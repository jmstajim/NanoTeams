import Foundation

// MARK: - Build/Test Summary Extraction

extension MemoryTagStore {

    /// Build compact summary from run_xcodebuild envelope JSON.
    func extractBuildSummary(from outputJSON: String) -> String {
        guard let parsed = parseJSON(outputJSON),
              let data = parsed["data"] as? [String: Any] else {
            return "BUILD UNKNOWN"
        }

        let success = data["success"] as? Bool ?? false
        let errorCount = data["error_count"] as? Int ?? 0
        let warningCount = data["warning_count"] as? Int ?? 0

        if success && errorCount == 0 {
            if warningCount > 0 {
                return "BUILD SUCCESS: \(warningCount) warning(s)"
            }
            return "BUILD SUCCESS"
        }

        var lines = ["BUILD FAILED: \(errorCount) error(s), \(warningCount) warning(s)"]

        if let issues = data["issues"] as? [[String: Any]] {
            for issue in issues.prefix(10) {
                let severity = issue["severity"] as? String ?? "E"
                let message = issue["message"] as? String ?? "?"
                let file = issue["file"] as? String
                let line = issue["line"] as? Int
                let prefix = severity.lowercased().hasPrefix("w") ? "[W]" : "[E]"
                var issueLine = "\(prefix) \(message)"
                if let file = file {
                    issueLine += " — \(file)"
                    if let line = line {
                        issueLine += ":\(line)"
                    }
                }
                lines.append(issueLine)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Test compact summary from run_xcodetests envelope JSON.
    func extractTestSummary(from outputJSON: String) -> String {
        guard let parsed = parseJSON(outputJSON),
              let data = parsed["data"] as? [String: Any] else {
            return "TESTS UNKNOWN"
        }

        let success = data["success"] as? Bool ?? false
        let passed = data["passed"] as? Int ?? data["tests_passed"] as? Int ?? 0
        let failed = data["failed"] as? Int ?? data["tests_failed"] as? Int ?? 0
        let skipped = data["skipped"] as? Int ?? 0

        if success && failed == 0 {
            return "TESTS PASSED: \(passed) passed"
        }

        var lines = ["TESTS FAILED: \(passed) passed, \(failed) failed, \(skipped) skipped"]

        if let failures = data["failures"] as? [[String: Any]] {
            for failure in failures.prefix(10) {
                let message = failure["message"] as? String ?? "?"
                let file = failure["file"] as? String
                let line = failure["line"] as? Int
                var failLine = "[F] \(message)"
                if let file = file {
                    failLine += " — \(file)"
                    if let line = line {
                        failLine += ":\(line)"
                    }
                }
                lines.append(failLine)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Parse "[E] message — file:line" lines from a build summary for delta comparison.
    func parseBuildErrorLines(from summary: String) -> Set<String> {
        Set(
            summary.components(separatedBy: "\n")
                .filter { $0.hasPrefix("[E]") || $0.hasPrefix("[F]") }
        )
    }
}
