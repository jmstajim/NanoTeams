import SwiftUI

/// Single shared API-token field used by every LM Studio settings surface
/// (LLM card, Vision card, Embeddings card, per-role override). Owns the
/// load-on-appear / reload-on-URL-change / save-on-edit lifecycle so each
/// call site is a single line:
///
/// ```swift
/// LLMTokenField(baseURL: config.llmBaseURLString, token: $apiToken)
/// ```
///
/// The parent passes a `Binding<String>` so it can read the current value
/// for "Test Connection" / "Fetch Models" calls (where the typed-but-unsaved
/// token must travel with the request before the Keychain write commits).
///
/// `isEnabled = false` (e.g. when a per-role override toggle is off) skips
/// writes entirely — the field becomes a no-op so a disabled URL doesn't
/// orphan a Keychain entry.
struct LLMTokenField: View {
    let baseURL: String
    @Binding var token: String
    var isEnabled: Bool = true
    /// Caption shown in place of the field when it's disabled because the
    /// URL is empty (e.g. Vision card inheriting the main LLM token).
    /// Default fits the most common case.
    var inheritedHint: String = "Inherits the token from the main LLM server"

    private let storage: any SecureTokenStorage
    /// Optional callback invoked on Keychain write failure so the parent can
    /// surface the error (e.g. via `store.lastErrorMessage`). Defaults to
    /// no-op so existing call sites keep compiling.
    private let onSaveError: ((Error) -> Void)?
    /// Optional callback invoked on Keychain READ failure (locked, ACL
    /// denied, corrupt entry). Wired by parents so the user sees a banner
    /// instead of an empty SecureField + 401-loop on every request.
    private let onLoadError: ((Error) -> Void)?

    init(
        baseURL: String,
        token: Binding<String>,
        isEnabled: Bool = true,
        inheritedHint: String = "Inherits the token from the main LLM server",
        storage: any SecureTokenStorage = KeychainSecureTokenStorage(),
        onSaveError: ((Error) -> Void)? = nil,
        onLoadError: ((Error) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self._token = token
        self.isEnabled = isEnabled
        self.inheritedHint = inheritedHint
        self.storage = storage
        self.onSaveError = onSaveError
        self.onLoadError = onLoadError
    }

    /// Effective enabled state: parent's `isEnabled` AND the URL is non-empty.
    /// An empty URL means the user hasn't pinned this surface to a specific
    /// server, so editing a token here would be saved against the wrong key.
    private var canEdit: Bool {
        Self.canEdit(isEnabled: isEnabled, baseURL: baseURL)
    }

    /// Pure decision used by `canEdit` — exposed for tests so the rule
    /// (parent enabled + URL non-empty + non-whitespace) is pinned without
    /// mounting SwiftUI.
    static func canEdit(isEnabled: Bool, baseURL: String) -> Bool {
        isEnabled && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if canEdit {
                editableField
            } else {
                inheritedHintRow
            }
        }
        .onAppear { reload() }
        .onChange(of: baseURL) { _, _ in reload() }
        .onChange(of: token) { _, newValue in save(newValue) }
        .onChange(of: isEnabled) { _, enabled in
            // Disabled → clear the visible field so a stale value from the
            // previous URL doesn't sit there. Re-enabled → reload from storage
            // so the saved token reappears (otherwise the user sees an empty
            // field and types over the saved value).
            //
            // Safe (unlike a parent doing the same write — see CLAUDE.md
            // "LM Studio Authentication" warning) because `save()` is
            // gated on `canEdit`, and `canEdit` is `false` here (`isEnabled`
            // is `false`). The cleared value is visual-only and does not
            // propagate to storage.
            if enabled {
                reload()
            } else {
                token = ""
            }
        }
    }

    @ViewBuilder
    private var editableField: some View {
        SecureField("API Token (optional)", text: $token)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .font(Typography.mono)
            .inputSurface(.field) {
                EmptyView()
            } trailing: {
                if !token.isEmpty {
                    Button {
                        token = ""
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear API token")
                    .accessibilityLabel("Clear API token")
                }
            }
    }

    @ViewBuilder
    private var inheritedHintRow: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(Colors.textTertiary)
            Text(inheritedHint)
                .foregroundStyle(Colors.textTertiary)
            Spacer(minLength: 0)
        }
        .font(Typography.monoCaption)
        .padding(Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceElevatedSubtle)
        )
    }

    private var persistence: LLMTokenFieldPersistence {
        LLMTokenFieldPersistence(storage: storage)
    }

    private func reload() {
        // The resulting `onChange(of: token)` calls `save()`, which in turn
        // calls `saveTokenIfChanged` — that helper compares against the
        // current storage value and skips when equal, so the echo is a no-op.
        // No `isReloading` flag needed: the content-comparison eliminates the
        // race window where a fast keystroke landing right after `reload()`
        // could otherwise be silently swallowed by a flag-guard.
        token = persistence.loadToken(forBaseURL: baseURL, onReadError: onLoadError)
    }

    private func save(_ newValue: String) {
        // Skip saves while editing is disabled — either the parent toggled
        // the override off or the URL is empty (in which case the entry
        // would be saved under the wrong Keychain key).
        guard canEdit else { return }
        do {
            try persistence.saveTokenIfChanged(newValue, forBaseURL: baseURL)
        } catch {
            onSaveError?(error)
        }
    }
}
