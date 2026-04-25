import Foundation

/// Shared directory-walk skip rules for `SearchTool`, `ListFilesTool`, and
/// `SearchIndexService`.
///
/// These names are excluded anywhere we walk the work folder for search /
/// indexing purposes. The set is intentionally generous toward noisy build /
/// dependency folders — `node_modules` and the like can each blow up file
/// counts by 10–100× without contributing relevant vocabulary.
enum WalkSkipRules {
    /// Directory and file names skipped during recursive walks.
    ///
    /// Includes legacy dotfile noise (`.DS_Store`, `.git`, `.svn`, `.hg`,
    /// `.build`) plus ecosystem-standard dependency/output folders that
    /// dominate file counts when present (`node_modules`, `Pods`,
    /// `DerivedData`, `vendor`, `third_party`, `.swiftpm`).
    static let skipped: Set<String> = [
        ".DS_Store", ".git", ".svn", ".hg", ".build",
        "node_modules", "Pods", "DerivedData", "vendor", "third_party", ".swiftpm",
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
}
