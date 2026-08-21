import Foundation

/// Helper structures and utilities for Xcode build operations.
nonisolated enum XcodeBuildHelpers {
    /// Regex pattern for valid feature branch names (`feature/...`).
    private static let featureBranchPattern = #"^feature\/[a-z0-9][a-z0-9._-]*$"#

    /// Result of Xcode project detection.
    struct DetectedXcodeProject {
        var found: Bool
        var kind: String?
        var path: String?
        var schemes: [String]
    }

    /// Snapshot of git status.
    struct GitStatusSnapshot {
        var branch: String?
        var isClean: Bool
    }

    /// Checks if a branch name follows the feature branch naming convention.
    /// - Parameter name: The branch name to check.
    /// - Returns: True if the branch name matches the pattern.
    static func isFeatureBranchName(_ name: String) -> Bool {
        name.range(of: featureBranchPattern, options: .regularExpression) != nil
    }

    /// Extracts a tool failure message from a result.
    /// - Parameter result: The tool execution result.
    /// - Returns: A formatted error message.
    static func toolFailureMessage(for result: ToolExecutionResult) -> String {
        let base = "Tool execution failed: \(result.toolName)"
        guard let dict = JSONUtilities.parseJSONDictionary(result.outputJSON) else { return base }
        if let message = dict["message"] as? String, !message.isEmpty {
            return "\(base) - \(message)"
        }
        if let error = dict["error"] as? String, !error.isEmpty {
            return "\(base) - \(error)"
        }
        return base
    }

    /// Checks if a tool result indicates file mutation.
    /// - Parameters:
    ///   - toolCall: The tool call that was executed.
    ///   - result: The tool execution result.
    /// - Returns: True if files were mutated.
    static func didMutateFiles(toolCall: StepToolCall, result: ToolExecutionResult) -> Bool {
        let name = toolCall.name.lowercased()
        guard let dict = JSONUtilities.parseJSONDictionary(result.outputJSON) else { return false }
        switch name {
        case ToolNames.writeFile:
            return (dict["ok"] as? Bool) == true
        default:
            return false
        }
    }

    /// Checks if a tool result contains warnings.
    /// - Parameter outputJSON: The tool output JSON.
    /// - Returns: True if warnings are present.
    static func hasWarnings(in outputJSON: String) -> Bool {
        guard let dict = JSONUtilities.parseJSONDictionary(outputJSON),
              let meta = dict["meta"] as? [String: Any],
              let warnings = meta["warnings"] as? [String]
        else {
            return false
        }
        return !warnings.isEmpty
    }

    /// Parses build result JSON to extract error and warning counts.
    /// - Parameter outputJSON: The build result JSON.
    /// - Returns: A tuple of (errorCount, warningCount).
    static func parseBuildCounts(from outputJSON: String) -> (errors: Int, warnings: Int) {
        guard let dict = JSONUtilities.parseJSONDictionary(outputJSON) else {
            return (0, 0)
        }
        let errors = (dict["errorCount"] as? Int) ?? 0
        let warnings = (dict["warningCount"] as? Int) ?? 0
        return (errors, warnings)
    }

    // MARK: - Scheme Fetching (for UI)

    /// Fetches available schemes for the Xcode project at the given root.
    /// Runs `xcodebuild -list` on a background thread to avoid blocking the main actor.
    /// - Parameter workFolderRoot: The project root URL.
    /// - Parameter fileManager: Used to enumerate the project directory before the
    ///   detached `xcodebuild` call. Honored end-to-end so test mocks aren't dropped.
    /// - Parameter runner: The `xcodebuild -list` invocation. No default, for the
    ///   reason `XcodebuildRunning` states — and because the detached body below was
    ///   entirely uncovered while the only thing standing between a test and it was
    ///   whether the temp directory happened to contain a project.
    /// - Returns: An array of scheme names.
    static func fetchAvailableSchemes(
        workFolderRoot: URL,
        runner: any XcodebuildRunning,
        fileManager: FileManager = .default
    ) async -> [String] {
        // Enumerate the project directory on the calling thread using the injected
        // `fileManager`. Pass the resulting `[String]` into `Task.detached` (Strings
        // are Sendable) — this preserves the DI contract that previously got
        // dropped when the body re-created `FileManager.default`.
        let contents = (try? fileManager.contentsOfDirectory(atPath: workFolderRoot.path)) ?? []
        guard let args = listArguments(forDirectoryContents: contents) else { return [] }
        return await Task.detached { [args] in
            guard let result = try? runner.run(args, in: workFolderRoot, timeout: 60) else {
                return []
            }
            return parseSchemes(fromListOutput: result.stdout)
        }.value
    }

    /// Picks the `xcodebuild -list` arguments for a directory listing, or `nil`
    /// when the directory holds neither a workspace nor a project (nothing to ask
    /// `xcodebuild` about).
    ///
    /// Extracted from `fetchAvailableSchemes`' detached closure: this is a pure
    /// decision over a `[String]`, and inside the closure it was reachable only by
    /// spawning a real `xcodebuild` subprocess. Same seam rationale as
    /// `TeamSwitchPlanner` / `RoleStepReconciler`. Workspace wins over project —
    /// a workspace that references the project would otherwise report a subset of
    /// the schemes the user actually builds.
    static func listArguments(forDirectoryContents contents: [String]) -> [String]? {
        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return ["-list", "-workspace", workspace]
        }
        if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return ["-list", "-project", project]
        }
        return nil
    }

    /// Parses the scheme names out of `xcodebuild -list` stdout.
    ///
    /// Extracted from `fetchAvailableSchemes`' detached closure for the same reason
    /// as `listArguments`: a text parser whose only entry point was a subprocess is
    /// a parser nobody can pin. The shape it consumes is `xcodebuild`'s, which has
    /// three properties worth stating because each one is a branch here: the
    /// `Schemes:` header may be indented, the list ends at the first blank line, and
    /// any line containing `:` is a *different* section header (`Targets:`,
    /// `Build Configurations:`) rather than a scheme.
    ///
    /// THE SINGLE PARSER for both consumers — the Settings scheme picker
    /// (`fetchAvailableSchemes`) and the tool path (`XcodeBuildRunner.detectSchemes`).
    /// They used to have one each and disagreed three ways; see the note at the
    /// delegation site for what each got wrong.
    ///
    /// A section header ENDS the block rather than being skipped over. Skipping was
    /// the original rule and it is unsafe in the direction that matters: everything
    /// after a header belongs to that header's section, so continuing to scan reports
    /// `Debug` and `Release` as schemes. Both consumers hand the result to
    /// `xcodebuild -scheme`, where a phantom name fails the build with an error about
    /// a scheme the user never configured — so the conservative rule is the correct
    /// one, and stopping can only ever under-report a shape `xcodebuild` does not
    /// emit (measured 2026-08-08: `Schemes:` is the last section, blank-line
    /// separated from the rest).
    static func parseSchemes(fromListOutput stdout: String) -> [String] {
        var schemes: [String] = []
        var captureSchemes = false

        for line in stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("Schemes:") {
                captureSchemes = true
                continue
            }
            if captureSchemes {
                // A blank line ends the section; so does the next section's header.
                if trimmed.isEmpty || trimmed.contains(":") { break }
                schemes.append(trimmed)
            }
        }
        return schemes
    }
}
