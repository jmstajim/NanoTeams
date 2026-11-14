import Foundation

/// How a snapshot decides WHAT it stages: which files are ignored, which directories are
/// embedded repositories, and — since F6 (2026-11-12) — under whose rules a round is read.
/// `SnapshotIgnoreRules` says why a round keeps the rules it started under.
extension TaskSnapshotService {

    /// The tree a snapshot or the live diff staged, the embedded repositories it left out, and
    /// the files hidden by rules written during the round that it could not stage even so.
    struct StagedTree: Sendable {
        let tree: String
        let embeddedRepositories: [String]
        let notShown: [String]
        /// The rules the work tree holds now — what a START snapshot records for its round.
        let currentRules: SnapshotIgnoreRules
    }

    /// One walk of the work tree: embedded repositories, and every `.gitignore` git would read.
    struct WorkTreeScan: Sendable {
        var embeddedRepositories: [String] = []
        var ignoreFiles: [String] = []
    }

    // MARK: - Paths

    /// `target` relative to `base`, cut by path COMPONENTS: `nil` outside `base`, `"."` for
    /// `base` itself. Until 2026-11-12 it dropped `prefix.utf8.count` CHARACTERS, so under a
    /// work folder whose path held a non-ASCII letter `vendor/lib` came out `lib` (T1).
    nonisolated static func relativePath(of target: String, under base: String) -> String? {
        let baseComponents = ((base as NSString).standardizingPath as NSString).pathComponents
        let targetComponents = ((target as NSString).standardizingPath as NSString).pathComponents
        guard targetComponents.count >= baseComponents.count,
              Array(targetComponents.prefix(baseComponents.count)) == baseComponents
        else { return nil }
        let rest = targetComponents.dropFirst(baseComponents.count)
        return rest.isEmpty ? "." : rest.joined(separator: "/")
    }

    // MARK: - Work tree scan

    /// Discovers embedded repositories (directories containing `.git`) to exclude them from snapshot staging.
    func discoverEmbeddedRepositories(in workFolder: URL) async -> [String] {
        await Self.scanWorkTree(in: workFolder).embeddedRepositories
    }

    func scanWorkTree(in workFolder: URL) async -> WorkTreeScan {
        await Self.scanWorkTree(in: workFolder)
    }

    /// One walk of the whole work tree — OFF the actor every folder's snapshots share, which it
    /// used to hold for the length of the walk on every snapshot and every `task_changes` (N14).
    @concurrent
    nonisolated static func scanWorkTree(in workFolder: URL) async -> WorkTreeScan {
        let fileManager = FileManager.default
        let workPath = workFolder.standardizedFileURL.path
        var scan = WorkTreeScan()
        guard let enumerator = fileManager.enumerator(
            at: workFolder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return scan }

        while let fileURL = enumerator.nextObject() as? URL {
            let lastComponent = fileURL.lastPathComponent
            if lastComponent == ".git" || lastComponent == ".nanoteams" {
                enumerator.skipDescendants()
                continue
            }
            if lastComponent == ".gitignore" {
                // git does not follow a symlinked .gitignore (2.32+), so neither does the record.
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true, values?.isSymbolicLink != true,
                   let rel = Self.relativePath(of: fileURL.path, under: workPath), rel != "." {
                    scan.ignoreFiles.append(rel)
                }
                continue
            }
            let childGit = fileURL.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: childGit.path) {
                enumerator.skipDescendants()
                if let rel = Self.relativePath(of: fileURL.path, under: workPath), rel != "." {
                    scan.embeddedRepositories.append(rel)
                }
            }
        }
        return scan
    }

    // MARK: - Exclude mirror

    func resolveGitInfoExcludes(in workFolder: URL) -> [URL] {
        let dotGit = workFolder.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDir) else {
            return []
        }

        if isDir.boolValue {
            let exclude = dotGit.appendingPathComponent("info/exclude")
            return fileManager.fileExists(atPath: exclude.path) ? [exclude] : []
        }

        // .git is a file (e.g. git worktree or submodule)
        guard let content = try? String(contentsOf: dotGit, encoding: .utf8) else {
            return []
        }

        var results: [URL] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let rawPath = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !rawPath.isEmpty else { continue }

            let gitdirURL: URL
            if rawPath.hasPrefix("/") {
                gitdirURL = URL(fileURLWithPath: rawPath).standardizedFileURL
            } else {
                gitdirURL = workFolder.appendingPathComponent(rawPath).standardizedFileURL
            }

            // In git worktrees, commondir points back to the common .git directory
            let commondirFile = gitdirURL.appendingPathComponent("commondir")
            if fileManager.fileExists(atPath: commondirFile.path),
               let commonContent = try? String(contentsOf: commondirFile, encoding: .utf8) {
                let commonTrimmed = commonContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !commonTrimmed.isEmpty {
                    let commonGitDir: URL
                    if commonTrimmed.hasPrefix("/") {
                        commonGitDir = URL(fileURLWithPath: commonTrimmed).standardizedFileURL
                    } else {
                        commonGitDir = gitdirURL.appendingPathComponent(commonTrimmed).standardizedFileURL
                    }
                    let commonExclude = commonGitDir.appendingPathComponent("info/exclude")
                    if fileManager.fileExists(atPath: commonExclude.path) {
                        results.append(commonExclude)
                    }
                }
            }

            // Also check gitdir directly (for submodules, or worktrees with direct info/exclude)
            let directExclude = gitdirURL.appendingPathComponent("info/exclude")
            let existingExcludeSet: Set<URL> = Set(results)
            if fileManager.fileExists(atPath: directExclude.path) && !existingExcludeSet.contains(directExclude) {
                results.append(directExclude)
            }
        }
        return results
    }

    /// The content of `snapshots.git/info/exclude` for the work tree as it is now.
    func composeMirroredExcludes(in workFolder: URL) -> String {
        var excludes = ".nanoteams\n.nanoteams/**\n"
        for userGitInfoExclude in resolveGitInfoExcludes(in: workFolder) {
            if let userExcludes = try? String(contentsOf: userGitInfoExclude, encoding: .utf8),
               !userExcludes.isEmpty {
                excludes += "\n# Mirrored from \(userGitInfoExclude.path)\n" + userExcludes + "\n"
            }
        }
        excludes += enclosingRepositoryExcludes(of: workFolder)
        return excludes
    }

    /// The rules of a repository enclosing the work folder, restated for it (N19): its
    /// `info/exclude`, then the `.gitignore` of every directory from its root down to the work
    /// folder's parent — lowest precedence first, as git applies them.
    private func enclosingRepositoryExcludes(of workFolder: URL) -> String {
        guard let root = EnclosingRepositoryIgnoreRules.enclosingRepositoryRoot(
            of: workFolder, fileManager: fileManager)
        else { return "" }
        let work = workFolder.standardizedFileURL
        guard let relative = Self.relativePath(of: work.path, under: root.path), relative != "." else {
            return ""
        }
        let components = relative.split(separator: "/").map(String.init)
        var sources: [(file: URL, below: [String])] = resolveGitInfoExcludes(in: root).map {
            ($0, components)
        }
        var directory = root
        for depth in 0..<components.count {
            sources.append((directory.appendingPathComponent(".gitignore"), Array(components[depth...])))
            directory = directory.appendingPathComponent(components[depth], isDirectory: true)
        }
        var out = ""
        for source in sources {
            guard let content = try? String(contentsOf: source.file, encoding: .utf8) else { continue }
            let lines = EnclosingRepositoryIgnoreRules.translate(content, workFolderBelow: source.below)
            guard !lines.isEmpty else { continue }
            out += "\n# Mirrored from enclosing \(source.file.path)\n" + lines.joined(separator: "\n") + "\n"
        }
        return out
    }

    func writeMirroredExcludes(_ content: Data, gitDir: URL) {
        let infoDir = gitDir.appendingPathComponent("info", isDirectory: true)
        try? fileManager.createDirectory(
            at: infoDir, withIntermediateDirectories: true, attributes: NTMSRepository.internalDirAttributes)
        try? content.write(to: infoDir.appendingPathComponent("exclude"), options: .atomic)
    }

    func syncExcludes(in workFolder: URL, gitDir: URL) {
        writeMirroredExcludes(Data(composeMirroredExcludes(in: workFolder).utf8), gitDir: gitDir)
    }

    /// The rules the work tree holds now.
    func currentIgnoreRules(in workFolder: URL, ignoreFiles: [String]) -> SnapshotIgnoreRules {
        var files: [String: Data] = [:]
        for relative in ignoreFiles {
            files[relative] = (try? Data(contentsOf: workFolder.appendingPathComponent(relative))) ?? Data()
        }
        return SnapshotIgnoreRules(
            ignoreFiles: files, mirroredExcludes: Data(composeMirroredExcludes(in: workFolder).utf8))
    }

    // MARK: - Staging

    /// Takes out of the private index every tracked file the rules now ignore. `-f`: the private
    /// repository has no HEAD, so `rm --cached` without it refuses any file whose staged content
    /// differs from the work tree — a file force-staged by an earlier snapshot or live diff and
    /// changed since — and one such file failed its whole batch. The file stayed tracked, `add -A`
    /// updated it whatever the rules said, and the next round started with it (review of
    /// 2026-11-12; `TaskSnapshotRoundHiddenCostTests`).
    func clearIgnoredTrackedFiles(in workFolder: URL, gitDir: URL) async {
        let args = [
            "--git-dir=\(gitDir.path)",
            "--work-tree=\(workFolder.path)",
            "-c", "core.quotePath=false",
            "ls-files",
            "-i",
            "-c",
            "--exclude-standard",
            "-z"
        ]
        guard let res = try? await runPrivateGit(args, in: workFolder, gitDir: gitDir),
              res.exitCode == 0,
              !res.stdoutData.isEmpty else {
            return
        }
        let ignoredPaths = parseNullDelimitedTokens(data: res.stdoutData)
        guard !ignoredPaths.isEmpty else { return }

        let batchSize = 50
        for i in stride(from: 0, to: ignoredPaths.count, by: batchSize) {
            let chunk = Array(ignoredPaths[i..<min(i + batchSize, ignoredPaths.count)])
            let rmArgs = [
                "--git-dir=\(gitDir.path)",
                "--work-tree=\(workFolder.path)",
                "rm",
                "--cached",
                "-f",
                "-q",
                "--ignore-unmatch",
                "--"
            ] + chunk.map { ":(literal)\($0)" }
            _ = try? await runPrivateGit(rmArgs, in: workFolder, gitDir: gitDir)
        }
    }

    /// Stages the work tree into the private index and writes its tree. `roundRules` are the
    /// rules the round started under (`nil` for a start snapshot, or a round recorded before
    /// rules were); `startRef` is that round's start, which a file a REMOVED rule exposed is
    /// measured against.
    func stageTree(
        workFolder: URL,
        gitDir: URL,
        resolver: SandboxPathResolver,
        roundRules: SnapshotIgnoreRules?,
        startRef: String?
    ) async throws -> StagedTree {
        let scan = await scanWorkTree(in: workFolder)
        let current = currentIgnoreRules(in: workFolder, ignoreFiles: scan.ignoreFiles)
        let effective = roundRules ?? current
        writeMirroredExcludes(effective.mirroredExcludes, gitDir: gitDir)
        await clearIgnoredTrackedFiles(in: workFolder, gitDir: gitDir)

        let excludedPaths = scan.embeddedRepositories + resolver.gitExcludedRelativePaths
        let exclusions = excludedPaths.map(SandboxPathResolver.gitExcludePathspec)
        // `add` refuses an exclude that names a path its rules ignore — exit 1, "The following
        // paths are ignored by one of your .gitignore files" — and stages around an ignored path
        // anyway, so such a path takes no exclude. Measured on git 2.54 (2026-11-12): `.build/` in
        // `.gitignore` beside a SwiftPM checkout `.build/checkouts/<dep>/.git`, or a role's
        // `.gitignore` naming an embedded repository, failed every snapshot of the folder.
        let ignoredExcluded: Set<String> = excludedPaths.isEmpty
            ? []
            : try await ignoredPaths(excludedPaths, workTree: workFolder, gitDir: gitDir)
        let addExclusions = excludedPaths.filter { !ignoredExcluded.contains($0) }
            .map(SandboxPathResolver.gitExcludePathspec)
        var addArgs = ["--git-dir=\(gitDir.path)", "--work-tree=\(workFolder.path)", "add", "-A"]
        if !addExclusions.isEmpty {
            addArgs.append("--")
            addArgs.append(contentsOf: addExclusions)
        }
        let addRes = try await runPrivateGit(addArgs, in: workFolder, gitDir: gitDir)
        if addRes.exitCode != 0 {
            throw ExternalAutovisorError("Snapshot add failed: \(addRes.stderr)", code: .commandFailed)
        }

        var notShown: [String] = []
        if let roundRules, roundRules.ignoreFiles != current.ignoreFiles {
            notShown = try await restoreRoundRules(
                roundRules, workFolder: workFolder, gitDir: gitDir, resolver: resolver,
                exclusions: exclusions, embedded: Set(scan.embeddedRepositories), startRef: startRef)
        }

        let treeRes = try await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "--work-tree=\(workFolder.path)", "write-tree"],
            in: workFolder,
            gitDir: gitDir
        )
        if treeRes.exitCode != 0 {
            throw ExternalAutovisorError("Snapshot write-tree failed: \(treeRes.stderr)", code: .commandFailed)
        }
        return StagedTree(
            tree: treeRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            embeddedRepositories: scan.embeddedRepositories,
            notShown: notShown,
            currentRules: current
        )
    }
}
