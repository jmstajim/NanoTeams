import Foundation

/// A round staged under the rules it STARTED under (`SnapshotIgnoreRules` says why).
///
/// git stages under the `.gitignore` files on disk, and nothing makes it read other ones. So
/// a snapshot stages as git does, with the round's `info/exclude` written back, and then — only
/// when the `.gitignore` files moved — corrects the difference by asking git itself, through
/// `check-ignore` over a scratch work tree that holds the round's `.gitignore` files and nothing
/// else: what the moved rules hide and the round's did not is added with `-f`, what a removed
/// rule exposed and the round's ignore is taken out again.
///
/// «Added with `-f`» has a price, and the role sets it: the ordinary first round of a project
/// writes `.gitignore` with `node_modules/` and runs `npm install`, and forcing that in put tens
/// of thousands of files into the private repository and onto the `task_changes` pages (review
/// of 2026-11-12). The point of reading a round by its start rules is that a role cannot HIDE
/// its files from the agent — not that their content reaches a snapshot at any cost. So a
/// directory new in the round that the moved rules hide is reported, not read; single files are
/// staged up to `RoundHiddenStagingLimit`; and what the round's start held is always restored,
/// whatever its size, because leaving it out reads as a deletion (N18).
extension TaskSnapshotService {

    // MARK: - The record

    func storeRoundRules(
        _ rules: SnapshotIgnoreRules, taskID: Int, runID: Int, round: Int, workFolder: URL, gitDir: URL
    ) async throws {
        let scratch = gitDir.appendingPathComponent("nanoteams-rules-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: scratch) }
        try JSONEncoder().encode(rules).write(to: scratch, options: .atomic)
        let hashRes = try await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "hash-object", "-w", "--no-filters", scratch.path],
            in: workFolder, gitDir: gitDir)
        guard hashRes.exitCode == 0 else {
            throw ExternalAutovisorError("Snapshot rules hash-object failed: \(hashRes.stderr)", code: .commandFailed)
        }
        let sha = hashRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let refRes = try await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "update-ref",
             SnapshotIgnoreRules.refName(taskID: taskID, runID: runID, round: round), sha],
            in: workFolder, gitDir: gitDir)
        guard refRes.exitCode == 0 else {
            throw ExternalAutovisorError("Snapshot rules update-ref failed: \(refRes.stderr)", code: .commandFailed)
        }
    }

    /// The rules a round started under, or `nil` for a round recorded before they were kept.
    func loadRoundRules(taskID: Int, runID: Int, round: Int, workFolder: URL, gitDir: URL) async -> SnapshotIgnoreRules? {
        let ref = SnapshotIgnoreRules.refName(taskID: taskID, runID: runID, round: round)
        guard let res = try? await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "cat-file", "blob", ref], in: workFolder, gitDir: gitDir),
              res.exitCode == 0
        else { return nil }
        return try? JSONDecoder().decode(SnapshotIgnoreRules.self, from: res.stdoutData)
    }

    func deleteRoundRules(taskID: Int, workFolder: URL, gitDir: URL) async {
        guard let res = try? await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "for-each-ref", "--format=%(refname)",
             SnapshotIgnoreRules.refPrefix(taskID: taskID)],
            in: workFolder, gitDir: gitDir)
        else { return }
        for ref in res.stdout.split(separator: "\n").map(String.init) where !ref.isEmpty {
            _ = try? await runPrivateGit(
                ["--git-dir=\(gitDir.path)", "update-ref", "-d", ref], in: workFolder, gitDir: gitDir)
        }
    }

    // MARK: - Files a snapshot could not show

    /// The commit-message line an end snapshot keeps its not-shown files in, so a later
    /// `task_changes` of that round reports them as the live diff did.
    nonisolated static let notShownTrailer = "Not-Shown: "

    nonisolated static func notShownTrailerLine(_ paths: [String]) -> String? {
        guard !paths.isEmpty, let json = try? JSONEncoder().encode(paths) else { return nil }
        return notShownTrailer + json.base64EncodedString()
    }

    func readNotShown(endRef: String, workFolder: URL, gitDir: URL) async -> [String] {
        guard let res = try? await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "cat-file", "commit", endRef], in: workFolder, gitDir: gitDir),
              res.exitCode == 0
        else { return [] }
        for line in res.stdout.split(separator: "\n") where line.hasPrefix(Self.notShownTrailer) {
            let encoded = String(line.dropFirst(Self.notShownTrailer.count))
            if let data = Data(base64Encoded: encoded),
               let paths = try? JSONDecoder().decode([String].self, from: data) {
                return paths
            }
        }
        return []
    }

    // MARK: - The correction

    /// Brings the private index from "staged under the rules on disk" to "staged under the
    /// round's rules". Returns what the round's rules show and the snapshot does not: the files
    /// that could not be staged, the files past `RoundHiddenStagingLimit`, and every directory
    /// new in the round that the moved rules hide (with a trailing `/`, never read).
    func restoreRoundRules(
        _ rules: SnapshotIgnoreRules,
        workFolder: URL,
        gitDir: URL,
        resolver: SandboxPathResolver,
        exclusions: [String],
        embedded: Set<String>,
        startRef: String?
    ) async throws -> [String] {
        let scratchTree = fileManager.temporaryDirectory
            .appendingPathComponent("nanoteams-round-rules-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratchTree, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratchTree) }
        for (relative, content) in rules.ignoreFiles {
            let url = scratchTree.appendingPathComponent(relative)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url)
        }

        // 1. What the rules on disk hide — files, and whole directories collapsed.
        var listArgs = [
            "--git-dir=\(gitDir.path)", "--work-tree=\(workFolder.path)",
            "ls-files", "-o", "-i", "--exclude-standard", "--directory", "--no-empty-directory", "-z"
        ]
        if !exclusions.isEmpty {
            listArgs.append("--")
            listArgs.append(contentsOf: exclusions)
        }
        let listRes = try await runPrivateGit(listArgs, in: workFolder, gitDir: gitDir)
        guard listRes.exitCode == 0 else {
            throw ExternalAutovisorError("Snapshot ls-files failed: \(listRes.stderr)", code: .commandFailed)
        }

        // 2. Of those, what the round's rules show. A directory the start held is opened a level
        //    at a time (a subtree the round's rules ignore is never walked); a directory NEW in the
        //    round is one not-shown entry, unread. A file the start held is restored; a new one
        //    is staged within the limit.
        //    `ls-files --directory` names a collapsed directory regardless of an `:(exclude)`
        //    pathspec — measured on git 2.54 (2026-11-12): `sub/` listed beside
        //    `:(exclude,literal)sub` — so what the excludes stand for is applied here as well, by
        //    the rule `children` applies a level down.
        var level = parseNullDelimitedTokens(data: listRes.stdoutData).filter { entry in
            guard !entry.isEmpty else { return false }
            let path = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            return !embedded.contains(path)
                && resolver.permits(canonicalPath: resolver.canonicalRoot + "/" + path)
        }
        let start = try await startTreeEntries(
            startRef, under: level, workFolder: workFolder, gitDir: gitDir)
        var restored: [String] = []
        var fresh: [String] = []
        var unreadDirectories: [String] = []
        while !level.isEmpty {
            let ignored = try await ignoredPaths(level, workTree: scratchTree, gitDir: gitDir)
            var next: [String] = []
            for entry in level where !ignored.contains(entry) {
                if entry.hasSuffix("/") {
                    let directory = String(entry.dropLast())
                    guard start.directories.contains(directory) else {
                        unreadDirectories.append(entry)
                        continue
                    }
                    next.append(contentsOf: children(
                        ofDirectory: directory, in: workFolder, resolver: resolver, embedded: embedded))
                } else if start.files.contains(entry) {
                    restored.append(entry)
                } else {
                    fresh.append(entry)
                }
            }
            level = next
        }
        let plan = Self.planRoundHiddenStaging(
            fresh.map { ($0, fileSize(workFolder.appendingPathComponent($0))) }, limit: .standard)
        let failed = try await forceAdd(restored + plan.stage, workFolder: workFolder, gitDir: gitDir)
        let notShown = Set(unreadDirectories + Self.listedSkippedPaths(plan.skipped, limit: .standard) + failed)
            .sorted()

        // 3. What a REMOVED rule exposed: staged now, absent at the start, ignored by the round.
        if let startRef {
            let addedRes = try await runPrivateGit(
                ["--git-dir=\(gitDir.path)", "--work-tree=\(workFolder.path)",
                 "diff-index", "--cached", "--name-only", "--no-renames", "--diff-filter=A", "-z", startRef],
                in: workFolder, gitDir: gitDir)
            if addedRes.exitCode == 0 {
                let added = parseNullDelimitedTokens(data: addedRes.stdoutData).filter { !$0.isEmpty }
                let exposed = try await ignoredPaths(added, workTree: scratchTree, gitDir: gitDir)
                if !exposed.isEmpty {
                    try await runPathListCommand(
                        ["rm", "--cached", "-f", "-q", "--ignore-unmatch"], paths: exposed.sorted(),
                        workFolder: workFolder, gitDir: gitDir)
                }
            }
        }
        return notShown
    }

    // MARK: - The start tree and the file sizes the limit reads

    /// The files and directories the round's start tree holds at or under `entries` (as
    /// `ls-files` names them, a directory with a trailing `/`), and their ancestor directories.
    /// Empty without a start — every entry is then new in the round.
    private func startTreeEntries(
        _ startRef: String?, under entries: [String], workFolder: URL, gitDir: URL
    ) async throws -> (files: Set<String>, directories: Set<String>) {
        guard let startRef, !entries.isEmpty else { return ([], []) }
        var files = Set<String>()
        var directories = Set<String>()
        let paths = entries.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        for batch in Self.argumentBatches(paths) {
            let res = try await runPrivateGit(
                ["--git-dir=\(gitDir.path)", "--literal-pathspecs", "ls-tree", "-r", "-t", "-z", startRef, "--"]
                    + batch,
                in: workFolder, gitDir: gitDir)
            guard res.exitCode == 0 else {
                throw ExternalAutovisorError("Snapshot ls-tree failed: \(res.stderr)", code: .commandFailed)
            }
            // `<mode> SP <type> SP <object> TAB <path>`, NUL-terminated.
            for record in parseNullDelimitedTokens(data: res.stdoutData) {
                guard let tab = record.firstIndex(of: "\t") else { continue }
                let path = String(record[record.index(after: tab)...])
                if record[..<tab].split(separator: " ").dropFirst().first == "tree" {
                    directories.insert(path)
                } else {
                    files.insert(path)
                }
            }
        }
        return (files, directories)
    }

    /// The size of a file, a symlink counted as itself; 0 for what is gone — staging skips it.
    private func fileSize(_ url: URL) -> Int {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// The entries of one directory as `ls-files` names them — files bare, directories with a
    /// trailing `/` — leaving out what git never stages (`.git`, sockets) and what a snapshot
    /// never stages (an embedded repository, a hidden location).
    private func children(
        ofDirectory relative: String, in workFolder: URL, resolver: SandboxPathResolver, embedded: Set<String>
    ) -> [String] {
        let directory = workFolder.appendingPathComponent(relative, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [])
        else { return [] }
        var out: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != ".git" else { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            guard resolver.permits(canonicalPath: resolver.canonicalRoot + "/" + path) else { continue }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true || values?.isRegularFile == true {
                out.append(path)
            } else if values?.isDirectory == true {
                guard !embedded.contains(path),
                      !fileManager.fileExists(atPath: entry.appendingPathComponent(".git").path)
                else { continue }
                out.append(path + "/")
            }
        }
        return out
    }

    /// Which of `paths` git's own matcher ignores in `workTree` — its `.gitignore` files, the
    /// store's `info/exclude` (written already) and the person's global file. Over the round's
    /// scratch tree that is the round's rules; over the work folder, the rules `add -A` reads.
    func ignoredPaths(
        _ paths: [String], workTree: URL, gitDir: URL
    ) async throws -> Set<String> {
        var ignored = Set<String>()
        for batch in Self.argumentBatches(paths) {
            // `./` keeps a name that starts with `:` from reading as pathspec magic.
            let args = [
                "--git-dir=\(gitDir.path)", "--work-tree=\(workTree.path)",
                "-c", "core.quotePath=false", "check-ignore", "--no-index", "--"
            ] + batch.map { "./" + $0 }
            let res = try await runPrivateGit(args, in: workTree, gitDir: gitDir)
            guard res.exitCode == 0 || res.exitCode == 1 else {
                throw ExternalAutovisorError("Snapshot check-ignore failed: \(res.stderr)", code: .commandFailed)
            }
            for line in res.stdoutData.split(separator: UInt8(ascii: "\n")) {
                var path = Self.unquotedGitPath(Data(line))
                if path.hasPrefix("./") { path.removeFirst(2) }
                ignored.insert(path)
            }
        }
        return ignored
    }

    /// `git add -f` of every path, and — when the batch fails — of each one alone. Returns the
    /// paths that exist and still could not be staged.
    private func forceAdd(_ paths: [String], workFolder: URL, gitDir: URL) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        do {
            try await runPathListCommand(["add", "-f"], paths: paths, workFolder: workFolder, gitDir: gitDir)
            return []
        } catch {
            var notShown: [String] = []
            for path in paths {
                guard (try? fileManager.attributesOfItem(
                    atPath: workFolder.appendingPathComponent(path).path)) != nil
                else { continue }   // gone since it was listed: nothing to show
                do {
                    try await runPathListCommand(["add", "-f"], paths: [path], workFolder: workFolder, gitDir: gitDir)
                } catch {
                    notShown.append(path)
                }
            }
            return notShown
        }
    }

    /// Runs a git command over a NUL-separated pathspec file of literal paths.
    private func runPathListCommand(
        _ command: [String], paths: [String], workFolder: URL, gitDir: URL
    ) async throws {
        let list = gitDir.appendingPathComponent("nanoteams-paths-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: list) }
        var data = Data()
        for path in paths {
            data.append(Data(path.utf8))
            data.append(0)
        }
        try data.write(to: list, options: .atomic)
        let args = ["--git-dir=\(gitDir.path)", "--work-tree=\(workFolder.path)", "--literal-pathspecs"]
            + command + ["--pathspec-from-file=\(list.path)", "--pathspec-file-nul"]
        let res = try await runPrivateGit(args, in: workFolder, gitDir: gitDir)
        guard res.exitCode == 0 else {
            throw ExternalAutovisorError("Snapshot \(command.first ?? "git") failed: \(res.stderr)", code: .commandFailed)
        }
    }

    // MARK: - Helpers

    /// Path lists cut to stay well under the argument limit.
    nonisolated static func argumentBatches(_ paths: [String], maxBytes: Int = 128 * 1024) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var bytes = 0
        for path in paths {
            let size = path.utf8.count + 3
            if !current.isEmpty && bytes + size > maxBytes {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(path)
            bytes += size
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// A path as git prints it outside `-z`: bare, or C-quoted (`"a\"b"`, `\n`, `\t`, octal)
    /// when it holds a quote, a backslash or a control character.
    nonisolated static func unquotedGitPath(_ line: Data) -> String {
        let bytes = [UInt8](line)
        guard bytes.count >= 2, bytes.first == UInt8(ascii: "\""), bytes.last == UInt8(ascii: "\"") else {
            return String(decoding: bytes, as: UTF8.self)
        }
        var out: [UInt8] = []
        var index = 1
        let end = bytes.count - 1
        while index < end {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < end else {
                out.append(byte)
                index += 1
                continue
            }
            let next = bytes[index + 1]
            switch next {
            case UInt8(ascii: "a"): out.append(0x07); index += 2
            case UInt8(ascii: "b"): out.append(0x08); index += 2
            case UInt8(ascii: "t"): out.append(0x09); index += 2
            case UInt8(ascii: "n"): out.append(0x0A); index += 2
            case UInt8(ascii: "v"): out.append(0x0B); index += 2
            case UInt8(ascii: "f"): out.append(0x0C); index += 2
            case UInt8(ascii: "r"): out.append(0x0D); index += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = 0
                var digits = 0
                while digits < 3, index + 1 + digits < end,
                      (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[index + 1 + digits]) {
                    value = value * 8 + Int(bytes[index + 1 + digits] - UInt8(ascii: "0"))
                    digits += 1
                }
                out.append(UInt8(truncatingIfNeeded: value))
                index += 1 + digits
            default:
                out.append(next)
                index += 2
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
