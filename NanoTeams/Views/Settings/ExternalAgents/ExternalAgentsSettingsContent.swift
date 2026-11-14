import SwiftUI

/// What the External Agents tab draws, from an `ExternalAgentsSettingsPresentation` and the actions
/// its wrapper performs. Pure of the store: every fact is a parameter, every effect a closure.
///
/// The page is the server and its agents, and nothing about connecting a client: that is the
/// agent sheet's (`ExternalAgentSheet`), reached by Add agent and by each row's How to connect.
/// Until 2026-11-12 two more cards closed the page — the six connection facts and the setup
/// prompt, both for nobody, with `<agent-id>` where an agent's id goes. They were some 60 % of
/// the page's height and a second copy of what the sheet shows filled in.
struct ExternalAgentsSettingsContent: View {
    /// What the tab can do to the server and its agents. Each throws so the content can put
    /// the failure on screen. Issuing a token is not here: the Add agent sheet does that, and
    /// the tab only opens it (`agentSheet`).
    struct Actions {
        var restartServer: @MainActor () async throws -> Void
        var setPort: @MainActor (Int) -> Void
        /// Returns a warning worth a line when the revocation succeeded with a caveat.
        var revokeAgent: @MainActor (UUID) throws -> String?
        /// The agent's switch: may it replace the open folder's Work Folder Context.
        var setMayReplaceWorkFolderContext: @MainActor (UUID, Bool) throws -> Void
        var openBashSettings: @MainActor () -> Void

        /// Every action a no-op: for a preview, and for a test of the drawing alone.
        // periphery:ignore - used in #Preview macros
        static let inert = Actions(
            restartServer: {}, setPort: { _ in }, revokeAgent: { _ in nil },
            setMayReplaceWorkFolderContext: { _, _ in }, openBashSettings: {})
    }

    let presentation: ExternalAgentsSettingsPresentation
    @Binding var isEnabled: Bool
    /// The port in the configuration — the field's resting value.
    let storedPort: Int
    /// Adding an agent and reissuing a token happen in `ExternalAgentSheet`, which also holds
    /// the one-time reveal. The Settings window presents it, so a tab change cannot take it down.
    @Binding var agentSheet: ExternalAgentSheet.Entry?
    let actions: Actions

    @State private var portDraft: String = ""
    /// Set by an Apply that moved the port: every client config written for the old one is now
    /// wrong, and the line saying so belongs next to the field that did it.
    @State private var portChanged = false
    @State private var pendingRevokeAgent: ExternalAgentRow?
    @State private var localErrorMessage: String?
    @State private var isRestarting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                intro
                if let warning = presentation.environmentTokenWarning {
                    environmentTokenCard(warning)
                }
                serverCard
                if !presentation.bashWarnings.isEmpty {
                    bashWarningsCard(presentation.bashWarnings)
                }
                // Switched off, the page is the switch and what it does. Agents already issued
                // stay listed so they can still be revoked.
                if isEnabled || !presentation.agentRows.isEmpty {
                    agentsCard
                }
            }
            .padding(Spacing.xl)
        }
        .onAppear {
            portDraft = String(storedPort)
        }
        .onChange(of: storedPort) { _, newValue in
            portDraft = String(newValue)
        }
        .confirmationDialog(
            "Revoke access for “\(pendingRevokeAgent?.label ?? "")”?",
            isPresented: Binding(
                get: { pendingRevokeAgent != nil },
                set: { if !$0 { pendingRevokeAgent = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let agent = pendingRevokeAgent {
                    revokeAgent(agent.id)
                }
                pendingRevokeAgent = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRevokeAgent = nil
            }
        } message: {
            Text("Its token stops working and the agent is disconnected at once.")
        }
    }

    // MARK: - Intro

    /// What the tab is for, and which way it points. No title of its own: the sidebar's
    /// highlighted cell already names the tab, as on every other page.
    private var intro: some View {
        Text("An external agent — Claude Code, Codex, Cursor and others — connects here to create tasks and supervise them. Tools your roles use from other servers are set up in MCP Servers.")
            .font(Typography.termBase)
            .foregroundStyle(Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Server Card

    private var serverCard: some View {
        SettingsCard(header: "Server", footer: presentation.listenerStatusDetail) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                SettingsToggleRow(
                    title: "Allow external agents to use NanoTeams",
                    icon: HostedMCPConstants.symbolName,
                    isOn: $isEnabled
                )

                // The state as a badge, the address beside it as text: an address belongs in
                // type that can be read and selected, not in 10pt capitals.
                HStack(spacing: Spacing.s) {
                    TerminalStatusBadge(
                        glyph: Self.glyph(for: presentation.listenerStatus),
                        label: presentation.listenerStatusTitle,
                        color: Self.color(for: presentation.listenerStatus))
                    if let address = presentation.listenerAddressText {
                        Text(address)
                            .font(Typography.monoCaption)
                            .foregroundStyle(Colors.textSecondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)

                    // Only where a restart can change something: a server that is listening
                    // or still starting has nothing a restart would repair.
                    if isEnabled, presentation.listenerStatus.offersRestart {
                        SettingsPillButton(
                            title: "Restart server", icon: "arrow.clockwise", isLoading: isRestarting
                        ) {
                            Task { await restartServer() }
                        }
                        .disabled(isRestarting)
                    }
                }

                if presentation.recommendsTokenRotation {
                    HStack(alignment: .top, spacing: Spacing.s) {
                        StatusGlyph(glyph: TerminalGlyph.failed, color: Colors.error)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Another app holds this port")
                                .font(Typography.subheadlineSemibold)
                                .foregroundStyle(Colors.textPrimary)
                            Text("It could have received an agent's token while NanoTeams was closed. Choose another port or quit that app, then reissue the tokens.")
                                .font(Typography.caption)
                                .foregroundStyle(Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !presentation.agentRows.isEmpty {
                                SettingsPillButton(
                                    title: "Reissue all agent tokens", icon: "key", isDestructive: true
                                ) {
                                    agentSheet = .reissue(.all)
                                }
                            }
                        }
                    }
                    .padding(Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.errorTint)
                    )
                }

                portRow

                if portChanged {
                    Text(ExternalAgentsConnectionFacts.portChangeHint)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let localErrorMessage {
                    Text(localErrorMessage)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The port on one line. No caption: the range is what a refused Apply says, and the default
    /// is the field's placeholder. Apply is there only while the draft is not the stored port
    /// (`ExternalAgentsSettingsPresentation.showsApply`).
    private var portRow: some View {
        HStack(spacing: Spacing.m) {
            Text("Port")
                .font(Typography.subheadlineMedium)
                .foregroundStyle(Colors.textPrimary)

            Spacer(minLength: 0)

            TextField(String(HostedMCPConstants.defaultPort), text: $portDraft)
                .textFieldStyle(.plain)
                .font(Typography.termBase)
                .frame(width: 96)
                .terminalField()
                .onSubmit {
                    applyPort()
                }

            if ExternalAgentsSettingsPresentation.showsApply(portDraft: portDraft, storedPort: storedPort) {
                SettingsPillButton(title: "Apply", icon: "checkmark") {
                    applyPort()
                }
            }
        }
    }

    /// The listener's glyph and ink, in the same vocabulary as an MCP server's status: a server
    /// still coming up is `info` (as "connecting" is there), a refusal is `error`, off is dim.
    static func glyph(for status: ExternalAgentsSettingsPresentation.ListenerStatus) -> String {
        switch status {
        case .listening: TerminalGlyph.done
        case .starting: TerminalGlyph.working
        case .portInUse, .failed: TerminalGlyph.failed
        case .disabled, .stopped: TerminalGlyph.paused
        }
    }

    static func color(for status: ExternalAgentsSettingsPresentation.ListenerStatus) -> Color {
        switch status {
        case .listening: Colors.success
        case .starting: Colors.info
        case .portInUse, .failed: Colors.error
        case .disabled, .stopped: Colors.textTertiary
        }
    }

    // MARK: - A8 Bash Security Warnings Card

    /// `NANOTEAMS_TOKEN` in the environment the app started with (#375).
    private func environmentTokenCard(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            StatusGlyph(glyph: TerminalGlyph.review, color: Colors.warning)
            Text(warning)
                .font(Typography.caption)
                .foregroundStyle(Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.warningTint))
    }

    private func bashWarningsCard(_ warnings: [BashSecurityWarning]) -> some View {
        SettingsCard(header: "Bash sandbox warnings") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(warnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: Spacing.s) {
                        StatusGlyph(glyph: TerminalGlyph.review, color: Colors.warning)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(warning.title)
                                .font(Typography.subheadlineSemibold)
                                .foregroundStyle(Colors.textPrimary)
                            Text(warning.message)
                                .font(Typography.caption)
                                .foregroundStyle(Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.s)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.warningTint)
                    )
                }
                SettingsPillButton(title: "Open Bash settings", icon: "terminal") {
                    actions.openBashSettings()
                }
            }
        }
    }

    // MARK: - Agents Card

    /// The list, with Add agent on the title line. The field that waited at the top of this
    /// card, and the token block that answered it, moved into `ExternalAgentSheet` (2026-11-08):
    /// a page is no place for a secret shown once.
    private var agentsCard: some View {
        SettingsCard(
            header: "Agents",
            footer: ExternalAgentsConnectionFacts.agentsCardFooter,
            headerTrailing: AnyView(
                SettingsPillButton(title: "Add agent", icon: "plus") {
                    agentSheet = .add
                })
        ) {
            if presentation.agentRows.isEmpty {
                Text(ExternalAgentsSettingsPresentation.noAgentsHint)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(presentation.agentRows) { row in
                        agentRowView(row)
                    }
                }
            }
        }
    }

    /// One agent: who it is on one line, its actions beside it where they fit and under it where
    /// they do not — the detail pane is about 409 pt at the Settings window's minimum width, and
    /// three pills beside a long label and its token prefix are wider than that.
    private func agentRowView(_ row: ExternalAgentRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.s) {
                    agentIdentity(row)
                    Spacer(minLength: 0)
                    agentActions(row)
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    agentIdentity(row)
                    HStack(spacing: Spacing.xs) {
                        Spacer(minLength: 0)
                        agentActions(row)
                    }
                }
            }

            // An agent that never connected has nothing to say here, and an empty line would
            // still hold a row of height.
            if !row.detailLine.isEmpty {
                Text(row.detailLine)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            contextPermissionToggle(row)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceElevated)
        )
    }

    private func agentIdentity(_ row: ExternalAgentRow) -> some View {
        HStack(spacing: Spacing.s) {
            TerminalStatusBadge(
                glyph: row.isPresent ? TerminalGlyph.done : TerminalGlyph.paused,
                label: row.presenceLabel,
                color: row.isPresent ? Colors.success : Colors.textTertiary)
            Text(row.label)
                .font(Typography.subheadlineSemibold)
                .foregroundStyle(Colors.textPrimary)
                .lineLimit(1)
            Text("ntm_\(row.shortID)_…")
                .font(Typography.termXs)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
        }
    }

    /// The one write that reaches past the agent's own tasks directly — the Work Folder Context,
    /// which the roles of the person's own tasks read too — is the person's to allow, agent by agent, and off
    /// until they do (decision A3, revised 2026-11-13). On the row, where the agent is, so which
    /// agents hold it reads at a glance.
    private func contextPermissionToggle(_ row: ExternalAgentRow) -> some View {
        Toggle(isOn: Binding(
            get: { row.mayReplaceWorkFolderContext },
            set: { allowed in setMayReplaceWorkFolderContext(allowed, for: row) })
        ) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(ExternalAgentsConnectionFacts.contextPermissionTitle)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textPrimary)
                Text(ExternalAgentsConnectionFacts.contextPermissionCaption)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.terminal)
    }

    private func agentActions(_ row: ExternalAgentRow) -> some View {
        HStack(spacing: Spacing.xs) {
            // The setup prompt and the connection facts for this agent — for a person who closed
            // the hand-over, or sets a second client up for the same agent. No token: that was
            // copied once, and a reissue is the way to another. Named for what it opens: as
            // "Connect" it read as an action that connects something.
            SettingsPillButton(title: "How to connect", icon: "link") {
                agentSheet = .connection(row)
            }
            SettingsPillButton(title: "Reissue token", icon: "arrow.triangle.2.circlepath") {
                agentSheet = .reissue(.one(row))
            }
            SettingsPillButton(title: "Revoke", icon: "trash", isDestructive: true) {
                pendingRevokeAgent = row
            }
        }
    }

    // MARK: - Actions

    private func setMayReplaceWorkFolderContext(_ allowed: Bool, for row: ExternalAgentRow) {
        do {
            try actions.setMayReplaceWorkFolderContext(row.id, allowed)
            localErrorMessage = nil
        } catch {
            // The switch reads the store, so it shows what is stored; this line says why not more.
            localErrorMessage = "The setting for “\(row.label)” could not be saved: \(error.localizedDescription)"
        }
    }

    private func restartServer() async {
        isRestarting = true
        defer { isRestarting = false }
        do {
            try await actions.restartServer()
            localErrorMessage = nil
        } catch {
            // The listener's own state usually says why; this is the line for when it does not.
            localErrorMessage = "The server could not restart: \(error.localizedDescription)"
        }
    }

    private func applyPort() {
        let trimmed = portDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed),
              (HostedMCPConstants.minValidPort...HostedMCPConstants.maxValidPort).contains(parsed)
        else {
            localErrorMessage = "Enter a port between 1024 and 65535."
            portDraft = String(storedPort)
            return
        }
        localErrorMessage = nil
        if parsed != storedPort {
            portChanged = true
        }
        actions.setPort(parsed)
    }

    private func revokeAgent(_ agentID: UUID) {
        do {
            localErrorMessage = try actions.revokeAgent(agentID)
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }
}
