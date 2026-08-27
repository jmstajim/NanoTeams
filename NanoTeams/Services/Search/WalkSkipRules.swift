import Foundation

/// Shared directory-walk skip rules for `SearchTool`, `ListFilesTool`, and
/// `SearchIndexService`.
///
/// These names are excluded anywhere we walk the work folder for search /
/// indexing purposes. The set is intentionally generous toward noisy build /
/// dependency folders — `node_modules` and the like can each blow up file
/// counts by 10–100× without contributing relevant vocabulary.
nonisolated enum WalkSkipRules {
    /// Directory and file names skipped during recursive walks.
    ///
    /// Matching is on the BARE NAME AT ANY DEPTH, which is what bounds the list: a name is only
    /// eligible if it could never plausibly be a hand-authored source directory anywhere in a
    /// tree. `build`, `dist`, `target`, `out`, `bin` and `obj` are deliberately ABSENT for
    /// exactly that reason — skipping them would silently swallow `src/build/` and
    /// `Sources/dist/`. Making those cheap is the binary gate's job, not this list's.
    ///
    /// Five subsystems share this set — `SearchExecutor`, `list_files`, `SearchIndexService`,
    /// `AgentInstructionsScanner` and `AgentSkillsScanner` — so an addition also changes what
    /// `list_files` reports and where `AGENTS.md` / `SKILL.md` can be discovered. None of the
    /// names here collide with an agent-instruction root (`claude.md`, `agents.md`, `gemini.md`,
    /// `.cursorrules`, `.github/…`, `.windsurfrules`) or a skill source (`.claude`, `.codex`,
    /// `.cursor`, `.gemini`, `.github`, `.windsurf`, `.opencode`, `.codeium`).
    ///
    /// They reach it through `shouldSkip(name:)`, not through this property — see the note there.
    static let skipped: Set<String> = [
        // VCS + macOS noise
        ".DS_Store", ".git", ".svn", ".hg",
        // Swift / Apple
        ".build", "Pods", "DerivedData", ".swiftpm", "Carthage",
        // JS / web
        "node_modules", "bower_components", ".next", ".nuxt", ".turbo", ".parcel-cache",
        // Python
        "__pycache__", "venv", ".venv", ".tox", ".mypy_cache", ".pytest_cache",
        // JVM / infra / editors
        ".gradle", ".terraform", ".idea", ".vscode",
        // Generic vendored + cache trees
        "vendor", "third_party", ".cache",
    ]

    /// Files skipped only when they live directly inside `.nanoteams/`. These
    /// are bookkeeping markers created by `NTMSRepository.ensureLayout`
    /// (`.gitignore` pointing git away from `internal/`) that contribute
    /// noise tokens without reflecting user content. We explicitly do NOT
    /// wholesale-skip `.nanoteams/` — `tasks/{id}/attachments/` and
    /// `runs/.../artifact_*.md` under it are LLM-visible user content and
    /// should be searchable. `internal/` is already excluded at walk time
    /// via `SandboxPathResolver.isWithin(internalDir)`.
    static let skippedInsideNanoteamsDir: Set<String> = [".gitignore"]

    /// Bundle EXTENSIONS skipped at any depth, whatever the bundle is named.
    ///
    /// `skipped` above cannot express these: it matches a bare name exactly, and these bundles
    /// are named by whoever produced them — `latest.xcresult`, `Test-NanoTeams-2026.08.21….
    /// xcresult`. Measured on this work folder: 76 474 files, **73% of everything the walk
    /// enumerated**, live inside four `.xcresult` directories that no rule here matched.
    ///
    /// They satisfy the same criterion as the names above — an extension that could never
    /// plausibly be a hand-authored source directory — and the payoff is not the walk but the
    /// READ: a sequential grep of this folder measured 8.69 s with the old rules and 0.73 s
    /// without those bundles, which is a bigger factor than the parallel scan buys.
    static let skippedBundleExtensions: Set<String> = ["xcresult", "xcappdata"]

    /// The one question every walk asks about an entry.
    ///
    /// A predicate rather than an exported set, because the rule stopped being expressible as
    /// one: five subsystems consume it (`SearchExecutor`, `list_files`, `SearchIndexService`,
    /// `AgentInstructionsScanner`, `AgentSkillsScanner`) and each used to write its own
    /// `WalkSkipRules.skipped.contains(name)`. Adding the extension rule to a SET would have
    /// meant editing five call sites to ask two questions instead of one, and the sixth walk
    /// written next year would ask one — which is CLAUDE.md #51 exactly. Now a new rule lands
    /// here and every walk gets it.
    static func shouldSkip(name: String) -> Bool {
        if skipped.contains(name) { return true }
        // `pathExtension` and not `hasSuffix(".xcresult")`: the suffix form also matches a file
        // literally named `.xcresult`, and it is the spelling that invites `hasSuffix("result")`
        // in the next edit.
        return skippedBundleExtensions.contains(
            (name as NSString).pathExtension.lowercased())
    }
}
