import Foundation

/// Helper structures and utilities for Xcode build operations.
enum XcodeBuildHelpers {
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
    /// Runs on a background thread to avoid blocking the main actor.
    /// - Parameter workFolderRoot: The project root URL.
    /// - Returns: An array of scheme names.
    static func fetchAvailableSchemes(workFolderRoot: URL, fileManager: FileManager = .default) async -> [String] {
        let fm = fileManager
        return await Task.detached {
            guard let contents = try? fm.contentsOfDirectory(atPath: workFolderRoot.path) else {
                return []
            }

            var args: [String] = ["-list"]
            if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
                args += ["-workspace", workspace]
            } else if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
                args += ["-project", project]
            } else {
                return []
            }

            guard let result = try? ProcessRunner.runXcodebuild(args, in: workFolderRoot, timeout: 60) else {
                return []
            }

            // Parse schemes from text output
            let lines = result.stdout.components(separatedBy: .newlines)
            var schemes: [String] = []
            var captureSchemes = false

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix("Schemes:") {
                    captureSchemes = true
                    continue
                }
                if captureSchemes {
                    if trimmed.isEmpty {
                        break
                    }
                    if !trimmed.contains(":") {
                        schemes.append(trimmed)
                    }
                }
            }
            return schemes
        }.value
    }
}
