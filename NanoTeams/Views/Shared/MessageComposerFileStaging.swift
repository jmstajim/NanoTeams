import Foundation

/// Pure file-staging validation lifted out of `MessageComposer.stageURLs` so the
/// directory-rejection, dedup, rejection-collection, and error-aggregation rules are
/// unit-testable without a view. The security-scoped resource access + the actual stage
/// call stay in the injected `stage` closure (the view owns that side effect); this enum
/// owns only the pure batch logic.
///
/// `nonisolated` (house pattern: `MessageComposerPasteHandler`, `MessageKeyPolicy`) —
/// `StagedAttachment` and `URL` are both nonisolated, so the helper composes from any
/// context including a non-`@MainActor` test.
nonisolated enum MessageComposerFileStaging {

    struct Result: Equatable {
        /// New attachments to append, deduped (against `existing` and within the batch),
        /// in input order.
        var staged: [StagedAttachment]
        /// `lastPathComponent` of each rejected URL (a directory, or a `stage` failure),
        /// in input order — for the aggregated "Could not attach: …" banner.
        var rejected: [String]
    }

    /// Validates + dedups a batch of dropped/picked/pasted URLs. Directories are rejected
    /// (can't be staged) WITHOUT invoking `stage`. For each file URL, `stage` is called —
    /// it owns the security-scoped access and returns `nil` on failure (→ rejected).
    /// Successful attachments are deduped against `existing` AND within the batch
    /// (`StagedAttachment` equates by `stagedRelativePath`), preserving order. Equivalent
    /// to the original per-item `!attachments.contains` loop, where `existing` is the
    /// attachment list at call time.
    static func validateAndStage(
        urls: [URL],
        existing: [StagedAttachment],
        stage: (URL) -> StagedAttachment?
    ) -> Result {
        var staged: [StagedAttachment] = []
        var rejected: [String] = []
        for url in urls {
            if url.hasDirectoryPath {
                rejected.append(url.lastPathComponent)
                continue
            }
            guard let attachment = stage(url) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            if !existing.contains(attachment) && !staged.contains(attachment) {
                staged.append(attachment)
            }
        }
        return Result(staged: staged, rejected: rejected)
    }

    /// Appends `new` to `existing` with a newline so a second failure doesn't silently
    /// overwrite the first. A nil/empty `existing` returns `new` verbatim.
    static func aggregateErrorMessage(existing: String?, new: String) -> String {
        if let existing, !existing.isEmpty { return existing + "\n" + new }
        return new
    }
}
