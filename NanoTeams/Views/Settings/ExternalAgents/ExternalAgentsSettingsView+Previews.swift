import SwiftUI

// MARK: - Preview data

/// Mocked facts for the External Agents tab: the states a design review needs to see without a
/// Keychain — rendered through `./render_preview.sh` (Xcode's `RenderPreview`).
// periphery:ignore - used in #Preview macros below
enum ExternalAgentsSettingsPreview {

    /// The real clock: the row's "Last seen" is formatted against it.
    static let now = Date()
    static let agentID = UUID(uuidString: "A4C36525-0000-4000-8000-000000000001")!

    static func agent(
        label: String = "Claude Code live", shortID: String = "a4c36525",
        lastSeenAgo: TimeInterval? = 3 * 3600, hint: String? = "claude-code/2.1",
        mayReplaceContext: Bool = false
    ) -> HostedMCPAgentRecord {
        HostedMCPAgentRecord(
            id: agentID, shortID: shortID, label: label,
            createdAt: now.addingTimeInterval(-6 * 3600),
            lastSeenAt: lastSeenAgo.map { now.addingTimeInterval(-$0) },
            clientHint: hint,
            mayReplaceWorkFolderContext: mayReplaceContext)
    }

    static func presentation(
        enabled: Bool = true,
        state: HostedMCPListenerState = .listening(port: 47321),
        agents: [HostedMCPAgentRecord] = [agent()],
        present: Set<UUID> = [],
        openTasks: [UUID: Int] = [:],
        bashWarnings: [BashSecurityWarning] = []
    ) -> ExternalAgentsSettingsPresentation {
        ExternalAgentsSettingsPresentation.make(
            externalAgentsEnabled: enabled,
            configuredPort: 47321,
            listenerState: state,
            agents: agents,
            presenceByAgent: Dictionary(uniqueKeysWithValues: agents.map { ($0.id, present.contains($0.id)) }),
            openTasksByAgent: openTasks,
            bashWarnings: bashWarnings)
    }

    /// Screenshot 5: listening, one agent registered and offline.
    static func listeningWithOfflineAgent() -> ExternalAgentsSettingsPresentation {
        presentation()
    }

    /// The agent is connected and holds two open tasks.
    static func listeningWithOnlineAgent() -> ExternalAgentsSettingsPresentation {
        presentation(agents: [agent(lastSeenAgo: 5)], present: [agentID], openTasks: [agentID: 2])
    }

    /// The agent is connected and the person let it replace the Work Folder Context.
    static func listeningWithAgentAllowedToReplaceContext() -> ExternalAgentsSettingsPresentation {
        presentation(agents: [agent(lastSeenAgo: 5, mayReplaceContext: true)], present: [agentID], openTasks: [agentID: 1])
    }

    /// Another process took the port while the app was closed: the rotation banner.
    static func portInUse() -> ExternalAgentsSettingsPresentation {
        presentation(state: .failed(.portInUse(47321)))
    }

    /// Switched off, with an agent still on the list.
    static func off() -> ExternalAgentsSettingsPresentation {
        presentation(enabled: false, state: .stopped)
    }

    /// No agent yet — the page as it is first seen.
    static func listeningWithNoAgents() -> ExternalAgentsSettingsPresentation {
        presentation(agents: [])
    }

    static let executablePath = "/Applications/NanoTeams.app/Contents/MacOS/NanoTeams"
    /// A home folder that is nobody's: the paths in the previews read as a person's would.
    static let home = URL(fileURLWithPath: "/Users/you", isDirectory: true)

    /// Where NanoTeams writes the token for `shortID` — what `HostedMCPClientTokenFile` would.
    static func tokenFile(shortID: String = "a4c36525") -> URL {
        HostedMCPClientTokenFile.location(shortID: shortID, home: home)!
    }

    /// A token as the sheet hands it over: written to its file unless the preview says the
    /// write failed.
    static func issuedToken(
        id: UUID = agentID, label: String = "Claude Code", shortID: String = "a4c36525",
        delivery: HostedMCPTokenHandoff.Delivery? = nil
    ) -> ExternalAgentsSettingsView.IssuedAgentTokenItem {
        .init(
            id: id, label: label, shortID: shortID,
            token: "ntm_\(shortID)_0f3c9b1e7d2a4c6e8b0f1a3c5e7d9b2f4a6c8e0b",
            delivery: delivery ?? .written(tokenFile(shortID: shortID)))
    }

    /// The sheet at `stage`, with the one registered agent as the duplicate check's roster.
    static func sheet(
        _ stage: ExternalAgentSheet.Stage, message: String? = nil, factsUnfolded: Bool = false
    ) -> some View {
        ExternalAgentSheet(
            opening: stage, existingAgents: listeningWithOfflineAgent().agentRows,
            port: 47321, executablePath: executablePath, clientHome: home, issuers: .inert, message: message,
            factsUnfolded: factsUnfolded)
        .frame(width: 620, height: factsUnfolded ? 1100 : 760)
    }

    /// A reissue of every token that left one agent out — the note as the sheet words it.
    static func partialReissueNote() -> String? {
        ExternalAgentSheet.IssueResult(bulk: HostedMCPBulkRotation(
            issued: [], failures: [.init(agentID: UUID(), label: "Codex", message: "macOS Keychain error: locked")]
        )).note
    }
}

// periphery:ignore - used in #Preview macros below
private struct ExternalAgentsPreviewHost: View {
    let presentation: ExternalAgentsSettingsPresentation
    @State private var isEnabled: Bool
    /// Opened by Add agent and never presented here: the sheet's stages have previews of their own.
    @State private var agentSheet: ExternalAgentSheet.Entry?

    init(_ presentation: ExternalAgentsSettingsPresentation) {
        self.presentation = presentation
        _isEnabled = State(initialValue: presentation.listenerStatus != .disabled)
    }

    var body: some View {
        ExternalAgentsSettingsContent(
            presentation: presentation,
            isEnabled: $isEnabled,
            storedPort: 47321,
            agentSheet: $agentSheet,
            actions: .inert)
        .frame(width: 760, height: 600)
        .background(Colors.surfacePrimary)
    }
}

#Preview("Listening — agent offline") {
    ExternalAgentsPreviewHost(ExternalAgentsSettingsPreview.listeningWithOfflineAgent())
}

#Preview("Listening — agent online") {
    ExternalAgentsPreviewHost(ExternalAgentsSettingsPreview.listeningWithOnlineAgent())
}

#Preview("Listening — agent may replace the context") {
    ExternalAgentsPreviewHost(ExternalAgentsSettingsPreview.listeningWithAgentAllowedToReplaceContext())
}

#Preview("Port in use") {
    ExternalAgentsPreviewHost(ExternalAgentsSettingsPreview.portInUse())
}

#Preview("Off") {
    ExternalAgentsPreviewHost(ExternalAgentsSettingsPreview.off())
}

#Preview("Listening — no agents") {
    ExternalAgentsPreviewHost(ExternalAgentsSettingsPreview.listeningWithNoAgents())
}

#Preview("Sheet — Add agent") {
    ExternalAgentsSettingsPreview.sheet(.add)
}

#Preview("Sheet — Reissue one") {
    ExternalAgentsSettingsPreview.sheet(.reissue(.one(ExternalAgentsSettingsPreview.listeningWithOfflineAgent().agentRows[0])))
}

#Preview("Sheet — Token issued") {
    ExternalAgentsSettingsPreview.sheet(.issued([ExternalAgentsSettingsPreview.issuedToken()], isReissue: false))
}

#Preview("Sheet — Token file not written") {
    ExternalAgentsSettingsPreview.sheet(.issued([ExternalAgentsSettingsPreview.issuedToken(
        delivery: .notWritten(
            ExternalAgentsSettingsPreview.tokenFile(),
            reason: "Could not write ~/.config/nanoteams/a4c36525.token."))], isReissue: true))
}

#Preview("Sheet — Reissued, one agent left out") {
    ExternalAgentsSettingsPreview.sheet(
        .issued([ExternalAgentsSettingsPreview.issuedToken(label: "Claude Code live")], isReissue: true),
        message: ExternalAgentsSettingsPreview.partialReissueNote())
}

#Preview("Sheet — Every token reissued") {
    ExternalAgentsSettingsPreview.sheet(.issued([
        ExternalAgentsSettingsPreview.issuedToken(),
        ExternalAgentsSettingsPreview.issuedToken(
            id: UUID(uuidString: "B7D11E02-0000-4000-8000-000000000002")!, label: "Codex", shortID: "b7d11e02"),
    ], isReissue: true))
}

#Preview("Sheet — Connect an existing agent") {
    ExternalAgentsSettingsPreview.sheet(.connection(ExternalAgentsSettingsPreview.listeningWithOfflineAgent().agentRows[0]))
}

/// The fold a person opens to set a client up by hand: the two routes and what both need.
#Preview("Sheet — Connect, facts unfolded") {
    ExternalAgentsSettingsPreview.sheet(
        .connection(ExternalAgentsSettingsPreview.listeningWithOfflineAgent().agentRows[0]), factsUnfolded: true)
}
