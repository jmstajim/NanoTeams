import Foundation

struct NTMSPaths: Hashable {
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

    // MARK: - Internal Task Paths

    func internalTaskDir(taskID: Int) -> URL {
        internalTasksDir.appendingPathComponent(String(taskID), isDirectory: true)
    }

    func taskJSON(taskID: Int) -> URL {
        internalTaskDir(taskID: taskID).appendingPathComponent("task.json", isDirectory: false)
    }

    // MARK: - Internal Run Paths (nested under task)

    func internalRunDir(taskID: Int, runID: Int) -> URL {
        internalTaskDir(taskID: taskID)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(String(runID), isDirectory: true)
    }

    func internalRoleDir(taskID: Int, runID: Int, roleID: String) -> URL {
        let safe = Self.sanitizePathComponent(roleID)
        return internalRunDir(taskID: taskID, runID: runID)
            .appendingPathComponent("roles", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    func conversationLogURL(taskID: Int, runID: Int) -> URL {
        internalRunDir(taskID: taskID, runID: runID).appendingPathComponent("conversation_log.md", isDirectory: false)
    }

    func networkLogJSON(taskID: Int, runID: Int) -> URL {
        internalRunDir(taskID: taskID, runID: runID).appendingPathComponent("network_log.json", isDirectory: false)
    }

    func toolCallsJSONL(taskID: Int, runID: Int) -> URL {
        internalRunDir(taskID: taskID, runID: runID).appendingPathComponent("tool_calls.jsonl", isDirectory: false)
    }

    func buildDiagnosticsJSON(taskID: Int, runID: Int, roleID: String) -> URL {
        internalRoleDir(taskID: taskID, runID: runID, roleID: roleID)
            .appendingPathComponent("build_diagnostics.json", isDirectory: false)
    }

    func buildExcerptsTXT(taskID: Int, runID: Int, roleID: String) -> URL {
        internalRoleDir(taskID: taskID, runID: runID, roleID: roleID)
            .appendingPathComponent("build_excerpts.txt", isDirectory: false)
    }

    // MARK: - LLM-Accessible Paths (tasks/attachments and runs/artifacts)

    var tasksDir: URL { nanoteamsDir.appendingPathComponent("tasks", isDirectory: true) }

    func taskDir(taskID: Int) -> URL {
        tasksDir.appendingPathComponent(String(taskID), isDirectory: true)
    }

    func taskAttachmentsDir(taskID: Int) -> URL {
        taskDir(taskID: taskID).appendingPathComponent("attachments", isDirectory: true)
    }

    // MARK: - LLM-Accessible Run Paths (nested under task)

    func runDir(taskID: Int, runID: Int) -> URL {
        taskDir(taskID: taskID)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(String(runID), isDirectory: true)
    }

    func rolesDir(taskID: Int, runID: Int) -> URL {
        runDir(taskID: taskID, runID: runID).appendingPathComponent("roles", isDirectory: true)
    }

    func roleDir(taskID: Int, runID: Int, roleID: String) -> URL {
        rolesDir(taskID: taskID, runID: runID).appendingPathComponent(Self.sanitizePathComponent(roleID), isDirectory: true)
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
        let base = nanoteamsDir.path.hasSuffix("/") ? nanoteamsDir.path : (nanoteamsDir.path + "/")
        let full = absoluteURL.path
        if full.hasPrefix(base) {
            return String(full.dropFirst(base.count))
        }
        // Fallback: last path component
        return absoluteURL.lastPathComponent
    }

    /// Returns a path relative to the project root for use with sandboxed tools.
    func relativePathFromProjectRoot(for absoluteURL: URL) -> String {
        let base = workFolderRoot.path.hasSuffix("/") ? workFolderRoot.path : (workFolderRoot.path + "/")
        let full = absoluteURL.path
        if full.hasPrefix(base) {
            return String(full.dropFirst(base.count))
        }
        return absoluteURL.lastPathComponent
    }

    /// Checks whether a URL points inside the internal directory.
    func isInternalURL(_ url: URL) -> Bool {
        SandboxPathResolver.isWithin(candidate: url, container: internalDir)
    }

    init(workFolderRoot: URL) {
        self.workFolderRoot = workFolderRoot
    }
}
