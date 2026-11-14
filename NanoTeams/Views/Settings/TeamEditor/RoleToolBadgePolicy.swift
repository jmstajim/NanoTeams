import Foundation

// MARK: - Tool Availability Requirement

/// Why a tool the role has selected may not reach the model right now.
///
/// The membership sets below are the SAME registry constants the runtime filters
/// read (`ToolHandlerRegistry.computerUseTools`, `.defaultStorageBlocked`, the git
/// union) — this type maps a tool to its precondition, it does not restate the
/// filtering rules. Shared by the role-editor tool list and the role-list badge so
/// both name a precondition with the same words.
nonisolated enum ToolAvailabilityRequirement: Hashable, Sendable, CaseIterable {
    case visionModel
    case computerUse
    case gitRepository
    case workFolder
    case xcodeScheme
    /// `request_team_meeting` / `request_changes` on a team with meetings switched off.
    case meetingsEnabled
    /// `request_team_meeting` / `request_changes` / `ask_teammate` on a team with no second
    /// non-Supervisor role (`Team.hasTeammatePartner == false`) — the one partner rule
    /// both collaboration channels share.
    case teammatePartner
    /// Either parking tool (`ToolNames.supervisorAskTools`) on a team whose Ask Supervisor
    /// mode is Off — the mode withholds both, so both rows say so.
    case askSupervisorEnabled
    /// `bash` / `bash_output` while the bash execution mode is Off.
    case bashEnabled
    /// A tool whose every call would wait for a human's approval, on a team where no human
    /// is there to give it: Supervisor mode Autonomous (or the Autovisor supervising this
    /// folder) while the family's mode is Manual — or Semi-automatic, for the computer-use
    /// tools that are never read-only (`ApprovalGatedAvailability`) — or an MCP tool its
    /// server's mode would hold (`MCPGrantState.needsApprover`).
    case humanApprover
    /// An `mcp__…` grant whose server is configured and switched off app-wide. Reversible, and
    /// not a fault in the role.
    case mcpServerDisabled
    /// An `mcp__…` grant whose server is switched on and blocked by the open work folder's rule
    /// (`MCPGrantState.serverOffInThisFolder`) — the folder's switch, not the server's.
    case mcpServerOffInThisFolder
    /// An `mcp__…` grant whose server nothing runs because no work folder is served — one being
    /// switched, one that failed to open (`MCPGrantState.serverNotRunning`). Nothing to switch:
    /// it starts when a folder opens. Until 2026-10-28 it read `mcpServerDisabled`, "switched
    /// off — turn it on", of a server whose power switch was on.
    case mcpServerNotRunning
    /// An `mcp__…` grant whose server is not connected and lacks a credential its configuration
    /// declares (`MCPGrantState.serverNeedsToken`): the repair is the token.
    case mcpServerNeedsToken
    /// An `mcp__…` grant whose server is switched on and not answering: connecting, refused,
    /// or an address this client will not talk to. All of those read the same from here —
    /// come back when it connects — and the server list is where the reason is.
    case mcpServerDisconnected
    /// An `mcp__…` grant naming a tool the server publishes and nobody has approved, or
    /// approved once and the server has since rewritten, and whose text nobody refused. Withheld
    /// until someone reads it. Also a whole-server grant of a server that publishes tools, has
    /// none approved, and has one waiting to be read.
    case mcpToolUnreviewed
    /// An `mcp__…` grant naming a tool whose text the person refused
    /// (`MCPGrantState.toolRefused`). Decided, not waiting: withheld until they review it again
    /// and approve it. Until 2026-10-28 it read "Waiting for review" beside a Settings list that
    /// counted nothing to review.
    case mcpToolRefused
    /// A whole-server grant of a server every text of which the person refused
    /// (`MCPGrantState.everyToolRefused`) — the whole-server form of `mcpToolRefused`.
    case mcpServerToolsRefused
    /// An `mcp__…` grant whose server is connected and re-reading its tool list: a listing asked
    /// after its `list_changed`, or once its stated catalogue lifetime ran out, failed. A
    /// whole-server grant, or a tool the last committed listing had reviewed — one it did not
    /// publish or had not reviewed is filed as that. Nothing to repair — the read is retried
    /// on its own — but nothing ships until it succeeds, and the Settings row says so.
    case mcpToolsBeingReread
    /// An `mcp__…` grant of a tool its connected server does not publish
    /// (`MCPGrantState.toolMissing`) — renamed or withdrawn. The grant sits under that server's
    /// own header in the picker (F45), so its words name the server's answer, not a missing
    /// server; the repair is the role's, here. Until 2026-10-28 it shared `mcpToolLive`'s "No
    /// configured MCP server offers this … or add the server", under the server's own header.
    case mcpToolNotOffered
    /// An `mcp__…` grant of a tool its server publishes and the APP cannot offer — its listing
    /// collided, or the app could not read the entry (`MCPGrantState.toolNotOfferable`). Not the
    /// server's withdrawal: the grant works again once the server fixes what the Settings page
    /// names, so the words send the person there rather than telling them to uncheck it. Until
    /// 2026-10-28 it read `mcpToolNotOffered`'s "does not offer this tool — uncheck it here".
    case mcpToolNotOfferable
    /// A whole-server grant of a server that published tools the app can offer none of
    /// (`MCPGrantState.noToolOfferable`) — the whole-server form of `mcpToolNotOfferable`.
    case mcpServerToolsNotOfferable
    /// The residual: an `mcp__…` grant no configured server can name at all — the server was
    /// deleted or its slug renamed (`MCPGrantState.unknownServer`), or a per-tool grant the
    /// catalogue reads live and the run still did not ship. Nothing but editing the role will
    /// resolve it.
    case mcpToolLive

    /// Wording shown when the precondition is NOT met. Also used as the tooltip
    /// group header in the role-list badge.
    var unmetHint: String {
        switch self {
        case .visionModel: return "Requires vision model"
        case .computerUse: return "Off in Settings → Computer Use"
        case .gitRepository: return "Requires git repo"
        case .workFolder: return "Requires work folder"
        case .xcodeScheme: return "Requires Xcode scheme"
        case .meetingsEnabled: return "Meetings are off in Team Settings → Collaboration"
        case .teammatePartner: return "Needs a second teammate in this team"
        case .askSupervisorEnabled: return "Ask Supervisor is Off in Team Settings"
        case .bashEnabled: return "Bash is Off in Settings → Bash"
        case .humanApprover:
            return "Needs a human to approve — Supervisor mode is Autonomous "
                + "(or the Autovisor supervises this folder) while the tool's mode asks a human"
        case .mcpServerDisabled:
            return "Its MCP server is switched off — turn it on in Settings → MCP Servers"
        case .mcpServerOffInThisFolder:
            return "Its MCP server is off in this work folder — allow it in Settings → MCP Servers"
        case .mcpServerNotRunning:
            return "Its MCP server is not running — it starts when a work folder opens"
        case .mcpServerNeedsToken:
            return "Its MCP server needs a token — add it in Settings → MCP Servers"
        case .mcpServerDisconnected:
            return "Its MCP server is not connected — check it in Settings → MCP Servers"
        case .mcpToolUnreviewed:
            return "Waiting for review — approve it in Settings → MCP Servers"
        case .mcpToolRefused:
            return "You rejected this tool's text — review it again in Settings → MCP Servers to grant it"
        case .mcpServerToolsRefused:
            return "You rejected the text of every tool this server publishes — review them again "
                + "in Settings → MCP Servers to grant them"
        case .mcpToolsBeingReread:
            return "Its MCP server's tool list is being re-read — withheld until the read succeeds "
                + "(see Settings → MCP Servers)"
        case .mcpToolNotOffered:
            return "Its MCP server does not offer this tool — uncheck it here"
        case .mcpToolNotOfferable:
            return "The app cannot offer what its MCP server publishes as this tool — see Settings → MCP Servers"
        case .mcpServerToolsNotOfferable:
            return "The app cannot offer any tool its MCP server publishes — see Settings → MCP Servers"
        case .mcpToolLive:
            return "No configured MCP server offers this — uncheck it here, "
                + "or add the server in Settings → MCP Servers"
        }
    }

    /// Wording shown when the precondition IS met, where the surface knows. `nil`
    /// means the tool needs no annotation once available.
    var metHint: String? {
        switch self {
        case .visionModel: return "Vision model configured"
        case .computerUse: return "Computer Use enabled"
        case .bashEnabled: return "Bash enabled"
        case .gitRepository, .workFolder, .xcodeScheme, .meetingsEnabled, .teammatePartner,
             .askSupervisorEnabled, .humanApprover, .mcpServerDisabled, .mcpServerOffInThisFolder,
             .mcpServerNotRunning, .mcpServerNeedsToken, .mcpServerDisconnected,
             .mcpToolUnreviewed, .mcpToolRefused, .mcpServerToolsRefused, .mcpToolsBeingReread,
             .mcpToolNotOffered, .mcpToolNotOfferable, .mcpServerToolsNotOfferable, .mcpToolLive: return nil
        }
    }

    /// For surfaces that know whether the precondition currently holds.
    func hint(isMet: Bool) -> String {
        isMet ? (metHint ?? unmetHint) : unmetHint
    }

    /// The badge's reading of where one grant stands. The Domain type answers what is true;
    /// this says which group the tooltip files it under, and `nil` means nothing withholds it.
    static func forMCPGrant(_ state: MCPGrantState) -> ToolAvailabilityRequirement? {
        switch state {
        case .live: return nil
        case .serverDisabled: return .mcpServerDisabled
        case .serverOffInThisFolder: return .mcpServerOffInThisFolder
        case .serverNotRunning: return .mcpServerNotRunning
        case .serverNeedsToken: return .mcpServerNeedsToken
        case .serverUnreachable: return .mcpServerDisconnected
        case .catalogueBeingReread: return .mcpToolsBeingReread
        case .toolUnreviewed: return .mcpToolUnreviewed
        case .toolRefused: return .mcpToolRefused
        case .everyToolRefused: return .mcpServerToolsRefused
        case .toolMissing: return .mcpToolNotOffered
        case .toolNotOfferable: return .mcpToolNotOfferable
        case .noToolOfferable: return .mcpServerToolsNotOfferable
        case .unknownServer: return .mcpToolLive
        case .needsApprover: return .humanApprover
        }
    }

    /// The precondition governing `toolName`, or `nil` when the tool has none.
    ///
    /// Order matters and mirrors the runtime's: a git tool in default storage is
    /// blocked by the missing WORK FOLDER first — reporting "requires git repo"
    /// there would send the user to `git init` in a folder they haven't opened.
    /// The team gates are named only when the setting is actually off or the roster is
    /// actually short — with meetings on and a partner present, those tools have no
    /// precondition at all. `ask_teammate` reads the partner alone: the meetings switch
    /// does not govern consultations. The two approval-gated families read `approval`:
    /// `.withheld(.switchedOff)` names the family's Off switch, `.withheld(.noApprover)`
    /// the missing human, and `.readOnlyUnattended` the missing human for exactly the
    /// computer-use tools that are never read-only; an `.available` family — like
    /// `bash` under Semi-automatic with no human, whose read-only commands still run —
    /// names its master switch so the surface can render the met hint.
    static func governing(
        _ toolName: String,
        isDefaultStorage: Bool,
        approval: ToolApprovalAvailability,
        meetings: MeetingAvailability = .available,
        hasTeammatePartner: Bool = true,
        askSupervisorEnabled: Bool = true,
        mcpGrants: MCPGrantCatalogue = .empty
    ) -> ToolAvailabilityRequirement? {
        // FIRST, because every arm below asks a registry set and no set holds an `mcp__…`
        // name — a grant falling through would end up reported as "not installed", which
        // sends the user looking for a handler that was never meant to exist. With no
        // catalogue every grant answers `.unknownServer`, which is the honest reading: a
        // surface that was given nothing knows of no server that could serve it.
        if MCPToolNaming.isMCPName(toolName) {
            return forMCPGrant(mcpGrants.state(ofGrant: toolName, humanPresent: approval.humanPresent))
        }
        if toolName == ToolNames.requestTeamMeeting || toolName == ToolNames.requestChanges {
            switch meetings {
            case .switchedOff: return .meetingsEnabled
            case .noPartner: return .teammatePartner
            case .available: break
            }
        }
        if !hasTeammatePartner, toolName == ToolNames.askTeammate { return .teammatePartner }
        // The SET, not the one name: Off strips both parking tools (resolution 8b), so a
        // questionnaire row with no badge would promise a capability the run removes.
        if !askSupervisorEnabled, ToolNames.supervisorAskTools.contains(toolName) {
            return .askSupervisorEnabled
        }
        if toolName == ToolNames.analyzeImage { return .visionModel }
        if ToolHandlerRegistry.computerUseTools.contains(toolName) {
            switch approval.computerUse {
            case .withheld(.noApprover): return .humanApprover
            case .readOnlyUnattended:
                return ToolHandlerRegistry.computerUseMutatingTools.contains(toolName)
                    ? .humanApprover : .computerUse
            case .withheld(.switchedOff), .available: return .computerUse
            }
        }
        if ToolHandlerRegistry.shellTools.contains(toolName) {
            switch approval.bash {
            case .withheld(.noApprover): return .humanApprover
            case .withheld(.switchedOff), .readOnlyUnattended, .available: return .bashEnabled
            }
        }
        if isDefaultStorage, ToolHandlerRegistry.defaultStorageBlocked.contains(toolName) {
            return .workFolder
        }
        if toolName == ToolNames.runXcodebuild || toolName == ToolNames.runXcodetests {
            return .xcodeScheme
        }
        if ToolHandlerRegistry.gitReadTools.union(ToolHandlerRegistry.gitWriteTools).contains(toolName) {
            return .gitRepository
        }
        return nil
    }
}

// MARK: - Role Tool Badge

/// What the role-list row reports about a role's tools.
///
/// `effective` is the real step-execution set from `EffectiveToolset` — the same
/// three-stage chain the wire uses — so the badge count cannot drift from what
/// ships. Everything else is a classification of the leftovers, never a second
/// model of the injection rules.
nonisolated enum RoleToolBadgePolicy {

    struct Model: Equatable, Sendable {
        /// Names actually shipped for step execution, sorted.
        let effective: [String]
        /// Shipped names the user did NOT select — added by the runtime.
        let autoInjected: [String]
        /// Selected names with no handler in the registry (stale / hand-edited JSON).
        /// The only class that indicates a real problem.
        let notInstalled: [String]
        /// Selected names that can never ship from `toolIDs` by construction —
        /// `unavailableToRoles`, the delegation pack (auto-injected from settings
        /// instead), the retired `list_teams`, the Autovisor's `ask_supervisor`.
        let policyBlocked: [String]
        /// Selected names withheld by an unmet precondition, grouped by it.
        let unavailableHere: [ToolAvailabilityRequirement: [String]]
        /// Names the role holds ONLY inside its meeting turns — `conclude_meeting`,
        /// for the team's coordinator while meetings are on. Not in `effective`
        /// (that is the step set) and not selectable; listed so the editor and the
        /// row tooltip can say the role has it.
        let meetingOnly: [String]
        /// What this role can truthfully be told about the gavel, computed over every legal
        /// `(requester, target)` pair on this roster. `meetingOnly` above answers "does it
        /// hold `conclude_meeting` in a MEETING"; this answers the question 1.9.18 opened —
        /// a `request_changes` VOTE the coordinator is party to is chaired by someone else
        /// (DEBTS D-B12).
        let chair: MeetingChairPolicy.Standing

        var count: Int { effective.count }
        var isEmpty: Bool { effective.isEmpty }

        /// Nothing worth a badge: the role selected no tools and the runtime added
        /// none. Distinct from `isEmpty`, which is also true when everything the
        /// role selected is currently withheld — that case DOES want a badge, since
        /// a bare "0" plus the reason is the whole point.
        var isSilent: Bool {
            effective.isEmpty && notInstalled.isEmpty
                && policyBlocked.isEmpty && unavailableHere.isEmpty
        }

        /// A tool the role selected has no handler at all, or nothing ships despite
        /// a non-empty selection. Everything else is routine configuration.
        var needsAttention: Bool {
            !notInstalled.isEmpty || (effective.isEmpty && !isSilent)
        }

        /// Shipped names the user DID select.
        var configured: [String] {
            let auto = Set(autoInjected)
            return effective.filter { !auto.contains($0) }
        }
    }

    /// Names that are stripped out of `toolIDs` structurally, whatever the role
    /// configured. Mirrors `resolveToolSchemas` step 3.0 + `unavailableToRoles`.
    private static var structurallyBlocked: Set<String> {
        ToolHandlerRegistry.unavailableToRoles.union([
            ToolNames.delegateToTeam,
            ToolNames.cancelDelegation,
            ToolNames.resumeDelegation,
            ToolNames.forwardToTeam,
            "list_teams",
        ])
    }

    /// Compact digest of every role field `model(…)` reads, for memo keys.
    ///
    /// `TeamRoleDefinition` is `Codable, Identifiable` but NOT `Hashable`, so a
    /// caller can't just compare `team.roles`. A field that affects resolution and
    /// is missing here leaves a stale badge on screen — pinned field-by-field by
    /// `RoleToolBadgePolicyTests`.
    static func resolutionSignature(for role: TeamRoleDefinition) -> String {
        [
            role.id,
            role.systemRoleID ?? "",
            role.toolIDs.sorted().joined(separator: ","),
            // Drives `create_artifact` (produces) and `shouldAutoInjectAskSupervisor`
            // (both, via the producing / advisory / observer derivation).
            role.dependencies.producesArtifacts.sorted().joined(separator: ","),
            role.dependencies.requiredArtifacts.sorted().joined(separator: ","),
            role.allowedDelegationTeamIDs.sorted().joined(separator: ","),
            role.allowDelegationToGeneratedTeams ? "1" : "0",
            // Not read by tool resolution, but the same memo drives the skills badge.
            role.attachedSkillIDs.joined(separator: ","),
        ].joined(separator: "|")
    }

    static func model(
        role: TeamRoleDefinition,
        team: Team?,
        allTeams: [Team],
        storage: EffectiveToolset.Storage,
        selectedScheme: String?,
        isVisionConfigured: Bool,
        approval: ToolApprovalAvailability,
        autovisorTeamPolicy: AutovisorTeamPolicy,
        mcpGrants: MCPGrantCatalogue = .empty,
        fileManager: FileManager = .default
    ) -> Model {
        let shipped = EffectiveToolset.resolve(
            role: role,
            team: team,
            allTeams: allTeams,
            storage: storage,
            selectedScheme: selectedScheme,
            isVisionConfigured: isVisionConfigured,
            approval: approval,
            autovisorTeamPolicy: autovisorTeamPolicy,
            // Split on the presence a RUN of this team would have, as the runtime splits it
            // (`resolvedMCPTools(humanPresent:)`). The person at the editor is not the run's
            // approver: asked with `true` "by construction", every Manual server's tool counted
            // as shipped on an Autonomous team while the runtime withheld it (F46).
            mcpTools: mcpGrants.resolvedTools(humanPresent: approval.humanPresent),
            fileManager: fileManager
        )
        let effectiveNames = Set(shipped.map(\.name))
        // `toolIDs` has no dedup guarantee on the decode path — only
        // `RoleEditorMutations.strippedToolIDs` dedupes, so templates and
        // imported / hand-edited JSON can carry repeats.
        let configured = Set(role.toolIDs)

        let installed = Set(ToolHandlerRegistry.allSchemas.map(\.name))
        let blocked = structurallyBlocked
        let isDefaultStorage = storage == .defaultStorage

        var notInstalled: [String] = []
        var policyBlocked: [String] = []
        var unavailable: [ToolAvailabilityRequirement: [String]] = [:]

        for name in configured.subtracting(effectiveNames) {
            if MCPToolNaming.isMCPName(name) {
                let state = mcpGrants.state(ofGrant: name, humanPresent: approval.humanPresent)
                // A whole-server grant never ships under its own name — its tools do, and they
                // are in `effectiveNames`. Live, it brings whatever of the server this run can
                // take (nothing, from a server that publishes nothing), and nothing is withheld;
                // until F46 it was filed under "No configured MCP server offers this — uncheck
                // it here". One whose server has nothing approved is not live: it waits for review,
                // or — every text of it refused — says the person rejected them.
                if MCPToolNaming.isServerGrant(name), state == .live { continue }
                // A per-tool grant that is live and still not shipped fell to something the
                // catalogue does not model; the residual group is where it belongs.
                let group = ToolAvailabilityRequirement.forMCPGrant(state) ?? .mcpToolLive
                unavailable[group, default: []].append(name)
            } else if !installed.contains(name) {
                notInstalled.append(name)
            } else if blocked.contains(name) {
                policyBlocked.append(name)
            } else if let requirement = ToolAvailabilityRequirement.governing(
                name, isDefaultStorage: isDefaultStorage,
                approval: approval,
                meetings: team?.meetingAvailability ?? .available,
                hasTeammatePartner: team?.hasTeammatePartner ?? true,
                askSupervisorEnabled: team?.settings.supervisorMode != .off) {
                unavailable[requirement, default: []].append(name)
            } else {
                // No precondition explains it — the Autovisor's `ask_supervisor`
                // hard gate, or any future structural strip. Reporting it as a
                // user problem would be a lie, so it joins the quiet class.
                policyBlocked.append(name)
            }
        }

        // The coordinator's meeting-only tool — read from the same list the meeting
        // runtime appends (`MeetingCoordinator.speakerTools`), not restated here.
        let isCoordinator = team.map { $0.canHoldMeetings && $0.meetingCoordinatorID == role.id } ?? false
        let meetingOnly = isCoordinator ? MeetingCoordinator.coordinatorOnlyToolNames.sorted() : []
        // The editor holds no vote, but it is not ignorant: which `(requester, target)` pairs
        // are legal is a static property of the team GRAPH, and the graph is what it is
        // editing. So the standing is COMPUTED over every legal pair by the one seat rule,
        // never guessed and never caveated — R4.4.1 forbids a caveat written instead of a
        // computation that was available.
        let chair = team.map { MeetingChairPolicy.voteChairSurvey(in: $0).standing(of: role.id) }
            ?? MeetingChairPolicy.Standing()

        return Model(
            effective: effectiveNames.sorted(),
            // The runtime never injects an MCP tool: one in the effective set that the role does
            // not name is one its whole-server grant brought, which is the role's own choice.
            autoInjected: effectiveNames.subtracting(configured).filter { !MCPToolNaming.isMCPName($0) }.sorted(),
            notInstalled: notInstalled.sorted(),
            policyBlocked: policyBlocked.sorted(),
            unavailableHere: unavailable.mapValues { $0.sorted() },
            meetingOnly: meetingOnly,
            chair: chair
        )
    }

    /// Multi-line `.help()` body. Names render raw (`read_file`) because that is
    /// what every other tool surface in the app shows and what the model is told.
    /// The gavel, in words, and only what was computed.
    ///
    /// What stays genuinely unknowable in the editor is WHICH legal pair occurs at run time,
    /// and naming that is a statement of fact rather than a dodge.
    private static func chairSentence(
        _ standing: MeetingChairPolicy.Standing, roleNames: [String: String]
    ) -> String? {
        var parts: [String] = []
        if standing.chairsMeetings {
            parts.append("Chairs every team meeting.")
            if standing.displacedOnSomeVote {
                let names = standing.standInIDs.compactMap { roleNames[$0] }.sorted()
                let who = names.isEmpty ? "another role" : names.joined(separator: " or ")
                parts.append(
                    "In a request_changes vote where this role is the requester or the target, "
                        + "\(who) takes the chair instead.")
            }
        } else if standing.canChairSomeVote {
            parts.append(
                "Not the meeting coordinator, but takes the chair in a request_changes vote "
                    + "the coordinator is party to.")
        }
        if standing.teamHasUnchairableVotes {
            parts.append(
                "Some vote on this roster would leave nobody impartial, and does not run.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// - Parameter roleNames: definition id → display name, so the tooltip can NAME the role
    ///   the feed will show in the chair. Absent, the sentence falls back to "another role".
    static func tooltip(_ model: Model, roleNames: [String: String] = [:]) -> String {
        var blocks: [String] = []

        let noun = model.count == 1 ? "tool" : "tools"
        blocks.append("\(model.count) \(noun) ship to the model for step execution.")

        let configured = model.configured
        if !configured.isEmpty {
            blocks.append("Selected: " + configured.joined(separator: ", "))
        }
        if !model.autoInjected.isEmpty {
            blocks.append("Auto-injected: " + model.autoInjected.joined(separator: ", "))
        }
        if !model.meetingOnly.isEmpty {
            blocks.append("In meeting turns only (coordinator): " + model.meetingOnly.joined(separator: ", "))
        }
        if let chair = chairSentence(model.chair, roleNames: roleNames) {
            blocks.append(chair)
        }
        // Stable order so the tooltip doesn't reshuffle between renders.
        for requirement in ToolAvailabilityRequirement.allCases {
            guard let names = model.unavailableHere[requirement], !names.isEmpty else { continue }
            blocks.append("\(requirement.unmetHint): " + names.joined(separator: ", "))
        }
        if !model.notInstalled.isEmpty {
            blocks.append("Not installed: " + model.notInstalled.joined(separator: ", "))
        }
        if !model.policyBlocked.isEmpty {
            blocks.append("Not usable from the role toolset: "
                + model.policyBlocked.joined(separator: ", "))
        }

        return blocks.joined(separator: "\n\n")
    }
}
