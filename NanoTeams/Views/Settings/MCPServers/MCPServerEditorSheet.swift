import SwiftUI

/// Add or edit one MCP server.
///
/// The sheet owns the draft and nothing else. What the Keychain holds reaches it as account
/// NAMES (`storedSecretKeys`, the manager's reading), and the save — the Keychain, the
/// approvals and the list, in that order — is `MCPServerManager.save`'s. The sheet dismisses
/// only when that save returned: a failure stays on screen, with everything typed still in the
/// fields, instead of closing as if the server had been saved (F41).
struct MCPServerEditorSheet: View {

    /// `nil` adds a server. Non-nil edits that one.
    let editing: MCPServerConfig?
    let existing: [MCPServerConfig]
    let onSave: @MainActor (MCPServerConfig, MCPServerSecretEdit) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: MCPServerEditorState
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var showingJudgePrompt = false
    /// Save lives in the fixed header, so the press can come from anywhere in the scroll; the
    /// banners it raises are at the top, and the page goes there to show them.
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// The draft is seeded HERE (#26), so the first frame already holds the stored server —
    /// seeded in a `.task`, an Edit sheet drew one blank frame with a red problems banner first
    /// (F49).
    ///
    /// `initialSaveError` is the banner the sheet opens on: `nil` wherever a person opens it,
    /// since only a save that threw sets one. The previews pass one, so the failed-save state
    /// can be looked at without a Keychain that refuses a write.
    init(
        editing: MCPServerConfig?,
        storedSecretKeys: Set<String> = [],
        existing: [MCPServerConfig],
        initialSaveError: String? = nil,
        onSave: @escaping @MainActor (MCPServerConfig, MCPServerSecretEdit) async throws -> Void
    ) {
        self.editing = editing
        self.existing = existing
        self.onSave = onSave
        _state = State(initialValue: editing.map {
            MCPServerEditorState.from(config: $0, storedSecretKeys: storedSecretKeys)
        } ?? MCPServerEditorState())
        _saveError = State(initialValue: initialSaveError)
    }

    private var isCreating: Bool { editing == nil }

    private var problems: [MCPServerEditorState.Problem] {
        state.problems(existing: existing)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            TerminalDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    // Above the cards: a Save that did nothing must say why where the eye lands.
                    if state.revealsProblems, !problems.isEmpty { problemsBanner }
                    if let saveError { errorBanner(saveError) }
                    identityCard
                    authenticationCard
                    policyCard
                }
                .padding(Spacing.xl)
            }
            .scrollPosition($scrollPosition)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Colors.surfacePrimary)
        }
        .frame(minWidth: 620, minHeight: 560)
        .sheet(isPresented: $showingJudgePrompt) {
            MCPJudgePreviewSheet(strictness: state.judgeStrictness)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Spacing.m) {
            MonoLabel(text: isCreating ? "Add MCP server" : "Edit MCP server", marker: true)
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.terminalSecondary)
                .keyboardShortcut(.cancelAction)
            // Enabled with problems on screen or not: a press on an untouched draft is what
            // reveals them (`noteSaveAttempt`), and a Save that did nothing must say why.
            Button("Save") { Task { await save() } }
                .buttonStyle(.terminalPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.m)
    }

    // MARK: - Cards

    private var identityCard: some View {
        SettingsCard(
            header: "Server",
            footer: "The short name prefixes every tool the model sees: mcp__<name>__<tool>."
        ) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SettingsToggleRow(title: "Connect to this server", icon: "power", isOn: $state.isEnabled)
                caption("Connecting lists its tools for your review. None reaches a prompt until you approve it.")
            }
            labelled("Short name") {
                TextField("my_server", text: $state.slugText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .terminalField()
            }
            labelled("Display name") {
                TextField("My server", text: $state.displayName)
                    .textFieldStyle(.plain)
                    .terminalField()
            }
            labelled("Address") {
                TextField("https://example.com/mcp", text: $state.urlString)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .terminalField()
            }
            if state.isRepointing {
                warning("A different server: saving clears the token, the header values and the tool "
                    + "approvals the old address was given. Enter its secrets again below.")
            }
        }
    }

    private var authenticationCard: some View {
        SettingsCard(
            header: "Authentication",
            footer: "Tokens are stored in the macOS Keychain — never in the server list, a log or a URL."
        ) {
            TerminalSegmentedPicker(
                selection: $state.authorization,
                options: MCPAuthorizationMode.allCases.map { ($0, $0.displayName) })

            if state.authorization == .staticBearer {
                labelled("Token") {
                    SecureField(state.bearerPlaceholder, text: $state.bearerToken)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .font(Typography.mono)
                        .inputSurface(.field)
                }
                if state.showsShortTokenWarning {
                    warning(MCPServerEditorState.shortSecretWarning)
                }
            }

            headerRows
        }
    }

    @ViewBuilder
    private var headerRows: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("Extra headers")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                Spacer()
                SettingsPillButton(title: "Add header", icon: "plus") {
                    state.headers.append(MCPServerEditorState.HeaderDraft())
                }
            }
            ForEach($state.headers) { $header in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.s) {
                        TextField("X-Tenant", text: $header.name)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .terminalField()
                            .frame(width: 160)
                        SecureField(state.valuePlaceholder(for: header), text: $header.value)
                            .textFieldStyle(.plain)
                            .font(Typography.mono)
                            .inputSurface(.field)
                        Button {
                            state.headers.removeAll { $0.id == header.id }
                        } label: {
                            // The cell is the hit area, not the glyph (CLAUDE.md View Conventions #12).
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Colors.textTertiary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove this header")
                        .accessibilityLabel("Remove header")
                    }
                    if state.showsShortValueWarning(for: header) {
                        warning(MCPServerEditorState.shortSecretWarning)
                    }
                }
            }
        }
    }

    private var policyCard: some View {
        SettingsCard(header: "Approval", footer: state.approvalMode.settingDescription) {
            TerminalSegmentedPicker(
                selection: $state.approvalMode,
                options: MCPApprovalMode.allCases.map { ($0, $0.displayName) })

            if state.showsJudgeControls {
                labelled("Judge strictness") {
                    TerminalSegmentedPicker(
                        selection: $state.judgeStrictness,
                        options: MCPJudgeStrictness.allCases.map { ($0, $0.displayName) })
                }
                caption(state.judgeStrictness.settingDescription)
                SettingsPillButton(title: "View judge prompt", icon: "doc.text.magnifyingglass") {
                    showingJudgePrompt = true
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                SettingsToggleRow(title: "Trusted server", icon: "checkmark.shield", isOn: $state.isTrusted)
                    .disabled(!state.isTrustMarkEditable)
                caption(state.trustMarkCaption ?? "Its read-only tools may run without asking.")
            }
        }
    }

    private var problemsBanner: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(problems, id: \.self) { problem in
                banner(problem.message, glyph: TerminalGlyph.failed,
                       tint: Colors.errorTint, ink: Colors.error)
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        banner(text, glyph: TerminalGlyph.failed, tint: Colors.errorTint, ink: Colors.error)
    }

    private func banner(_ text: String, glyph: String, tint: Color, ink: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            StatusGlyph(glyph: glyph, color: ink)
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(tint))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Colors.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            content()
        }
    }

    // MARK: - Saving

    private func save() async {
        state.noteSaveAttempt()
        saveError = nil
        isSaving = true
        defer { isSaving = false }
        let outcome = await Self.save(state.makeConfig(existing: existing), state.secretEdit, through: onSave)
        saveError = outcome.saveError
        if outcome.dismissesSheet {
            dismiss()
        } else {
            withAnimation(Animations.quick) { scrollPosition.scrollTo(edge: .top) }
        }
    }

    /// What one Save press ends in, and what the sheet then does — read one-to-one by `save()`,
    /// so "closes only on a save that returned" is a fact a test can hold (F41).
    enum SaveOutcome: Equatable {
        /// The draft still has problems — now on screen; nothing was asked of the manager.
        case blocked
        /// The save returned: the sheet closes.
        case saved
        /// The save threw: the sheet stays open on this message, everything typed still in it.
        case failed(String)

        /// Whether the sheet closes: only after a save that returned.
        var dismissesSheet: Bool { self == .saved }

        /// The banner the sheet shows after the press: the failure's message, or none.
        var saveError: String? {
            guard case .failed(let message) = self else { return nil }
            return message
        }
    }

    /// Decided here rather than in `body`, so a test can hold the sheet to "closes only on a
    /// save that returned" (F41).
    static func save(
        _ config: MCPServerConfig?,
        _ secrets: MCPServerSecretEdit,
        through onSave: @MainActor (MCPServerConfig, MCPServerSecretEdit) async throws -> Void
    ) async -> SaveOutcome {
        guard let config else { return .blocked }
        do {
            try await onSave(config, secrets)
            return .saved
        } catch {
            return .failed((error as? MCPServerEditError)?.message ?? "The server could not be saved.")
        }
    }
}

#Preview("Add server") {
    MCPServerEditorSheet(editing: nil, existing: [], onSave: { _, _ in })
}

#Preview("Save failed") {
    MCPServerEditorSheet(
        editing: nil,
        existing: [],
        initialSaveError: MCPServerEditError.catalogueNotSaved(undone: true, approvalsCleared: false).message,
        onSave: { _, _ in })
}
