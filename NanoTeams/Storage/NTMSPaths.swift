import Foundation

nonisolated struct NTMSPaths: Hashable {
    /// The per-work-folder metadata directory, `.nanoteams/`.
    static let nanoteamsDirName = ".nanoteams"

    /// Name of the internal subdirectory within `.nanoteams/` hidden from LLM file tools.
    private static let internalDirName = "internal"

    /// `.nanoteams/internal`, relative to a work folder — for the consumers that build path
    /// STRINGS (the Seatbelt profile). URL consumers read `internalDir`.
    static let internalRelativePath = nanoteamsDirName + "/" + internalDirName

    /// NanoTeams' own folder under Application Support.
    static let applicationSupportFolderName = "NanoTeams"

    /// Default internal storage used when no real work folder is selected.
    static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }

    /// Where `defaultStorageURL` lies for the user whose home folder is `home` — the
    /// spelling the Seatbelt profile denies, which is handed the home it confines (a test's
    /// fake one included) rather than asking `FileManager`.
    static func defaultStorageURL(home: URL) -> URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }

    /// The machine-scoped stores that reside directly under `defaultStorageURL`, beside
    /// `.nanoteams/` — never inside it: that folder is itself the default WORK FOLDER, and a
    /// machine-scoped fact filed under one folder's tree would be tied to that folder.
    ///
    /// The ONE table (F6 S9, 2026-11-12): every store takes its directory from
    /// `machineStorageURL(_:)`, and the bash sandbox denies every case — so a new store is a
    /// new case, and it cannot be created without also being denied.
    enum MachineStore: CaseIterable, Sendable {
        /// `MCPServerCatalogueStore` — the configured MCP servers.
        case mcp
        /// `HostedMCPEnvironment.live` — the external agents' records.
        case externalAgents
        /// `AgentSkillsCatalogueStore` — the agent-skill catalogue cache.
        case skills
        /// `BenchmarkHistoryStore` — generation-speed benchmark history.
        case benchmarks

        var directoryName: String {
            switch self {
            case .mcp: "mcp"
            // The tab's former name, kept so what it already stored is still found.
            case .externalAgents: HostedMCPConstants.externalAgentsSubdirectory
            case .skills: "skills"
            case .benchmarks: "benchmarks"
            }
        }
    }

    /// The directory of one machine store under `storage` (by default the app's own).
    static func machineStorageURL(_ store: MachineStore, under storage: URL = defaultStorageURL) -> URL {
        storage.appendingPathComponent(store.directoryName, isDirectory: true)
    }

    let workFolderRoot: URL

    var nanoteamsDir: URL { workFolderRoot.appendingPathComponent(Self.nanoteamsDirName, isDirectory: true) }

    // MARK: - Internal Directory (hidden from LLM tools)

    var internalDir: URL {
        nanoteamsDir.appendingPathComponent(Self.internalDirName, isDirectory: true)
    }

    var internalTasksDir: URL { internalDir.appendingPathComponent("tasks", isDirectory: true) }

    /// The bare git repository task snapshots are kept in (`TaskSnapshotService`).
    var snapshotsGitDir: URL { internalDir.appendingPathComponent("snapshots.git", isDirectory: true) }

    /// The file whose exclusive `flock` makes one NanoTeams process the folder's only one
    /// (`WorkFolderInstanceLock`). It holds the holder's PID and since-when, for the refusal.
    var instanceLockFile: URL { internalDir.appendingPathComponent("instance.lock", isDirectory: false) }

    // MARK: - Internal Service Files

    var workFolderJSON: URL { internalDir.appendingPathComponent("workfolder.json", isDirectory: false) }
    var settingsJSON: URL { internalDir.appendingPathComponent("settings.json", isDirectory: false) }
    var teamsJSON: URL { internalDir.appendingPathComponent("teams.json", isDirectory: false) }
    var toolsJSON: URL { internalDir.appendingPathComponent("tools.json", isDirectory: false) }
    var tasksIndexJSON: URL { internalDir.appendingPathComponent("tasks_index.json", isDirectory: false) }
    var stagedAttachmentsDir: URL { internalDir.appendingPathComponent("staged", isDirectory: true) }
    var headlessResultJSON: URL { internalDir.appendingPathComponent("headless_result.json", isDirectory: false) }

    // MARK: - Autovisor (internal per work folder)

    /// Per-folder internal Autovisor directory (`.nanoteams/internal/autovisor/`), hidden from
    /// role file tools and created with `NTMSRepository.internalDirAttributes` (`0o700`).
    var internalAutovisorDir: URL {
        internalDir.appendingPathComponent("autovisor", isDirectory: true)
    }

    /// Summary-only JSONL log of external Autovisor agent tool calls (§11, Ш14). The calls in
    /// full sit beside it in `external_calls/`, a directory the log derives from this URL
    /// (`ExternalAutovisorActivityLog.callsDirectoryURL(for:)`).
    var externalActivityLogJSONL: URL {
        internalAutovisorDir.appendingPathComponent("external_activity.jsonl", isDirectory: false)
    }

    /// When each external agent's task creations were committed, kept so the creation window
    /// outlives the process (`ExternalCreationWindowStore`, F6 L4).
    var externalCreationsJSON: URL {
        internalAutovisorDir.appendingPathComponent("external_creations.json", isDirectory: false)
    }

    // MARK: - MCP (per work folder)

    /// Per-folder MCP state. The server CATALOGUE is machine-scoped and lives beside
    /// `.nanoteams/` (`MCPServerCatalogueStore`) — what belongs to a folder is which of
    /// those servers it switches off, and the frame log of the ones it talked to.
    var mcpDir: URL { internalDir.appendingPathComponent("mcp", isDirectory: true) }

    /// `{ disabledServerIDs }` — the folder's opt-outs. Per-folder sets are the mitigation
    /// for cross-server shadowing: a folder that needs a design server does not also carry
    /// a brokerage one.
    var mcpFolderJSON: URL { mcpDir.appendingPathComponent("mcp_folder.json", isDirectory: false) }

    func mcpServerDir(slug: MCPServerSlug) -> URL {
        mcpDir.appendingPathComponent(slug.rawValue, isDirectory: true)
    }

    /// Redacted JSON-RPC frame log for one server — the audit trail for what was asked and
    /// answered, beside the existing tool and network logs.
    func mcpRPCLogJSONL(slug: MCPServerSlug) -> URL {
        mcpServerDir(slug: slug).appendingPathComponent("rpc_log.jsonl", isDirectory: false)
    }

    /// Where a binary block of an MCP result is written: an image, audio, or an opaque
    /// blob. Under the task's ATTACHMENTS rather than under `internal/`, because the point
    /// of writing it is that a later tool call can read it back — `analyze_image` takes the
    /// project-relative path this yields.
    func mcpAttachmentsDir(taskID: Int, ancestors: [Int] = []) -> URL {
        taskAttachmentsDir(taskID: taskID, ancestors: ancestors)
            .appendingPathComponent("mcp", isDirectory: true)
    }

    func mcpAttachmentsDir(taskID: Int, ancestors: [Int] = [], slug: MCPServerSlug) -> URL {
        mcpAttachmentsDir(taskID: taskID, ancestors: ancestors)
            .appendingPathComponent(slug.rawValue, isDirectory: true)
    }

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
