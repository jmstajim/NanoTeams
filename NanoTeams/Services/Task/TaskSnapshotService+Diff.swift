import Foundation

/// `task_changes`: what changed in a round, between its start and its end (or the work tree).
extension TaskSnapshotService {

    func parseNullDelimitedTokens(data: Data) -> [String] {
        var tokens: [String] = []
        var start = data.startIndex
        for i in data.indices {
            if data[i] == 0 {
                if i > start {
                    let subData = data[start..<i]
                    tokens.append(String(decoding: subData, as: UTF8.self))
                } else {
                    tokens.append("")
                }
                start = data.index(after: i)
            }
        }
        if start < data.endIndex {
            let subData = data[start..<data.endIndex]
            let token = String(decoding: subData, as: UTF8.self)
            if !token.isEmpty {
                tokens.append(token)
            }
        }
        return tokens
    }

    /// What changed in a round, paginated per file: its start against its last end snapshot —
    /// or against the work tree while `roundIsOpen`, or when it has no end snapshot. `runID` /
    /// `round` default to the latest recorded. The caller says whether the round is still
    /// going (N7): an end snapshot is not the end of a round that went on after it.
    func diffChanges(
        workFolder: URL,
        folderID: String,
        taskID: Int,
        runID: Int?,
        round: Int?,
        roundIsOpen: Bool,
        page: Int?,
        pageSize: Int?,
        filePath: String?
    ) async throws -> TaskChangesResult {
        try await withFolderLock(workFolder: workFolder) { _ in
            if let filePath {
                if TaskChangesRefusal.refuses(filePath: filePath) {
                    throw ExternalAutovisorError(
                        TaskChangesRefusal.invalidFilePath(filePath),
                        code: .invalidArgs,
                        next: ExternalNextCall.fixArgument.hint(after: ExternalAutovisorToolNames.taskChanges, taskID: taskID)
                    )
                }
            }

            let requestedPage = page ?? 1
            if requestedPage < 1 {
                throw ExternalAutovisorError(
                    TaskChangesRefusal.invalidPage,
                    code: .invalidArgs,
                    next: ExternalNextCall.firstPage.hint(taskID: taskID)
                )
            }
            let limit = pageSize ?? 5
            if limit < 1 {
                throw ExternalAutovisorError(
                    TaskChangesRefusal.invalidPageSize,
                    code: .invalidArgs,
                    next: ExternalNextCall.fixArgument.hint(after: ExternalAutovisorToolNames.taskChanges, taskID: taskID)
                )
            }

            let resolver = SandboxPathResolver(workFolderRoot: workFolder, home: home)
            if resolver.hidesRoot {
                throw ExternalAutovisorError(
                    TaskChangesRefusal.protectedWorkFolder(workFolder.path),
                    code: .permissionDenied,
                    next: ExternalNextCall.protectedFolder.hint(taskID: taskID)
                )
            }

            let gitDir = NTMSPaths(workFolderRoot: workFolder).snapshotsGitDir

            guard fileManager.fileExists(atPath: gitDir.appendingPathComponent("HEAD").path) else {
                throw Self.noSnapshotsTaken(taskID: taskID, missingRoundStart: round)
            }

            let index = try await taskRefIndex(gitDir: gitDir, taskID: taskID, workFolder: workFolder)
            guard let targetRunID = runID ?? index.latestRunID,
                  let actualRound = round ?? index.latestRound(ofRun: targetRunID)
            else {
                throw Self.noSnapshotsTaken(taskID: taskID, missingRoundStart: round)
            }
            let recorded = index.recordedPhases(run: targetRunID, round: actualRound)
            guard recorded.contains(.start) else {
                if round != nil {
                    throw Self.roundDoesNotExist(round: actualRound, taskID: taskID)
                }
                throw Self.noSnapshotsTaken(taskID: taskID, missingRoundStart: actualRound)
            }
            let resolvedStartRef = Self.refName(taskID: taskID, runID: targetRunID, round: actualRound, phase: .start)
            let resolvedEndRef = roundIsOpen
                ? nil
                : await latestEndRef(
                    taskID: taskID, runID: targetRunID, round: actualRound, recorded: recorded,
                    workFolder: workFolder, gitDir: gitDir)

            var notTracked: [NotTrackedPath]
            let targetTreeOrRef: String
            if let resolvedEndRef {
                targetTreeOrRef = resolvedEndRef
                notTracked = await discoverEmbeddedRepositories(in: workFolder).map {
                    NotTrackedPath(path: $0, reason: NotTrackedPath.embeddedRepository)
                }
                notTracked += await readNotShown(endRef: resolvedEndRef, workFolder: workFolder, gitDir: gitDir)
                    .map { NotTrackedPath(path: $0, reason: NotTrackedPath.hiddenByRoundRules) }
            } else {
                // Live diff: stage the work tree as the round's end would, under the round's rules.
                let roundRules = await loadRoundRules(
                    taskID: taskID, runID: targetRunID, round: actualRound, workFolder: workFolder, gitDir: gitDir)
                let staged = try await stageTree(
                    workFolder: workFolder, gitDir: gitDir, resolver: resolver,
                    roundRules: roundRules, startRef: resolvedStartRef)
                targetTreeOrRef = staged.tree
                notTracked = staged.embeddedRepositories.map {
                    NotTrackedPath(path: $0, reason: NotTrackedPath.embeddedRepository)
                } + staged.notShown.map { NotTrackedPath(path: $0, reason: NotTrackedPath.hiddenByRoundRules) }
            }

            let roundRepairs = await storeRepairs(
                startRef: resolvedStartRef, endRef: resolvedEndRef, workFolder: workFolder, gitDir: gitDir)

            let nameStatusArgs = [
                "--git-dir=\(gitDir.path)",
                "-c", "core.quotePath=false",
                "diff",
                "-M",
                "-z",
                "--name-status",
                resolvedStartRef,
                targetTreeOrRef
            ]
            let nameStatusRes = try await runPrivateGit(nameStatusArgs, in: workFolder, gitDir: gitDir, isDiff: true)
            if nameStatusRes.exitCode != 0 {
                throw ExternalAutovisorError("Snapshot diff failed: \(nameStatusRes.stderr)", code: .commandFailed)
            }

            let tokens = parseNullDelimitedTokens(data: nameStatusRes.stdoutData)
            var allFiles: [ChangedFile] = []
            var idx: Int = 0
            while idx < tokens.count {
                let statusCode = tokens[idx]
                idx = idx + 1
                guard !statusCode.isEmpty else { continue }
                if statusCode.hasPrefix("R") || statusCode.hasPrefix("C") {
                    guard idx + 1 < tokens.count else { break }
                    let oldPath = tokens[idx]
                    let newPath = tokens[idx + 1]
                    idx = idx + 2
                    let changeType = statusCode.hasPrefix("R") ? "renamed" : "copied"
                    allFiles.append(ChangedFile(path: newPath, change_type: changeType, old_path: oldPath))
                } else {
                    guard idx < tokens.count else { break }
                    let path = tokens[idx]
                    idx = idx + 1
                    let changeType: String
                    if statusCode.hasPrefix("A") {
                        changeType = "added"
                    } else if statusCode.hasPrefix("D") {
                        changeType = "deleted"
                    } else {
                        changeType = "modified"
                    }
                    allFiles.append(ChangedFile(path: path, change_type: changeType))
                }
            }

            var filesToInspect = allFiles
            if let filePath {
                // The raw name, or the name as `task_changes` showed it (hidden characters tagged).
                let matches: (String?) -> Bool = { name in
                    guard let name else { return false }
                    return name == filePath || MCPTextSanitizer.taggedName(name).text == filePath
                }
                filesToInspect = allFiles.filter { matches($0.path) || matches($0.old_path) }
            }

            let totalFiles = filesToInspect.count
            let totalPages = max(1, Int(ceil(Double(totalFiles) / Double(limit))))
            let hasMore = requestedPage < totalPages

            var pageDiffs: [PageFileDiff] = []
            if totalFiles > 0 && requestedPage <= totalPages {
                let startIndex = (requestedPage - 1) * limit
                let endIndex = min(startIndex + limit, totalFiles)
                pageDiffs = try await self.pageDiffs(
                    Array(filesToInspect[startIndex..<endIndex]), from: resolvedStartRef, to: targetTreeOrRef,
                    workFolder: workFolder, gitDir: gitDir)
                for (offset, fileDiff) in pageDiffs.enumerated() {
                    if fileDiff.binary { filesToInspect[startIndex + offset].binary = true }
                    if fileDiff.notUTF8 { filesToInspect[startIndex + offset].encoding = Self.notUTF8Encoding }
                }
            }

            return TaskChangesResult(
                folder_id: folderID,
                task_id: taskID,
                round: actualRound,
                files: filesToInspect,
                diff: pageDiffs.map(\.text).joined(),
                page: requestedPage,
                total_pages: totalPages,
                has_more: hasMore,
                not_tracked: notTracked,
                store_repairs: roundRepairs,
                page_diffs: pageDiffs
            )
        }
    }

    /// No start snapshot for the round asked about (or none at all). `missingRoundStart` names
    /// the round for the caller, which may know why (`RunSnapshotFailure`); it is not on the wire.
    nonisolated static func noSnapshotsTaken(taskID: Int, missingRoundStart: Int?) -> ExternalAutovisorError {
        var error = ExternalAutovisorError(
            TaskChangesRefusal.snapshotsUnavailable(taskID: taskID),
            code: .snapshotsUnavailable,
            details: ["reason": "none_taken"],
            next: ExternalNextCall.passLog.hint(taskID: taskID)
        )
        error.missingRoundStart = missingRoundStart
        return error
    }

    nonisolated static func roundDoesNotExist(round: Int, taskID: Int) -> ExternalAutovisorError {
        var error = ExternalAutovisorError(
            TaskChangesRefusal.roundDoesNotExist(round: round, taskID: taskID),
            code: .invalidArgs,
            next: ExternalNextCall.currentRound.hint(taskID: taskID)
        )
        error.missingRoundStart = round
        return error
    }
}
