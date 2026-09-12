import Foundation

// MARK: - Build/Test Summary Extraction

nonisolated extension MemoryTagStore {

    /// How many issue / failure lines a summary renders before it says how many it left
    /// out. Named because it is a WIRE budget read by two extractors and asserted by
    /// their tests — as a bare `prefix(10)` in each it read as an implementation detail,
    /// and the second copy silently disagreed with the first about what it bounded.
    static let summaryMaxDetailLines = 10

    /// Build compact summary from run_xcodebuild envelope JSON.
    ///
    /// **This is the only build diagnostic the model ever sees.** `run_xcodebuild` returns
    /// a SUCCESS envelope even on `BUILD FAILED` (`XcodeHandlers`), so the raw `issues`
    /// array reaches the activity feed and `tool_calls.jsonl` but never the wire —
    /// `BuildGitToolProcessor.processBuild` replaces it with this string. Two consequences
    /// shape what follows, and both were live defects until 2026-09-11:
    ///
    /// 1. Issues arrive in LOG order, not severity order, and the renderer took the first
    ///    ten of them. Twelve warnings ahead of the single error meant the model read
    ///    `BUILD FAILED: 1 error(s), 12 warning(s)` followed by ten `[W]` lines and not one
    ///    `[E]` — it never learned which symbol failed to compile.
    /// 2. A failure with no `file:line:col:` diagnostic at all — a linker error, a
    ///    `Multiple commands produce`, a killed process — parses to zero issues, and the
    ///    summary was then the header alone: `BUILD FAILED: 0 error(s), 0 warning(s)`.
    ///    The 30-line log tail that would have explained it sits in `data.log`, which this
    ///    extractor never read. The model's only move is to run the same build again.
    ///
    /// The rule that answers both: **a failed build never reaches the model without
    /// something actionable.** Errors take the line budget FIRST — sorted ahead of
    /// warnings and notes rather than replacing them, so nothing is discarded while the
    /// budget has room — and if no `[E]` line survives to act on, the log tail ships
    /// instead of a bare header.
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

        let issues = (data["issues"] as? [[String: Any]]) ?? []
        let rendered = issues.map { issue -> String in
            let tag = Self.severityTag(issue["severity"] as? String)
            let message = issue["message"] as? String ?? "?"
            var issueLine = "\(tag) \(message)"
            if let file = issue["file"] as? String {
                issueLine += " — \(file)"
                if let line = issue["line"] as? Int {
                    issueLine += ":\(line)"
                }
            }
            return issueLine
        }

        // Errors first. `parseIssues` appends in LOG order and `aggregateBuild`
        // concatenates schemes without sorting, so severity order is not a property of the
        // input and has to be imposed here. A STABLE partition, not a sort: within each
        // severity the compiler's own order is the useful one (the first error is usually
        // the cause of the rest), and reordering it would cost more than it buys.
        let shown = rendered.filter { $0.hasPrefix("[E]") } + rendered.filter { !$0.hasPrefix("[E]") }
        lines.append(contentsOf: shown.prefix(Self.summaryMaxDetailLines))
        if shown.count > Self.summaryMaxDetailLines {
            // Say what was dropped. Silent truncation reads as "that is all of them", and
            // a model that believes it has seen every error stops after fixing ten.
            lines.append("… and \(shown.count - Self.summaryMaxDetailLines) more")
        }

        // The invariant, stated as code: no `[E]` line means the parser found nothing the
        // model can act on, so the log tail is the diagnostic. It is already bounded to
        // `XcodeBuildRunner.defaultMaxLogLines` and is already populated only on failure.
        if !shown.prefix(Self.summaryMaxDetailLines).contains(where: { $0.hasPrefix("[E]") }) {
            lines.append(contentsOf: Self.logTailLines(data, why: "no file:line diagnostics were parsed"))
        }

        return lines.joined(separator: "\n")
    }

    /// Test compact summary from run_xcodetests envelope JSON.
    ///
    /// Same rule as the build summary, for the same reason: `0 passed, 0 failed` with an
    /// empty `failures` array is what a suite whose TARGET did not build looks like from
    /// here, and rendering it as a bare header tells the model nothing it can act on.
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

        let failures = (data["failures"] as? [[String: Any]]) ?? []
        let rendered = failures.map { failure -> String in
            let message = failure["message"] as? String ?? "?"
            // The producer is `XcodeBuildRunner.TestResult.failures`, typed
            // `[[String: String]]`, so `line` arrives as a STRING and the
            // old `as? Int` never once succeeded — the `:line` suffix below
            // was unreachable and every test failure reached the model
            // without its line number. Accept both spellings rather than
            // depending on which side is right.
            let line = (failure["line"] as? Int)
                ?? (failure["line"] as? String).flatMap(Int.init)
            var failLine = "[F] \(message)"
            if let file = failure["file"] as? String {
                failLine += " — \(file)"
                if let line = line {
                    failLine += ":\(line)"
                }
            }
            return failLine
        }
        lines.append(contentsOf: rendered.prefix(Self.summaryMaxDetailLines))
        if rendered.count > Self.summaryMaxDetailLines {
            lines.append("… and \(rendered.count - Self.summaryMaxDetailLines) more")
        }

        if rendered.isEmpty {
            lines.append(contentsOf: Self.logTailLines(data, why: "no individual test failure was parsed"))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Shared rendering

    /// `[E]` / `[W]` / `[N]`, by explicit severity, with `[E]` as the default for a
    /// missing or unrecognised token — an unclassified issue must not be downgraded to
    /// something ignorable. `note` gets its own tag rather than falling into that default:
    /// it is a KNOWN severity that `error_count` does not count, so rendering it `[E]`
    /// both inflated the error list and, once errors became the filter, would have smuggled
    /// notes in beside them.
    static func severityTag(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case let s? where s.hasPrefix("w"): return "[W]"
        case let s? where s.hasPrefix("note"): return "[N]"
        default: return "[E]"
        }
    }

    /// The trailing log, labelled with why it is here. Empty when the envelope carries no
    /// log — the caller appends unconditionally and gets nothing rather than a bare header.
    private static func logTailLines(_ data: [String: Any], why: String) -> [String] {
        guard let log = (data["log"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !log.isEmpty else { return [] }
        return ["", "Log tail (\(why)):", log]
    }
}
