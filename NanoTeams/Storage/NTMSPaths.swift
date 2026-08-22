import Foundation

nonisolated struct NTMSPaths: Hashable {
    /// Name of the internal subdirectory within `.nanoteams/` hidden from LLM file tools.
    private static let internalDirName = "internal"

    let workFolderRoot: URL

    var nanoteamsDir: URL { workFolderRoot.appendingPathComponent(".nanoteams", isDirectory: true) }

    // MARK: - Internal Directory (hidden from LLM tools)

    var internalDir: URL {
        nanoteamsDir.appendingPathComponent(Self.internalDirName, isDirectory: true)
    }

    var internalTasksDir: URL { internalDir.appendingPathComponent("tasks", isDirectory: true) }

    // MARK: - Internal Service Files

    var workFolderJSON: URL { internalDir.appendingPathComponent("workfolder.json", isDirectory: false) }
    var settingsJSON: URL { internalDir.appendingPathComponent("settings.json", isDirectory: false) }
    var teamsJSON: URL { internalDir.appendingPathComponent("teams.json", isDirectory: false) }
    var toolsJSON: URL { internalDir.appendingPathComponent("tools.json", isDirectory: false) }
    var tasksIndexJSON: URL { internalDir.appendingPathComponent("tasks_index.json", isDirectory: false) }
    var stagedAttachmentsDir: URL { internalDir.appendingPathComponent("staged", isDirectory: true) }
    var headlessResultJSON: URL { internalDir.appendingPathComponent("headless_result.json", isDirectory: false) }

    // MARK: - Ancestor-Aware Path Construction
    //
    // Delegated child tasks are stored nested under their parent's directory:
    //
    //   .nanoteams/tasks/100/                     ← top-level task
    //   .nanoteams/tasks/100/subtasks/123/         ← child of 100
    //   .nanoteams/tasks/100/subtasks/123/subtasks/456/  ← grandchild
    //
    // The `ancestors:` parameter on every path method is the list of parent task
    // IDs ordered ROOT-FIRST. Top-level tasks pass `[]`. A child of task 100
    // passes `[100]`. A grandchild of 100 (whose direct parent is 123) passes `[100, 123]`.
    //
    // Helpers in `TasksIndex.ancestorIDs(of:)` compute the chain by walking
    // `parentTaskID` links — repository call sites use that.

    /// Appends `subtasks/<id>` segments for each ancestor, then `<taskID>` itself.
    /// `ancestors == []` yields `<base>/<taskID>` (the original flat layout).
    private static func appendNestedTaskPath(base: URL, taskID: Int, ancestors: [Int]) -> URL {
        var url = base
        for (index, ancestorID) in ancestors.enumerated() {
            if index > 0 {
                url.appendPathComponent("subtasks", isDirectory: true)
            }
            url.appendPathComponent(String(ancestorID), isDirectory: true)
        }
        if !ancestors.isEmpty {
            url.appendPathComponent("subtasks", isDirectory: true)
        }
        url.appendPathComponent(String(taskID), isDirectory: true)
        return url
    }

    // MARK: - Internal Task Paths

    func internalTaskDir(taskID: Int, ancestors: [Int] = []) -> URL {
        Self.appendNestedTaskPath(base: internalTasksDir, taskID: taskID, ancestors: ancestors)
    }

    func taskJSON(taskID: Int, ancestors: [Int] = []) -> URL {
        internalTaskDir(taskID: taskID, ancestors: ancestors)
            .appendingPathComponent("task.json", isDirectory: false)
    }

    // MARK: - Internal Run Paths (nested under task)

    func internalRunDir(taskID: Int, runID: Int, ancestors: [Int] = []) -> URL {
        internalTaskDir(taskID: taskID, ancestors: ancestors)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(String(runID), isDirectory: true)
    }

    func internalRoleDir(taskID: Int, runID: Int, roleID: String, ancestors: [Int] = []) -> URL {
        let safe = Self.sanitizePathComponent(roleID)
        return internalRunDir(taskID: taskID, runID: runID, ancestors: ancestors)
            .appendingPathComponent("roles", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    func conversationLogURL(taskID: Int, runID: Int, ancestors: [Int] = []) -> URL {
        internalRunDir(taskID: taskID, runID: runID, ancestors: ancestors)
            .appendingPathComponent("conversation_log.md", isDirectory: false)
    }

    /// The wire log — JSONL since 2026-08-21 (one record per line, O(1) appends,
    /// per-file serialization in `JSONLFileLog`).
    func networkLogJSONL(taskID: Int, runID: Int, ancestors: [Int] = []) -> URL {
        internalRunDir(taskID: taskID, runID: runID, ancestors: ancestors)
            .appendingPathComponent("network_log.jsonl", isDirectory: false)
    }

    /// Pre-2026-08-21 runs wrote a JSON ARRAY under this name. Log artifacts die
    /// with their run, so nothing converts them — readers (`networkLogURL`,
    /// `train_first_prompt.sh --from-logs` and its Swift mirror) fall back to
    /// this when the `.jsonl` is absent.
    func legacyNetworkLogJSON(taskID: Int, runID: Int, ancestors: [Int] = []) -> URL {
        internalRunDir(taskID: taskID, runID: runID, ancestors: ancestors)
            .appendingPathComponent("network_log.json", isDirectory: false)
    }

    func toolCallsJSONL(taskID: Int, runID: Int, ancestors: [Int] = []) -> URL {
        internalRunDir(taskID: taskID, runID: runID, ancestors: ancestors)
            .appendingPathComponent("tool_calls.jsonl", isDirectory: false)
    }

    /// Per-STEP append log of the four stream collections (`llmConversation`,
    /// `wireTranscript`, `toolCalls`, `messages`) — 98.4% of a task's bytes,
    /// split out of `task.json` 2026-08-21 so `updateTaskOnly` appends O(delta)
    /// instead of rewriting the whole conversation per message. Per step, not
    /// per run: parallel roles (CLAUDE.md #45) write with zero contention, a
    /// step reset compacts one step's file, and `tool_calls.jsonl` already owns
    /// the run-level name.
    func stepLogJSONL(taskID: Int, runID: Int, roleID: String, ancestors: [Int] = []) -> URL {
        internalRoleDir(taskID: taskID, runID: runID, roleID: roleID, ancestors: ancestors)
            .appendingPathComponent("step_log.jsonl", isDirectory: false)
    }

    func buildDiagnosticsJSON(taskID: Int, runID: Int, roleID: String, ancestors: [Int] = []) -> URL {
        internalRoleDir(taskID: taskID, runID: runID, roleID: roleID, ancestors: ancestors)
            .appendingPathComponent("build_diagnostics.json", isDirectory: false)
    }

    func buildExcerptsTXT(taskID: Int, runID: Int, roleID: String, ancestors: [Int] = []) -> URL {
        internalRoleDir(taskID: taskID, runID: runID, roleID: roleID, ancestors: ancestors)
            .appendingPathComponent("build_excerpts.txt", isDirectory: false)
    }

    // MARK: - LLM-Accessible Paths (tasks/attachments and runs/artifacts)

    var tasksDir: URL { nanoteamsDir.appendingPathComponent("tasks", isDirectory: true) }

    func taskDir(taskID: Int, ancestors: [Int] = []) -> URL {
        Self.appendNestedTaskPath(base: tasksDir, taskID: taskID, ancestors: ancestors)
    }

    func taskAttachmentsDir(taskID: Int, ancestors: [Int] = []) -> URL {
        taskDir(taskID: taskID, ancestors: ancestors)
            .appendingPathComponent("attachments", isDirectory: true)
    }

    /// Folder-level Autovisor store — deliberately OUTSIDE `internal/` so the
    /// manager's file tools (`read_file`, `read_lines`, …) can read the goal's
    /// attachments. Not task-scoped: it survives manager delete/recreate, matching
    /// the lifecycle of the goal string it belongs to.
    var autovisorDir: URL { nanoteamsDir.appendingPathComponent("autovisor", isDirectory: true) }

    var autovisorAttachmentsDir: URL {
        autovisorDir.appendingPathComponent("attachments", isDirectory: true)
    }

    // MARK: - LLM-Accessible Run Paths (nested under task)

    func runDir(taskID: Int, runID: Int, ancestors: [Int] = []) -> URL {
        taskDir(taskID: taskID, ancestors: ancestors)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(String(runID), isDirectory: true)
    }

    func rolesDir(taskID: Int, runID: Int, ancestors: [Int] = []) -> URL {
        runDir(taskID: taskID, runID: runID, ancestors: ancestors)
            .appendingPathComponent("roles", isDirectory: true)
    }

    func roleDir(taskID: Int, runID: Int, roleID: String, ancestors: [Int] = []) -> URL {
        rolesDir(taskID: taskID, runID: runID, ancestors: ancestors)
            .appendingPathComponent(Self.sanitizePathComponent(roleID), isDirectory: true)
    }

    /// The directory-name form of a role ID — the ONE place a role id becomes a
    /// path component, so anything that needs to identify a role's directory
    /// without building a URL (see `stepLogKey`) collapses to the same string
    /// the path itself uses.
    static func roleDirComponent(_ roleID: String) -> String { sanitizePathComponent(roleID) }

    /// Registry identity of a step's `step_log.jsonl`, built from a task
    /// directory path the caller resolved ONCE.
    ///
    /// Exists because `splittingStreams` asks about every step of every run on
    /// every mutation, and building a `URL` per step (six `appendPathComponent`
    /// hops) plus `standardizedFileURL` was measured at 47% of that walk — paid
    /// in full by frozen history that has nothing to flush. String concatenation
    /// over an already-standardized prefix is the same identity for a fraction
    /// of the cost: appending plain components introduces no `.`/`..`, so
    /// standardizing the base and then appending equals appending and then
    /// standardizing. Pinned by `NTMSPathsTests`.
    static func stepLogKey(taskDirPath: String, runID: Int, roleID: String) -> String {
        "\(taskDirPath)/runs/\(runID)/roles/\(roleDirComponent(roleID))/step_log.jsonl"
    }

    /// Strips path traversal characters from a role ID used as a directory name.
    private static func sanitizePathComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
    }

    func stagedAttachmentDir(draftID: UUID) -> URL {
        stagedAttachmentsDir.appendingPathComponent(draftID.uuidString, isDirectory: true)
    }

    // MARK: - Path Helpers

    /// Returns a path relative to the .nanoteams directory for persistence references.
    func relativePathWithinNanoteams(for absoluteURL: URL) -> String {
        Self.relativePath(of: absoluteURL, under: nanoteamsDir)
    }

    /// Returns a path relative to the project root for use with sandboxed tools.
    func relativePathFromProjectRoot(for absoluteURL: URL) -> String {
        Self.relativePath(of: absoluteURL, under: workFolderRoot)
    }

    /// `absoluteURL` relative to `base`, compared by symlink-resolved + standardized path
    /// COMPONENTS — not raw string prefixing, which silently missed `/var`↔`/private/var`
    /// symlink divergence and any `..`/trailing-slash normalization, falling back to the bare
    /// last component (a plausible-but-wrong `.nanoteams/<file>` that `read_file` then 404s on).
    ///
    /// Returns "" when `absoluteURL` is not actually under `base`. Every consumer treats an
    /// empty `relativePath` as "no readable reference" (`Artifact.llmReadablePath`,
    /// `ArtifactService.readContent`), so a wrong path is never fabricated. All persisted
    /// artifact/attachment URLs are built under these dirs, so "" signals a programmer error,
    /// not a normal outcome.
    private static func relativePath(of absoluteURL: URL, under base: URL) -> String {
        let baseComponents = base.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let urlComponents = absoluteURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard urlComponents.count >= baseComponents.count,
              Array(urlComponents.prefix(baseComponents.count)) == baseComponents else {
            return ""
        }
        return urlComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    /// Checks whether a URL points inside the internal directory.
    func isInternalURL(_ url: URL) -> Bool {
        SandboxPathResolver.isWithin(candidate: url, container: internalDir)
    }

    init(workFolderRoot: URL) {
        self.workFolderRoot = workFolderRoot
    }
}
