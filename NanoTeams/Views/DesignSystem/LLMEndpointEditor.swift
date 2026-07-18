import SwiftUI

/// Single trailing status surface used by `LLMEndpointEditor`. Parents
/// compute exactly one of these per render so that error / warning / info
/// messages never compete with other inline rows scattered through the
/// card body. Hidden when `nil`.
nonisolated enum EndpointStatus: Equatable {
    case error(String)
    case warning(String)
    case info(String)

    var message: String {
        switch self {
        case .error(let m), .warning(let m), .info(let m): return m
        }
    }

    /// Pure status resolver shared by every endpoint card. Hides any
    /// stale error while a fetch is in flight (spinner speaks), and
    /// surfaces the most recent error otherwise. Empty / whitespace-only
    /// strings collapse to nil so an empty status row never renders.
    nonisolated static func resolve(
        fetchError: String?,
        isFetching: Bool
    ) -> EndpointStatus? {
        if isFetching { return nil }
        if let err = fetchError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !err.isEmpty {
            return .error(err)
        }
        return nil
    }
}

/// Unified UI block for picking an LM Studio endpoint:
/// **URL → API Token → (optional Test slot) → Model picker → Status row**.
///
/// One component used by every surface that selects an LM Studio endpoint:
/// the main LLM card, Vision card, Embeddings card, and per-role override
/// (Role Editor → LLM tab). Keeps placeholder text, error rendering, and
/// load/save lifecycle identical everywhere — so a user who learns the
/// pattern in one place reads every other LM endpoint at a glance.
///
/// Flexibility points:
/// - `urlPrompt` — placeholder text for the URL field (e.g. global URL
///   inherited by Vision when its own URL is blank).
/// - `urlIsEnabled` — disabled URL when the parent's "Custom override" toggle
///   is off. The token field auto-disables in lockstep.
/// - `urlVisible` — when `false`, hides the URL + Token fields entirely
///   (used by override cards when their "Override server URL & API token"
///   toggle is off, so the user only sees the model picker / inheritance
///   label and the URL inheritance is implicit).
/// - `modelVisible` — when `false`, hides the model picker and (if a non-empty
///   `inheritedModelLabel` is provided) renders a small inheritance row in
///   its place so the user sees what model would be used.
/// - `inheritedModelLabel` — the model name to surface as "Inherits global
///   model: <name>" when `modelVisible == false`.
/// - `testSlot` — `@ViewBuilder` slot rendered between Token and Model. The
///   main LLM card injects its "Test Connection" + status pill row here;
///   other surfaces pass `EmptyView()`.
/// - `status` — single typed status (error / warning / info) rendered in a
///   trailing row. Parents compute this from their own priority rules
///   (connection failure > model fetch error > validation hints, etc.).
struct LLMEndpointEditor<TestSlot: View>: View {

    // MARK: Bindings (parent owns the values so it can use `apiToken` for
    // Test Connection / Fetch Models calls before the Keychain write commits)

    @Binding var baseURL: String
    @Binding var modelName: String
    @Binding var apiToken: String

    // MARK: Configuration

    var urlPrompt: String? = nil
    /// Value the URL field's inline X button restores to. `""` (default)
    /// means "clear" (override cards inheriting from a broader scope);
    /// the global LLM card passes a canonical URL so the field is never
    /// stranded in a broken empty state.
    var urlDefaultValue: String = ""
    var urlIsEnabled: Bool = true
    var urlVisible: Bool = true
    var modelVisible: Bool = true
    var emptyModelLabel: String = "Select a model"
    /// Hint shown in place of the token field when the URL is empty. The
    /// LLM card overrides this to "Set a server address…" since it's the
    /// root server (nothing to inherit from); Vision/Embeddings/Role-
    /// override surfaces use the default ("inherits from main LLM server").
    var tokenInheritedHint: String = "Inherits the token from the main LLM server"
    /// Shown in place of the model picker when `modelVisible == false`.
    /// `nil` or empty → no inheritance row (URL-only override surfaces).
    var inheritedModelLabel: String? = nil
    /// Optional Keychain-write error sink. Wired by parents that hold a
    /// reference to `NTMSOrchestrator.lastErrorMessage`.
    var onTokenSaveError: ((Error) -> Void)? = nil
    /// Optional Keychain-READ error sink (locked Keychain, ACL denied,
    /// corrupt entry). Without this wired, a stuck Keychain looks
    /// identical to "no token saved" — every request 401s and the user
    /// can't tell whether they need to re-enter the token or unlock
    /// Keychain Access.
    var onTokenLoadError: ((Error) -> Void)? = nil
    /// Fired when the URL field loses focus or the user presses Return —
    /// used by the global LLM card to auto-run Test Connection so the
    /// status pill updates without a separate click.
    var onURLCommit: (() -> Void)? = nil

    // MARK: Model picker state (passed through; parent owns fetch loop)

    let availableModels: [String]
    let isFetchingModels: Bool
    /// Single consolidated status row, computed by the parent. The previous
    /// `modelFetchError: String?` parameter folded into this — parents that
    /// just want to show a fetch-error message pass `.warning(error)`.
    var status: EndpointStatus? = nil
    /// Closure wired to the Refresh button on the model picker. Parents
    /// pass `{ Task { await catalog.refresh(url: ...) } }` so user-driven
    /// re-fetches always fire, regardless of cache state.
    let onRefreshModels: () -> Void

    @ViewBuilder var testSlot: TestSlot

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if urlVisible {
                LLMElevatedTextField(
                    "Server Address",
                    text: $baseURL,
                    prompt: urlPrompt,
                    defaultValue: urlDefaultValue,
                    onCommit: onURLCommit
                )
                .disabled(!urlIsEnabled)
                .opacity(urlIsEnabled ? 1 : 0.5)

                LLMTokenField(
                    baseURL: baseURL,
                    token: $apiToken,
                    isEnabled: urlIsEnabled,
                    inheritedHint: tokenInheritedHint,
                    onSaveError: onTokenSaveError,
                    onLoadError: onTokenLoadError
                )
            }

            testSlot

            if modelVisible {
                LLMModelPickerSection(
                    modelName: $modelName,
                    availableModels: availableModels,
                    isFetching: isFetchingModels,
                    emptyLabel: emptyModelLabel,
                    onRefresh: onRefreshModels
                )
            } else if let label = inheritedModelLabel?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !label.isEmpty {
                inheritedModelRow(label)
            }

            if let status {
                statusRow(status)
            }
        }
    }

    @ViewBuilder
    private func inheritedModelRow(_ label: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(Colors.textTertiary)
            Text("Inherits global model:")
                .foregroundStyle(Colors.textTertiary)
                .fixedSize()
            Text(label)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(label)
            Spacer(minLength: 0)
        }
        .font(Typography.monoCaption)
        .padding(Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceElevatedSubtle)
        )
    }

    private func statusIcon(_ status: EndpointStatus) -> String {
        switch status {
        case .error: return "xmark.octagon"
        case .warning: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }

    private func statusColor(_ status: EndpointStatus) -> Color {
        switch status {
        case .error: return Colors.error
        case .warning: return Colors.warning
        case .info: return Colors.textSecondary
        }
    }

    @ViewBuilder
    private func statusRow(_ status: EndpointStatus) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: statusIcon(status))
                .foregroundStyle(statusColor(status))
                .font(Typography.caption)
            Text(status.message)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - No-test-slot convenience

extension LLMEndpointEditor where TestSlot == EmptyView {
    init(
        baseURL: Binding<String>,
        modelName: Binding<String>,
        apiToken: Binding<String>,
        urlPrompt: String? = nil,
        urlDefaultValue: String = "",
        urlIsEnabled: Bool = true,
        urlVisible: Bool = true,
        modelVisible: Bool = true,
        emptyModelLabel: String = "Select a model",
        tokenInheritedHint: String = "Inherits the token from the main LLM server",
        inheritedModelLabel: String? = nil,
        onTokenSaveError: ((Error) -> Void)? = nil,
        onTokenLoadError: ((Error) -> Void)? = nil,
        onURLCommit: (() -> Void)? = nil,
        availableModels: [String],
        isFetchingModels: Bool,
        status: EndpointStatus? = nil,
        onRefreshModels: @escaping () -> Void
    ) {
        self.init(
            baseURL: baseURL,
            modelName: modelName,
            apiToken: apiToken,
            urlPrompt: urlPrompt,
            urlDefaultValue: urlDefaultValue,
            urlIsEnabled: urlIsEnabled,
            urlVisible: urlVisible,
            modelVisible: modelVisible,
            emptyModelLabel: emptyModelLabel,
            tokenInheritedHint: tokenInheritedHint,
            inheritedModelLabel: inheritedModelLabel,
            onTokenSaveError: onTokenSaveError,
            onTokenLoadError: onTokenLoadError,
            onURLCommit: onURLCommit,
            availableModels: availableModels,
            isFetchingModels: isFetchingModels,
            status: status,
            onRefreshModels: onRefreshModels,
            testSlot: { EmptyView() }
        )
    }
}
