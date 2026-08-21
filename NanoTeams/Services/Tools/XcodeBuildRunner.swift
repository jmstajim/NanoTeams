import Foundation

// MARK: - xcodebuild Subprocess Seam

/// One `xcodebuild` invocation, as an injectable seam.
///
/// Everything in `XcodeBuildRunner` that *decides* — scheme resolution, argument
/// assembly, issue parsing, per-scheme aggregation — was already extracted and
/// covered. What stayed unreachable was the orchestration that binds those pieces
/// together, because the single line in the middle of it spawns a real multi-minute
/// build. So the two tool handlers' entire loop bodies, their per-scheme
/// `SchemeRun` assembly, their stop-on-first-failure rule and their envelope
/// construction were all at 0 %: 78 uncovered lines across two ~95 %-identical
/// copies.
///
/// The seam is deliberately shaped like `ProcessRunner.runXcodebuild` and nothing
/// wider. A `ProcessRunning` abstraction over `ProcessRunner.run` was considered and
/// rejected: `git` and `bash` spawn real subprocesses from this suite today
/// (`GitReadHandlers`, `BashHandlers`, `SeatbeltSandbox`) and are covered *because*
/// they do — they are fast and their side effects are confined to a temp directory.
/// `xcodebuild` is the one that is not, so it is the one that gets a seam.
///
/// **No parameter carrying this protocol has a default.** There is no honest inert
/// value for "did the build succeed" — `false` with empty output invents a failure,
/// `true` invents a success — so the inward-default rule that governs
/// `SelectionCapturing` does not apply and cannot be faked. Production names
/// `SystemXcodebuildRunner()` at each of its construction sites instead, and a
/// forgotten injection is a compile error rather than a silent multi-minute build
/// inside a test process.
nonisolated protocol XcodebuildRunning: Sendable {
    /// Runs `xcodebuild` with `arguments` in `directory`.
    ///
    /// A NON-ZERO EXIT comes back as a `Result` with `success == false`; only a
    /// missing executable, a cancellation or an expired timeout throws. That
    /// asymmetry is load-bearing — `detectSchemes` relies on it, and getting it
    /// wrong is exactly how its on-disk fallback came to be dead code (see the
    /// note there).
    func run(
        _ arguments: [String], in directory: URL, timeout: TimeInterval
    ) throws -> ProcessRunner.Result
}

/// Production conformance — the real subprocess.
///
/// Lives in this file rather than its own so it does not constitute a 0 %-coverage
/// file of its own. Its three lines are genuinely unreachable from a test process
/// (covering them means spawning a build), and a whole file at 0 % is the residue
/// shape this effort treats as a smell: either the shim should be thinner or the
/// extraction did not take the decision. Here the decision is entirely in
/// `XcodeBuildRunner` below, so the adapter belongs beside it.
nonisolated struct SystemXcodebuildRunner: XcodebuildRunning {
    func run(
        _ arguments: [String], in directory: URL, timeout: TimeInterval
    ) throws -> ProcessRunner.Result {
        try ProcessRunner.runXcodebuild(arguments, in: directory, timeout: timeout)
    }
}

/// Pure utility enum for Xcode build/test operations.
/// Extracted from Tools+Xcode.swift to eliminate ~65% code duplication
/// between run_xcodebuild and run_xcodetests handlers.
nonisolated enum XcodeBuildRunner {

    // MARK: - Tunables
    //
    // Named here rather than re-spelled in each handler, which is where they used to
    // live as `let` locals inside the duplicated bodies.

    /// The only destination either tool has ever passed. NanoTeams is a macOS app.
    static let defaultDestination = "platform=macOS"

    /// Trailing log lines kept when a run fails. See `aggregateBuild` for why this is
    /// the only cap.
    static let defaultMaxLogLines = 30

    /// `xcodebuild build` — long enough for a cold full build.
    static let buildTimeout: TimeInterval = 600

    /// `xcodebuild test` — double the build budget, because a test run builds first.
    static let testTimeout: TimeInterval = 1200

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
    ///
    /// `runner` has no default on purpose: auto-detection spawns `xcodebuild -list`,
    /// and before the seam existed three tests reached it with a real subprocess —
    /// gated behind `skipUnlessXcodebuildIsInstalled`, so on a machine without the
    /// toolchain they contributed nothing at all. Requiring the argument makes each
    /// call site state whether it expects a subprocess, which turns the
    /// "no subprocess" claim in the settings-path tests from a section comment into
    /// an assertion.
    static func resolveSchemes(
        xcodeRef: XcodeProjectRef,
        workFolderRoot: URL,
        toolName: String,
        args: [String: Any],
        runner: any XcodebuildRunning,
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
                    // Trimmed, because a BLANK stored scheme is "not configured", not a
                    // scheme named "". `[""]` is non-empty, so it skipped the auto-detect
                    // branch below and sent `-scheme ""` to xcodebuild.
                    let stored = (settings.selectedScheme ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    schemes = stored.isEmpty ? [] : [stored]
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
            let detected = detectSchemes(
                xcodeRef: xcodeRef, workFolderRoot: workFolderRoot,
                runner: runner, fileManager: fileManager)
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
    ///
    /// `fileManager` reaches the on-disk fallback below. It used to be dropped:
    /// `resolveSchemes` called this without forwarding its own, so a caller that
    /// substituted a file manager still had the `xcshareddata/xcschemes` scan run
    /// against the real filesystem — the same "DI contract got dropped" defect
    /// `fetchAvailableSchemes` documents on itself.
    static func detectSchemes(
        xcodeRef: XcodeProjectRef,
        workFolderRoot: URL,
        runner: any XcodebuildRunning,
        fileManager: FileManager = .default
    ) -> [String] {
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

        // `ProcessRunner.run` throws only when the executable is missing, the task was
        // cancelled, or the timeout expired — a NON-ZERO EXIT comes back as a Result with
        // `success == false`. So the on-disk fallback below, written inside a `catch`,
        // never ran for the common case: a malformed project makes `xcodebuild -list` exit
        // non-zero, stdout carries no "Schemes:", and the user was told "no schemes could
        // be auto-detected" while `xcshareddata/xcschemes` sat there full of them.
        //
        // Parsing delegates to `XcodeBuildHelpers.parseSchemes`, which is the SAME parser
        // the Settings scheme picker uses. There used to be a second one inlined here, and
        // the two disagreed on the shape `xcodebuild` actually emits:
        //
        //   * this one claimed to stop at the first blank line, and could not. It split with
        //     `split(separator: "\n")`, whose `omittingEmptySubsequences` defaults to TRUE,
        //     so the blank line was removed before the `isEmpty` break could see it —
        //     everything after the scheme list became a scheme, and a phantom scheme goes
        //     straight into `-scheme <phantom>` and fails the build with a confusing error.
        //     Same defect class as `truncateLog`'s CRLF split: a stop condition that quietly
        //     stops stopping.
        //   * it also broke at exactly two known section headers, so any third one truncated
        //     the list, while the picker's parser skipped headers and kept scanning.
        //
        // Measured against this project (`xcodebuild -list`, 2026-08-08): `Schemes:` is the
        // LAST section, its list is followed by a blank line and EOF — so a healthy project
        // hid the disagreement, and only a malformed one surfaced it.
        if let result = try? runner.run(listArgs, in: workFolderRoot, timeout: 30) {
            schemes = XcodeBuildHelpers.parseSchemes(fromListOutput: result.stdout)
        }

        if schemes.isEmpty {
            let schemesPath = workFolderRoot
                .appendingPathComponent(xcodeRef.path)
                .appendingPathComponent("xcshareddata/xcschemes")

            if let contents = try? fm.contentsOfDirectory(atPath: schemesPath.path) {
                for file in contents.sorted() where file.hasSuffix(".xcscheme") {
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

    /// Relativizes one path emitted by xcodebuild against the work-folder root, for BOTH the
    /// build-issue parser below and the test-failure parser in `XcodeHandlers`.
    ///
    /// Component-wise containment, never a string prefix: `URL.path` carries no trailing slash, so
    /// `hasPrefix` matched any sibling whose name merely EXTENDS the root's (the same defect class
    /// as `…/Application Supportive` matching `…/Application Support`), and the paired
    /// `dropFirst(count + 1)` separator-eater then consumed a real character of that sibling's own
    /// name — emitting `rivate/Sources/A.swift` for a file under `/Users/x/NanoTeamsPrivate`. That
    /// path has never existed, so the model chased a `read_file` that could not resolve while the
    /// true out-of-folder origin of the issue was hidden. Delegating to
    /// `NTMSPaths.relativePathFromProjectRoot` also buys symlink-aware containment, which a string
    /// prefix misses for the `/var`↔`/private/var` spellings xcodebuild mixes freely.
    ///
    /// A path that is NOT under the root is returned unchanged (absolute) rather than truncated or
    /// emptied: an honest absolute path keeps the origin visible, where the old truncation produced
    /// a plausible-but-nonexistent relative one. Same reasoning for the degenerate
    /// `file == workFolderRoot` case, where `dropFirst` past the end silently yielded "" and erased
    /// the issue's location entirely. Pinned by `XcodeIssuePathRelativizationTests`.
    static func relativizeIssuePath(_ file: String, workFolderRoot: URL) -> String {
        guard file.hasPrefix("/") else { return file }   // non-path token / already relative
        let relative = NTMSPaths(workFolderRoot: workFolderRoot)
            .relativePathFromProjectRoot(for: URL(fileURLWithPath: file))
        return relative.isEmpty ? file : relative
    }

    /// What one scheme's `xcodebuild test` output says happened.
    ///
    /// `line` is a STRING because that is what the envelope carries — the failure
    /// records are `[String: String]` all the way to the model, and `MemoryTagStore`
    /// reads them back from JSON where the field is a string.
    nonisolated struct TestOutcome: Equatable {
        var passed: Int
        var failed: Int
        var failures: [[String: String]]

        static let empty = TestOutcome(passed: 0, failed: 0, failures: [])
    }

    /// Parse one scheme's `xcodebuild test` output into counts + failure records.
    ///
    /// Extracted from `RunXcodetestsTool` for the same reason `parseIssues` above was:
    /// the parsing is the interesting part, and the handler wraps it around
    /// `ProcessRunner.runXcodebuild`, which spawns a real multi-minute build and so is
    /// unreachable from a test process.
    ///
    /// The result-line match is CASE-INSENSITIVE. Xcode 26 prints
    /// `Test case 'Suite.testName()' passed on 'My Mac - …'` (lowercase `c`), while the
    /// older shape is `Test Case '-[Suite testName]' passed`. The pattern was
    /// `#"Test Case .+ passed"#`, so on the current toolchain it matched NOTHING and
    /// `run_xcodetests` reported `passed: 0, failed: 0` for every run — a green suite and
    /// a red one produced the same counts, and only the process exit code distinguished
    /// them. Measured against this repo's own output, not recalled.
    static func parseTestOutcome(
        output: String, scheme: String, workFolderRoot: URL
    ) -> TestOutcome {
        var outcome = TestOutcome.empty
        let fullRange = NSRange(output.startIndex..., in: output)

        func count(_ pattern: String) -> Int {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]) else { return 0 }
            return regex.numberOfMatches(in: output, range: fullRange)
        }
        outcome.passed = count(#"Test Case .+ passed"#)
        outcome.failed = count(#"Test Case .+ failed"#)

        guard let failureRegex = try? NSRegularExpression(
            pattern: #"(.+?):(\d+):\s*error:\s*(.+)"#) else { return outcome }

        failureRegex.enumerateMatches(in: output, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            var failure: [String: String] = ["scheme": scheme]

            if match.range(at: 1).location != NSNotFound,
               let fileRange = Range(match.range(at: 1), in: output) {
                failure["file"] = relativizeIssuePath(
                    String(output[fileRange]), workFolderRoot: workFolderRoot)
            }
            if match.range(at: 2).location != NSNotFound,
               let lineRange = Range(match.range(at: 2), in: output) {
                failure["line"] = String(output[lineRange])
            }
            if match.range(at: 3).location != NSNotFound,
               let msgRange = Range(match.range(at: 3), in: output) {
                failure["message"] = String(output[msgRange])
            }
            outcome.failures.append(failure)
        }
        return outcome
    }

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

            // Make path relative (component-wise — see `relativizeIssuePath`).
            let relativePath = file.map { relativizeIssuePath($0, workFolderRoot: workFolderRoot) }

            issues.append(XcodeIssue(
                file: relativePath, line: line, column: column,
                severity: severity, message: message, raw: nil
            ))
        }

        return issues
    }

    /// Truncate log to last N lines.
    ///
    /// Splits on the SCALAR `\n`, not the `Character` `"\n"`. In Swift `"\r\n"`
    /// is a single grapheme cluster that does not equal `"\n"`, so the previous
    /// `log.split(separator: "\n")` found no separators at all in a CRLF log:
    /// `lines.count` was 1, `truncated` was false, and the cap silently did not
    /// apply — an unbounded log went into the conversation and into
    /// `build_excerpts.txt`. `xcodebuild` itself emits LF, so this was latent,
    /// but a cap that quietly stops capping is the failure mode this codebase
    /// treats as worse than the cap itself. `LineScanner` splits on scalars for
    /// the same reason.
    ///
    /// For LF-only input the result is byte-identical to the previous
    /// implementation; a CRLF line keeps its `\r` as trailing content, so the
    /// bytes that survive are exactly the bytes that were there.
    static func truncateLog(_ log: String, maxLines: Int) -> (log: String, truncated: Bool) {
        // `suffix(_:)` traps on a negative count. No caller passes one today
        // (both handlers hardcode `maxLogLines`), so clamping keeps a shared
        // helper from being able to kill the process if one ever does.
        let cap = max(0, maxLines)
        let lines = log.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        let truncated = lines.count > cap
        let result = truncated
            ? lines.suffix(cap).joined(separator: "\n")
            : log
        return (result, truncated)
    }

    // MARK: - Per-scheme aggregation

    /// One completed `xcodebuild` invocation, as the aggregators below see it.
    ///
    /// The handlers own the subprocess; everything they do with its OUTPUT is folded
    /// here. Same extraction, and the same reason, as `parseTestOutcome` above: the
    /// aggregation is the interesting part, and it sat inside a loop wrapped around
    /// `ProcessRunner.runXcodebuild`, which spawns a real multi-minute build and so is
    /// unreachable from a test process. Before this seam existed, both handlers' loop
    /// bodies and their whole envelope assembly were at 0%.
    nonisolated struct SchemeRun: Equatable {
        var scheme: String
        /// `stdout + stderr`, in that order — what the handlers concatenate before parsing.
        var output: String
        var success: Bool
        var exitCode: Int
    }

    /// Every `xcodebuild` invocation of one tool call, plus the wall-clock they took.
    nonisolated struct SchemeSweep: Equatable {
        var runs: [SchemeRun]
        /// Summed elapsed time across the invocations that actually ran. `Date()`, not
        /// `MonotonicClock` — this is an elapsed-time measurement, which is the one
        /// case CLAUDE.md's timestamp convention exempts.
        var duration: Double

        static let empty = SchemeSweep(runs: [], duration: 0)
    }

    /// Run one action across `schemes`, stopping at the first failure.
    ///
    /// The stop rule is a contract, not an optimization: a scheme that fails to build
    /// invalidates everything downstream of it, and continuing would bury the real
    /// diagnostic under later schemes' cascading noise. It is also why
    /// `aggregateBuild` can take the last failing scheme's exit code as *the* exit
    /// code — there is only ever one.
    ///
    /// Extracted from `RunXcodebuildTool` and `RunXcodetestsTool`, whose loop bodies
    /// were ~95 % identical: same base args, same scheme injection, same timing, same
    /// `SchemeRun` assembly, same stop rule. They differed in three values (action,
    /// timeout, aggregator) and in nothing else, and both copies were entirely
    /// uncovered because of the one subprocess line in the middle.
    static func runSchemes(
        _ schemes: [String],
        xcodeRef: XcodeProjectRef,
        workFolderRoot: URL,
        action: String,
        destination: String = defaultDestination,
        timeout: TimeInterval,
        runner: any XcodebuildRunning
    ) throws -> SchemeSweep {
        let baseArgs = buildBaseArgs(
            xcodeRef: xcodeRef, destination: destination, action: action)
        var sweep = SchemeSweep.empty

        for scheme in schemes {
            var args = baseArgs
            injectScheme(scheme, into: &args, action: action)

            let startedAt = Date()
            let result = try runner.run(args, in: workFolderRoot, timeout: timeout)
            sweep.duration += Date().timeIntervalSince(startedAt)

            sweep.runs.append(SchemeRun(
                scheme: scheme,
                output: result.stdout + result.stderr,
                success: result.success,
                exitCode: Int(result.exitCode)
            ))

            if !result.success { break }
        }
        return sweep
    }

    /// What `sweep` produced, or the tool-envelope error that stopped it first.
    enum SweepOutcome {
        case swept(SchemeSweep)
        case error(ToolExecutionResult)
    }

    /// Locate the project, resolve its schemes, and run `action` across them.
    ///
    /// The whole prologue both Xcode tools share. Folding it here is what makes the
    /// handlers thin enough to be *entirely* dispatch: each is now a switch over this
    /// outcome plus its own aggregator, so the only thing left that distinguishes them
    /// is the pair of values they were always meant to differ in.
    static func sweep(
        workFolderRoot: URL,
        toolName: String,
        args: [String: Any],
        action: String,
        timeout: TimeInterval,
        runner: any XcodebuildRunning,
        fileManager: FileManager = .default
    ) throws -> SweepOutcome {
        guard let xcodeRef = findProject(in: workFolderRoot, fileManager: fileManager) else {
            return .error(missingProjectError(toolName: toolName, args: args))
        }

        switch resolveSchemes(
            xcodeRef: xcodeRef, workFolderRoot: workFolderRoot,
            toolName: toolName, args: args, runner: runner, fileManager: fileManager
        ) {
        case .error(let errorResult):
            return .error(errorResult)
        case .schemes(let schemes):
            return .swept(try runSchemes(
                schemes, xcodeRef: xcodeRef, workFolderRoot: workFolderRoot,
                action: action, timeout: timeout, runner: runner))
        }
    }

    /// "There is no Xcode project here", identically for both tools.
    ///
    /// The two handlers had drifted: `run_xcodebuild` said "found in project root."
    /// and carried a `list_files` recovery hint, `run_xcodetests` said "found" and
    /// carried none. Same condition, same remedy — but only one of them told the
    /// model how to check, so a model that hit it through `run_xcodetests` had
    /// nothing to act on. The hint is the useful half, so both get it.
    static func missingProjectError(
        toolName: String, args: [String: Any]
    ) -> ToolExecutionResult {
        makeErrorResult(
            toolName: toolName, args: args,
            code: .fileNotFound,
            message: "No .xcodeproj, .xcworkspace, or Package.swift found in project root.",
            next: NextHint(
                suggested_cmd: ToolNames.listFiles,
                suggested_args: ["path": "."],
                reason: "Check project structure"
            )
        )
    }

    /// The combined log shown to the model: one `--- Scheme: X ---` header per
    /// invocation, blank-line separated after the first.
    static func combinedLog(for runs: [SchemeRun]) -> String {
        var log = ""
        for run in runs {
            log += log.isEmpty
                ? "--- Scheme: \(run.scheme) ---\n"
                : "\n\n--- Scheme: \(run.scheme) ---\n"
            log += run.output
        }
        return log
    }

    /// Fold `run_xcodebuild`'s per-scheme results into its envelope payload.
    ///
    /// `exit_code` is the LAST failing scheme's — which is also the ONLY failing one,
    /// because the handler stops feeding runs after the first failure. Kept as
    /// last-wins so the fold matches the loop it replaced byte for byte.
    ///
    /// `truncated` reports the line cap, which is now the only one. A second, character cap
    /// used to sit on top and reach `meta` separately — a log fitting in `maxLines` but past
    /// 5000 chars lost the overflow with `truncated: false`. Rather than report that cap, it
    /// was removed: see the note at the call site.
    static func aggregateBuild(
        runs: [SchemeRun], workFolderRoot: URL, duration: Double, maxLines: Int
    ) -> (data: BuildResult, truncated: Bool) {
        var issues: [XcodeIssue] = []
        var success = true
        var exitCode = 0

        for run in runs {
            if !run.success {
                success = false
                exitCode = run.exitCode
            }
            issues.append(contentsOf: parseIssues(from: run.output, workFolderRoot: workFolderRoot))
        }

        // ONE cap, by lines. The 5000-character cut that used to sit on top of this was
        // removed deliberately: the log ships only when the build FAILED, so it truncated
        // exactly the diagnostic the model needs, and a single long linker invocation or Swift
        // type name pushes a real error past 5000 chars while the line cap would have kept it.
        // Note (2026-08-11): the tag store no longer collapses repeat builds to a reference —
        // each build re-ships its full summary. The line cap here is the only size bound, per
        // the product's no-hard-byte-caps preference.
        let (log, lineTruncated) = truncateLog(combinedLog(for: runs), maxLines: maxLines)

        return (
            BuildResult(
                success: success,
                exit_code: exitCode,
                duration: duration,
                error_count: issues.filter { $0.severity == "error" }.count,
                warning_count: issues.filter { $0.severity == "warning" }.count,
                issues: issues,
                log: success ? "" : log
            ),
            lineTruncated
        )
    }

    /// Fold `run_xcodetests`' per-scheme results into its envelope payload.
    ///
    /// `success` is `xcodebuild exited 0` AND `no test reported a failure` — a suite can
    /// exit non-zero for a build error with zero failed tests, and a green exit code
    /// alongside parsed failures would be a lie in the other direction.
    static func aggregateTests(
        runs: [SchemeRun], workFolderRoot: URL, duration: Double, maxLines: Int
    ) -> (data: TestResult, truncated: Bool) {
        var passed = 0
        var failed = 0
        var failures: [[String: String]] = []
        var exitedCleanly = true
        var exitCode = 0

        for run in runs {
            if !run.success {
                exitedCleanly = false
                exitCode = run.exitCode
            }
            let outcome = parseTestOutcome(
                output: run.output, scheme: run.scheme, workFolderRoot: workFolderRoot)
            passed += outcome.passed
            failed += outcome.failed
            failures.append(contentsOf: outcome.failures)
        }

        let (log, truncated) = truncateLog(combinedLog(for: runs), maxLines: maxLines)
        let success = exitedCleanly && failed == 0

        return (
            TestResult(
                success: success,
                exit_code: exitCode,
                passed: passed,
                failed: failed,
                skipped: 0,
                duration: duration,
                failures: failures,
                log: success ? "" : log
            ),
            truncated
        )
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
