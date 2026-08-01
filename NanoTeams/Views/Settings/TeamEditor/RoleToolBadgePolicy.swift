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

    /// Wording shown when the precondition is NOT met. Also used as the tooltip
    /// group header in the role-list badge.
    var unmetHint: String {
        switch self {
        case .visionModel: return "Requires vision model"
        case .computerUse: return "Off in Settings → Computer Use"
        case .gitRepository: return "Requires git repo"
        case .workFolder: return "Requires work folder"
        case .xcodeScheme: return "Requires Xcode scheme"
        }
    }

    /// Wording shown when the precondition IS met, where the surface knows. `nil`
    /// means the tool needs no annotation once available.
    var metHint: String? {
        switch self {
        case .visionModel: return "Vision model configured"
        case .computerUse: return "Computer Use enabled"
        case .gitRepository, .workFolder, .xcodeScheme: return nil
        }
    }

    /// For surfaces that know whether the precondition currently holds.
    func hint(isMet: Bool) -> String {
        isMet ? (metHint ?? unmetHint) : unmetHint
    }

    /// The precondition governing `toolName`, or `nil` when the tool has none.
    ///
    /// Order matters and mirrors the runtime's: a git tool in default storage is
    /// blocked by the missing WORK FOLDER first — reporting "requires git repo"
    /// there would send the user to `git init` in a folder they haven't opened.
    static func governing(_ toolName: String, isDefaultStorage: Bool) -> ToolAvailabilityRequirement? {
        if toolName == ToolNames.analyzeImage { return .visionModel }
        if ToolHandlerRegistry.computerUseTools.contains(toolName) { return .computerUse }
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
        isComputerUseEnabled: Bool,
        autovisorAllowTeamGeneration: Bool,
        fileManager: FileManager = .default
    ) -> Model {
        let shipped = EffectiveToolset.resolve(
            role: role,
            team: team,
            allTeams: allTeams,
            storage: storage,
            selectedScheme: selectedScheme,
            isVisionConfigured: isVisionConfigured,
            isComputerUseEnabled: isComputerUseEnabled,
            autovisorAllowTeamGeneration: autovisorAllowTeamGeneration,
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
            if !installed.contains(name) {
                notInstalled.append(name)
            } else if blocked.contains(name) {
                policyBlocked.append(name)
            } else if let requirement = ToolAvailabilityRequirement.governing(
                name, isDefaultStorage: isDefaultStorage) {
                unavailable[requirement, default: []].append(name)
            } else {
                // No precondition explains it — the Autovisor's `ask_supervisor`
                // hard gate, or any future structural strip. Reporting it as a
                // user problem would be a lie, so it joins the quiet class.
                policyBlocked.append(name)
            }
        }

        return Model(
            effective: effectiveNames.sorted(),
            autoInjected: effectiveNames.subtracting(configured).sorted(),
            notInstalled: notInstalled.sorted(),
            policyBlocked: policyBlocked.sorted(),
            unavailableHere: unavailable.mapValues { $0.sorted() }
        )
    }

    /// Multi-line `.help()` body. Names render raw (`read_file`) because that is
    /// what every other tool surface in the app shows and what the model is told.
    static func tooltip(_ model: Model) -> String {
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
