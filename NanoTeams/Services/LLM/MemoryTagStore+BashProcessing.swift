import Foundation

// MARK: - Bash Processing

nonisolated extension MemoryTagStore {

    /// Tags `bash` command output so an identical re-run of the same command with
    /// unchanged output collapses to a compact tag reference (per the no-truncation
    /// product preference — repeats are referenced, not re-sent in full). Skips
    /// errors (denied commands). Held-for-approval commands never reach here — the
    /// gate awaits the human in-loop and only the REAL command output is processed.
    func processBash(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        guard !result.isError else { return .passthrough }

        let resource = "bash:\(Self.bashCommandKey(from: result.argumentsJSON))"
        let content = result.outputJSON

        if let currentTag = currentBashTag(resource: resource),
           let entry = entries[currentTag],
           entry.content == content {
            return .reference(content: buildUnchangedReference(tag: currentTag))
        }

        if let prevTag = currentBashTag(resource: resource) {
            entries[prevTag]?.status = .outdated(reason: "re-ran command")
        }

        let tag = nextTag(.shell)
        entries[tag] = TagEntry(tag: tag, type: .shell, resource: resource,
                                iteration: iteration, status: .current, content: content)
        let taggedContent = "{\"tag\":\"\(tag)\",\"content\":\(jsonEscape(content))}"
        return .tagged(content: taggedContent, tag: tag)
    }

    /// Current (non-outdated, non-replaced) shell tag for a command resource.
    func currentBashTag(resource: String) -> String? {
        entries.values
            .filter { entry in
                guard entry.type == .shell, entry.resource == resource else { return false }
                if case .current = entry.status { return true }
                return false
            }
            .first?.tag
    }

    /// Stable resource key derived from the command string AND its working
    /// directory (falls back to the raw arguments JSON if the command can't be
    /// decoded). Folding in `working_directory` keeps the SAME command run in two
    /// directories from collapsing to a stale tag reference.
    static func bashCommandKey(from argumentsJSON: String) -> String {
        guard let cmd = BashArguments.command(fromJSON: argumentsJSON) else { return argumentsJSON }
        let normalizedCmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = BashArguments.workingDirectory(fromJSON: argumentsJSON) ?? ""
        // Length-prefix the directory so (cwd, command) maps INJECTIVELY to the key:
        // the leading count fixes where cwd ends, so no character a path or command
        // could contain can make two distinct pairs collide.
        return "\(cwd.count):\(cwd)\(normalizedCmd)"
    }
}
