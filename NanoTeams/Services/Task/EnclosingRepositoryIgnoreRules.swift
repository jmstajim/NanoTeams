import Foundation

/// The ignore rules of a repository that ENCLOSES the work folder, restated for the work folder
/// (N19, 2026-11-12).
///
/// Snapshots stage with `--work-tree=<work folder>`, and git reads `.gitignore` from the work
/// tree's root DOWN — so for `/repo/app` the `/repo/.gitignore` and `/repo/.git/info/exclude`
/// the person's own git applies were never read, and `node_modules/` or `.env` ignored there
/// reached every snapshot. They reach git now through the one file a snapshot can steer,
/// `snapshots.git/info/exclude`, whose patterns are relative to the work folder: each enclosing
/// pattern is rewritten from the directory it was written in to the work folder.
///
/// - A pattern without a slash matches a name at any depth and is kept as it is.
/// - An anchored pattern is matched component by component against the path from its
///   directory down to the work folder (`**` spans components, every other component is a
///   glob), and what remains of it is anchored at the work folder. A pattern that ends on the
///   way down, or that would leave only `*` or `**` — or an unanchored `*` — names the work
///   folder itself or all of it, and is NOT applied: the work folder is what a review looks at, and a repository that
///   ignores it whole would leave `task_changes` nothing to show.
/// - Negation and a trailing `/` survive; comments, blank lines and trailing unescaped
///   spaces go, as git drops them.
///
/// Read-only: the enclosing repository's configuration is never read, so nothing in it runs.
nonisolated enum EnclosingRepositoryIgnoreRules {

    /// The nearest directory ABOVE `workFolder` that holds a `.git` (a directory or a gitfile),
    /// or `nil` — always `nil` when the work folder is a repository of its own, since git stops
    /// at the first `.git` it meets.
    static func enclosingRepositoryRoot(of workFolder: URL, fileManager: FileManager = .default) -> URL? {
        let work = workFolder.standardizedFileURL
        if fileManager.fileExists(atPath: work.appendingPathComponent(".git").path) { return nil }
        var candidate = work.deletingLastPathComponent()
        while candidate.path != "/" && !candidate.path.isEmpty {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return nil
    }

    /// One ignore file's content restated for a work folder that lies `relative` below the
    /// directory the file applies to. Lines of output, in input order, ready for `info/exclude`.
    static func translate(_ content: String, workFolderBelow relative: [String]) -> [String] {
        guard !relative.isEmpty else { return [] }
        return content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { translateLine(String($0), relative: relative) }
    }

    static func translateLine(_ rawLine: String, relative: [String]) -> [String] {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        line = trimmingUnescapedTrailingSpaces(line)
        if line.isEmpty || line.hasPrefix("#") { return [] }

        var negated = false
        if line.hasPrefix("!") {
            negated = true
            line.removeFirst()
        }
        var directoryOnly = false
        if line.hasSuffix("/") && !line.hasSuffix("\\/") {
            directoryOnly = true
            line.removeLast()
        }
        guard !line.isEmpty else { return [] }

        let prefix = negated ? "!" : ""
        let suffix = directoryOnly ? "/" : ""
        guard line.contains("/") else {
            // `*` (or `**`) alone matches every name at every depth: the whole folder — as a
            // dotfiles repository in the home directory writes it (`*`, then `!.zshrc` …).
            return isWholeFolder([line]) && !negated ? [] : [prefix + line + suffix]
        }
        if line.hasPrefix("/") { line.removeFirst() }
        let components = line.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var seen = Set<[String]>()
        var out: [String] = []
        for remainder in remainders(of: components, from: 0, consuming: relative, at: 0)
        where !remainder.isEmpty && !isWholeFolder(remainder) && seen.insert(remainder).inserted {
            out.append(prefix + "/" + remainder.joined(separator: "/") + suffix)
        }
        return out
    }

    /// What is left of `pattern[pi...]` once it has matched every component of `path[ri...]`.
    private static func remainders(
        of pattern: [String], from pi: Int, consuming path: [String], at ri: Int
    ) -> [[String]] {
        if ri == path.count { return [Array(pattern[pi...])] }
        guard pi < pattern.count else { return [] }
        if pattern[pi] == "**" {
            return remainders(of: pattern, from: pi + 1, consuming: path, at: ri)
                + remainders(of: pattern, from: pi, consuming: path, at: ri + 1)
        }
        guard componentMatches(pattern[pi], path[ri]) else { return [] }
        return remainders(of: pattern, from: pi + 1, consuming: path, at: ri + 1)
    }

    private static func componentMatches(_ glob: String, _ name: String) -> Bool {
        fnmatch(glob, name, 0) == 0
    }

    private static func isWholeFolder(_ remainder: [String]) -> Bool {
        remainder == ["**"] || remainder == ["*"]
    }

    private static func trimmingUnescapedTrailingSpaces(_ line: String) -> String {
        var scalars = Array(line.unicodeScalars)
        while let last = scalars.last, last == " " {
            let backslashes = scalars.dropLast().reversed().prefix { $0 == "\\" }.count
            if backslashes % 2 == 1 { break }
            scalars.removeLast()
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }
}
