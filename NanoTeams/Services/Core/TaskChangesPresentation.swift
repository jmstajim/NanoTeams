import Foundation

/// What `task_changes` hands an external agent, from what the snapshot read (S5 and N8,
/// 2026-11-12).
///
/// Every name — a path, an old path, a not-tracked path — is shown with each hidden character
/// TAGGED (`MCPTextSanitizer.taggedName`), and that spelling is what `file_path` accepts back.
/// Until then names went through `singleLine`, which REMOVES the very characters the warning
/// check then looked for, so a name hiding U+202E was silently renamed and never warned about,
/// and the agent's `file_path` for the name it was shown matched nothing. The diff is
/// sanitized FILE BY FILE (`TaskSnapshotService.PageFileDiff`), so a warning names the file a
/// hidden character was found in — not, as before, every file of the round.
nonisolated enum TaskChangesPresentation {

    struct Presented {
        var result: TaskSnapshotService.TaskChangesResult
        var warnings: [String]
        /// The agent-visible text an injection scan reads.
        var scanTargets: [String]
    }

    static func present(_ changes: TaskSnapshotService.TaskChangesResult) -> Presented {
        var warnings: [String] = []
        var result = changes

        result.files = changes.files.map { file in
            let path = MCPTextSanitizer.taggedName(file.path)
            if path.hadStripped { warnings.append(TaskChangesWarnings.hiddenCharactersInName(path.text)) }
            var shown = file
            shown.path = path.text
            shown.change_type = MCPTextSanitizer.taggedName(file.change_type).text
            if let oldPath = file.old_path {
                let old = MCPTextSanitizer.taggedName(oldPath)
                if old.hadStripped { warnings.append(TaskChangesWarnings.hiddenCharactersInName(old.text)) }
                shown.old_path = old.text
            }
            return shown
        }
        result.not_tracked = changes.not_tracked.map { entry in
            let path = MCPTextSanitizer.taggedName(entry.path)
            if path.hadStripped { warnings.append(TaskChangesWarnings.hiddenCharactersInName(path.text)) }
            return .init(path: path.text, reason: entry.reason)
        }

        if !changes.store_repairs.isEmpty {
            warnings.append(TaskChangesWarnings.storeRestored(changes.store_repairs))
        }
        result.store_repairs = []

        // `changes.diff` is these parts joined; the parts are read so each warning has its file.
        var diff = ""
        for fileDiff in changes.page_diffs {
            let shownPath = MCPTextSanitizer.taggedName(fileDiff.path).text
            let sanitized = MCPTextSanitizer.sanitizeDiff(fileDiff.text)
            if sanitized.hadStripped { warnings.append(TaskChangesWarnings.hiddenCharactersInDiff(shownPath)) }
            if fileDiff.notUTF8 { warnings.append(TaskChangesWarnings.notUTF8(shownPath)) }
            diff += sanitized.text
        }
        result.diff = diff
        result.page_diffs = []

        let scanTargets = [diff]
            + result.files.map(\.path)
            + result.files.compactMap(\.old_path)
            + result.not_tracked.map(\.path)
        return Presented(result: result, warnings: warnings, scanTargets: scanTargets)
    }
}

/// The `meta.warnings` lines `task_changes` writes about a page.
nonisolated enum TaskChangesWarnings {
    /// runtime-prompt
    static func hiddenCharactersInName(_ shownName: String) -> String {
        "File name '\(shownName)' contains hidden characters, shown as <U+XXXX> tags; pass it to file_path as shown."
    }

    /// runtime-prompt
    static func hiddenCharactersInDiff(_ shownName: String) -> String {
        "File '\(shownName)' contains hidden characters in diff, shown as <U+XXXX> tags."
    }

    /// runtime-prompt
    static func notUTF8(_ shownName: String) -> String {
        "File '\(shownName)' is not valid UTF-8; each byte that is not is shown in diff as <0xNN>."
    }

    /// runtime-prompt
    /// `parts` are the fixed labels `TaskSnapshotService.restoreStore` reports (S1, F6
    /// 2026-11-12) — never a name from the store itself.
    static func storeRestored(_ parts: [String]) -> String {
        "Something other than NanoTeams changed the private snapshot store during this pass (\(parts.joined(separator: ", "))); NanoTeams restored it before taking or reading any snapshot."
    }

    /// The lines a page carries about its round's snapshots that did not land in time (N2 of the
    /// F6 acceptance, 2026-11-12) — read off `Run.snapshotFailures`. A start record on a round
    /// whose diff exists means the start landed late; an end record matters only once the round
    /// has ended, since an open round is read against the work tree anyway.
    static func snapshotFailures(_ failures: [RunSnapshotFailure], round: Int, roundIsOpen: Bool) -> [String] {
        let ofRound = failures.filter { $0.round == round }
        var lines: [String] = []
        if ofRound.contains(where: { $0.phase == .start }) {
            lines.append(lateStartSnapshot(round: round))
        }
        if !roundIsOpen,
           let end = ofRound.filter({ $0.phase.endsRound }).max(by: { $0.recordedAt < $1.recordedAt }) {
            lines.append(endSnapshotMissing(round: round, reason: end.reason))
        }
        return lines
    }

    /// runtime-prompt
    static func lateStartSnapshot(round: Int) -> String {
        "The snapshot that opened pass \(round) finished after the pass began, so changes made in its first moments may be missing from this diff."
    }

    /// runtime-prompt
    static func endSnapshotMissing(round: Int, reason: RunSnapshotFailure.Reason) -> String {
        switch reason {
        case .timedOut:
            return "The snapshot taken when pass \(round) ended had not finished, so this diff may show changes made after the pass ended."
        case .failed:
            return "The snapshot taken when pass \(round) ended failed, so this diff may show changes made after the pass ended."
        case .completedLate:
            return "The snapshot taken when pass \(round) ended finished late, so this diff may hold changes made after the pass ended."
        }
    }
}
