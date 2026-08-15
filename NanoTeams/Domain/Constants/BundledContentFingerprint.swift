import Foundation

// MARK: - Bundled Content Fingerprint

/// A stable hash of everything the version-bump reconcile ships.
///
/// The reconcile gate is `MARKETING_VERSION`, not content — deliberately, so a
/// user's edits to a system role's prompt survive until the next app upgrade
/// rather than being reverted whenever a bundled string changes.
///
/// The cost of that choice is a silent one: editing a bundled prompt WITHOUT
/// bumping `MARKETING_VERSION` reaches no existing work folder at all, and
/// nothing says so. `BundledContentFingerprintPinTests` closes that by failing
/// when this value moves, with a message pointing at the version to bump.
///
/// Not used at runtime. It exists purely so the omission is loud.
nonisolated enum BundledContentFingerprint {

    /// FNV-1a over exactly the fields `applyBundledContentUpdates` writes.
    ///
    /// Enumerated field by field rather than encoding the teams wholesale: the
    /// bundled models stamp `createdAt`/`updatedAt` from `MonotonicClock` at
    /// construction, so a whole-object encode produces a DIFFERENT value on
    /// every launch — a pin on it would fail constantly and be disabled within a
    /// day. Listing the fields also keeps the fingerprint honest: it moves when
    /// shipped content moves, and not otherwise.
    ///
    /// Computed once per process.
    static let current: String = compute()

    private static func compute() -> String {
        var hash: UInt64 = 0xcbf5_2913_1c93_1e00

        func fold(_ data: Data) {
            for byte in data {
                hash ^= UInt64(byte)
                hash = hash &* 0x1000_0000_01b3
            }
        }
        func fold(_ string: String) { fold(Data(string.utf8)) }
        func fold(_ flag: Bool) { fold(flag ? "1" : "0") }
        func fold(_ strings: [String]) {
            // Sorted: `toolIDs` order is not itself shipped content.
            for s in strings.sorted() { fold(s); fold("\u{1}") }
        }

        let encoder = JSONCoderFactory.makePersistenceEncoder()

        // Teams, sorted by templateID so array order can't move the value.
        let bundled = (Team.defaultTeams + [TeamTemplateFactory.autovisor()])
            .sorted { ($0.templateID ?? "") < ($1.templateID ?? "") }
        for team in bundled {
            fold(team.templateID ?? "")
            fold(team.systemPromptTemplate)
            fold(team.consultationPromptTemplate)
            fold(team.meetingPromptTemplate)
            // `team.settings` is deliberately NOT folded: it carries
            // `Set<String>` members (`invitableRoles`, `acceptanceCheckpoints`)
            // that encode in per-process hash order, so including it made the
            // fingerprint differ on every launch. A pin that fails constantly is
            // a pin everyone disables. Settings changes therefore still need the
            // version bump remembered by hand — narrower coverage, but coverage
            // that works.

            // Step 1 writes these seven fields on every system role.
            for role in team.roles.sorted(by: { ($0.systemRoleID ?? "") < ($1.systemRoleID ?? "") }) {
                fold(role.systemRoleID ?? "")
                fold(role.prompt)
                fold(role.toolIDs)
                fold(role.dependencies.requiredArtifacts)
                fold(role.dependencies.producesArtifacts)
                fold(role.icon)
                fold(role.iconColor)
                fold(role.iconBackground)
                fold(role.usePlanningPhase)
            }
            // Step 4 adds missing system artifacts — names are the identity.
            fold(team.artifacts.filter(\.isSystemArtifact).map(\.name))
        }

        // Step 2 resolves templates through this map for teams whose bundled
        // counterpart may be absent, so it is shipped content in its own right.
        for key in SystemTemplates.templateConfigs.keys.sorted() {
            fold(key)
            if let cfg = SystemTemplates.templateConfigs[key] {
                fold(cfg.system)
                fold(cfg.consultation)
                fold(cfg.meeting)
            }
        }

        // Step 5 merges built-in tool definitions.
        for tool in ToolDefinitionRecord.defaultDefinitions().sorted(by: { $0.id < $1.id }) {
            fold(tool.id)
            fold(tool.name)
            fold(tool.prompt)
            fold(tool.isBuiltIn)
            if let data = try? encoder.encode(tool.parameters) { fold(data) }
        }

        return String(hash, radix: 16)
    }
}
