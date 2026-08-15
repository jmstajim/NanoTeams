import Foundation

/// Extracts the conflicted paths from git's `CONFLICT (<kind>): …` lines.
///
/// This is the ONLY channel by which a role learns WHICH file to open after a failed
/// merge or pull: the conflict envelope is an `ErrorEnvelope` whose `data` is `nil`, so the
/// paths exist nowhere but inside `error.message`. Whatever this returns is the whole
/// answer.
///
/// The message reaches the model as the tool turn itself, and reaches the Supervisor on the
/// tool card (`StepToolCall.errorMessage`). It used to be repeated a third time by the
/// runtime's follow-up turn; that turn now carries direction only
/// (`ToolErrorNotePolicy`), which changes nothing here — the paths were always the
/// message's, never the direction's.
///
/// It used to be `line.range(of: "in ")` — the first ` in ` anywhere in the line. That
/// parses the two `Merge conflict in <path>` shapes and mis-parses the other three,
/// handing the model a branch name, a commit SHA, or a fragment of English prose as the
/// file to open. Measured against git 2.50.1, all five kinds it emits for a two-parent
/// merge:
///
/// ```
/// CONFLICT (content):        Merge conflict in f.txt
/// CONFLICT (add/add):        Merge conflict in both.txt
/// CONFLICT (modify/delete):  doc.txt deleted in other and modified in HEAD.  Version …
/// CONFLICT (rename/delete):  r.txt renamed to r2.txt in HEAD, but deleted in other.
/// CONFLICT (file/directory): directory in the way of thing from HEAD; moving it to …
/// ```
///
/// Paths are parsed by SEPARATOR, never by whitespace tokenisation: git does not quote a
/// path containing spaces and does not escape a non-ASCII one (both measured —
/// `Merge conflict in my file.txt`, `Merge conflict in привет.txt`), so "the first word"
/// would truncate exactly the paths hardest to guess at.
nonisolated enum GitConflictParser {

    /// Every conflicted path named in a git merge/pull's combined output, in the order
    /// git printed them, de-duplicated. Empty when the output names none — which is not
    /// the same as "no conflict", and callers must not treat it as such.
    static func conflictedPaths(in output: String) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for line in output.components(separatedBy: .newlines) where line.contains("CONFLICT") {
            guard let path = conflictedPath(inLine: line), !path.isEmpty else { continue }
            if seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }

    /// Paths with unmerged index entries, parsed from `git ls-files -u` output
    /// (`<mode> <sha> <stage>\t<path>`, one line per stage, so paths repeat).
    ///
    /// This is the AUTHORITATIVE answer to "is the tree conflicted", and the exit status is
    /// not: `merge.autoStash` / `rebase.autoStash` make `git pull` exit **0** after the
    /// merge succeeds and the stash pop conflicts (measured — `Applying autostash resulted
    /// in conflicts.`, exit 0, `UU f.txt`, conflict markers on disk). A handler that reads
    /// only the exit status reports `ok: true` and the model edits a file full of markers.
    static func unmergedPaths(inLsFilesOutput output: String) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for line in output.components(separatedBy: .newlines) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let path = String(line[line.index(after: tab)...])
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return paths
    }

    /// The conflicted path in ONE `CONFLICT (<kind>): <message>` line, or `nil` when the
    /// line does not carry the `): ` separator that introduces the message.
    static func conflictedPath(inLine line: String) -> String? {
        guard let sep = line.range(of: "): ") else { return nil }
        let message = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)

        // content, add/add — the rest of the line IS the path, spaces and all. No
        // punctuation is stripped here: git ends this shape at the path, so anything
        // trailing belongs to the filename.
        if let r = message.range(of: mergeConflictPrefix), r.lowerBound == message.startIndex {
            return trim(String(message[r.upperBound...]))
        }
        // rename/delete — checked BEFORE modify/delete's marker, which this shape also
        // contains ("… renamed to r2.txt in HEAD, but deleted in other."). Reversing the
        // two yields `r.txt renamed to r2.txt in HEAD, but` as the "path".
        if let r = message.range(of: " renamed to ") {
            return trim(String(message[..<r.lowerBound]))
        }
        // modify/delete — the path leads the message.
        if let r = message.range(of: " deleted in ") {
            return trim(String(message[..<r.lowerBound]))
        }
        // file/directory — the path sits between two fixed phrases. `.backwards` on the
        // trailing one so a path that itself contains ` from ` survives.
        if let r = message.range(of: directoryPrefix), r.lowerBound == message.startIndex {
            let rest = String(message[r.upperBound...])
            if let from = rest.range(of: " from ", options: .backwards) {
                return trim(String(rest[..<from.lowerBound]))
            }
            return strippingSentencePunctuation(rest)
        }
        // An unrecognised kind (rename/rename, submodule, a future wording). Returning the
        // whole message beats returning nil: it still names the files, and the alternative
        // is telling the model to resolve a conflict without saying where. This is the one
        // branch whose value is prose, so it is also the only one worth de-punctuating.
        return strippingSentencePunctuation(message)
    }

    private static let mergeConflictPrefix = "Merge conflict in "
    private static let directoryPrefix = "directory in the way of "

    private static func trim(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
    }

    private static func strippingSentencePunctuation(_ raw: String) -> String {
        var s = trim(raw)
        while s.hasSuffix(".") || s.hasSuffix(";") || s.hasSuffix(",") {
            s = trim(String(s.dropLast()))
        }
        return s
    }
}
