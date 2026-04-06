import Foundation

/// Pure utility enum for Xcode build/test operations.
/// Extracted from Tools+Xcode.swift to eliminate ~65% code duplication
/// between run_xcodebuild and run_xcodetests handlers.
enum XcodeBuildRunner {

    // MARK: - Work Folder Discovery

    /// Find Xcode project/workspace/package in directory (prefers workspace).
    static func findProject(in workFolderRoot: URL, fileManager: FileManager = .default) -> XcodeProjectRef? {
        let fm = fileManager
        guard let contents = try? fm.contentsOfDirectory(atPath: workFolderRoot.path) else {
            return nil
        }

        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return XcodeProjectRef(kind: "workspace", path: workspace)
        }
        if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return XcodeProjectRef(kind: "project", path: project)
        }
        if contents.contains("Package.swift") {
            return XcodeProjectRef(kind: "package", path: ".")
        }
        return nil
    }

    // MARK: - Scheme Resolution

    enum SchemeResolution {
        case schemes([String])
        case error(ToolExecutionResult)
    }

    /// Load configured schemes from settings.json, falling back to auto-detection.
    static func resolveSchemes(
        xcodeRef: XcodeProjectRef,
        workFolderRoot: URL,
        toolName: String,
        args: [String: Any],
        fileManager: FileManager = .default
    ) -> SchemeResolution {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        var schemes: [String] = []

        // Read `settings.json` with distinct error handling for the three cases:
        //   1. file missing             → silent (expected on first run)
        //   2. file present, read fails → log + fall through to auto-detect
        //   3. file present, decode fails → HARD ERROR; do not silently build
        //      against the wrong scheme. The user's configured scheme is the
        //      source of truth when the file exists — a decode failure means
        //      schema drift, and silently auto-detecting would build the wrong
        //      target with confusing errors.
        if fileManager.fileExists(atPath: paths.settingsJSON.path) {
            do {
                let data = try Data(contentsOf: paths.settingsJSON)
                do {
                    let settings = try JSONCoderFactory.makeDateDecoder()
                        .decode(ProjectSettings.self, from: data)
                    schemes = settings.selectedScheme.map { [$0] } ?? []
                } catch {
                    return .error(makeErrorResult(
                        toolName: toolName, args: args,
                        code: .invalidArgs,
                        message:
                            """
                            Project settings file exists but could not be decoded: \(error.localizedDescription).
                            This usually means the settings schema changed after the file was last written.
                            The user should open NanoTeams settings and re-select the Xcode scheme.
                            """
                    ))
                }
            } catch {
                // Read failure (permission/IO) — log and fall through to
                // auto-detect rather than failing the tool call outright.
                print("[XcodeBuildRunner] WARNING: could not read \(paths.settingsJSON.lastPathComponent): \(error)")
            }
        }

        if schemes.isEmpty {
            let detected = detectSchemes(xcodeRef: xcodeRef, workFolderRoot: workFolderRoot)
            if !detected.isEmpty {
                schemes = [detected[0]]
            } else {
                return .error(makeErrorResult(
                    toolName: toolName, args: args,
                    code: .invalidArgs,
                    message:
                        """
                        No scheme configured in project settings.
                        Detected Xcode project: \(xcodeRef.path)
                        \(detected.isEmpty ? "No schemes could be auto-detected." : "Available schemes: \(detected.joined(separator: ", "))")
                        The user needs to select a scheme in NanoTeams settings before \(toolName == ToolNames.runXcodebuild ? "building" : "running tests").
                        """
                ))
            }
        }

        return .schemes(schemes)
    }

    /// Detect available schemes from Xcode project via xcodebuild -list.
    static func detectSchemes(xcodeRef: XcodeProjectRef, workFolderRoot: URL, fileManager: FileManager = .default) -> [String] {
        let fm = fileManager
        var schemes: [String] = []

        let listArgs: [String]
        if xcodeRef.kind == "package" {
            listArgs = ["-list"]
        } else if xcodeRef.kind == "workspace" {
            listArgs = ["-workspace", xcodeRef.path, "-list"]
        } else {
            listArgs = ["-project", xcodeRef.path, "-list"]
        }

        do {
            let result = try ProcessRunner.runXcodebuild(listArgs, in: workFolderRoot, timeout: 30)
            if let schemesRange = result.stdout.range(of: "Schemes:") {
                let afterSchemes = result.stdout[schemesRange.upperBound...]
                for line in afterSchemes.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { break }
                    if trimmed.hasPrefix("Targets:") || trimmed.hasPrefix("Build Configurations:") { break }
                    schemes.append(trimmed)
                }
            }
        } catch {
            let schemesPath = workFolderRoot
                .appendingPathComponent(xcodeRef.path)
                .appendingPathComponent("xcshareddata/xcschemes")

            if let contents = try? fm.contentsOfDirectory(atPath: schemesPath.path) {
                for file in contents where file.hasSuffix(".xcscheme") {
                    schemes.append((file as NSString).deletingPathExtension)
                }
            }
        }

        return schemes
    }

    // MARK: - Args Building

    /// Build base xcodebuild arguments from project ref, destination, and action.
    static func buildBaseArgs(xcodeRef: XcodeProjectRef, destination: String, action: String) -> [String] {
        var args: [String] = []

        if xcodeRef.kind == "workspace" {
            args += ["-workspace", xcodeRef.path]
        } else if xcodeRef.kind == "project" {
            args += ["-project", xcodeRef.path]
        }
        // kind == "package": no -project/-workspace flag — xcodebuild auto-detects Package.swift

        args += ["-destination", destination]
        args.append(action)
        return args
    }

    /// Insert scheme into args before the action keyword.
    static func injectScheme(_ scheme: String, into args: inout [String], action: String) {
        if let actionIndex = args.lastIndex(of: action) {
            args.insert(contentsOf: ["-scheme", scheme], at: actionIndex)
        } else {
            args += ["-scheme", scheme]
        }
    }

    // MARK: - Output Processing

    /// Parse xcodebuild output for error/warning/note issues.
    static func parseIssues(from output: String, workFolderRoot: URL) -> [XcodeIssue] {
        var issues: [XcodeIssue] = []

        let pattern = #"^(.+?):(\d+):(\d+):\s*(error|warning|note):\s*(.+)$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)

        let range = NSRange(output.startIndex..., in: output)
        regex?.enumerateMatches(in: output, options: [], range: range) { match, _, _ in
            guard let match = match else { return }

            let file = match.range(at: 1).location != NSNotFound
                ? String(output[Range(match.range(at: 1), in: output)!])
                : nil

            let line = match.range(at: 2).location != NSNotFound
                ? Int(output[Range(match.range(at: 2), in: output)!])
                : nil

            let column = match.range(at: 3).location != NSNotFound
                ? Int(output[Range(match.range(at: 3), in: output)!])
                : nil

            let severity = match.range(at: 4).location != NSNotFound
                ? String(output[Range(match.range(at: 4), in: output)!])
                : nil

            let message = match.range(at: 5).location != NSNotFound
                ? String(output[Range(match.range(at: 5), in: output)!])
                : ""

            // Make path relative
            var relativePath = file
            if let file = file, file.hasPrefix(workFolderRoot.path) {
                relativePath = String(file.dropFirst(workFolderRoot.path.count + 1))
            }

            issues.append(XcodeIssue(
                file: relativePath, line: line, column: column,
                severity: severity, message: message, raw: nil
            ))
        }

        return issues
    }

    /// Truncate log to last N lines.
    static func truncateLog(_ log: String, maxLines: Int) -> (log: String, truncated: Bool) {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        let truncated = lines.count > maxLines
        let result = truncated
            ? Array(lines.suffix(maxLines)).joined(separator: "\n")
            : log
        return (result, truncated)
    }

    // MARK: - Result Types

    struct BuildResult: Codable {
        var success: Bool
        var exit_code: Int
        var duration: Double
        var error_count: Int
        var warning_count: Int
        var issues: [XcodeIssue]
        var log: String
    }

    struct TestResult: Codable {
        var success: Bool
        var exit_code: Int
        var passed: Int
        var failed: Int
        var skipped: Int
        var duration: Double
        var failures: [[String: String]]
        var log: String
    }
}
