import XCTest

@testable import NanoTeams

/// The orchestration between "we know which schemes to run" and "here is the envelope",
/// which until the `XcodebuildRunning` seam existed was 78 uncovered lines living as two
/// ~95 %-identical copies inside `RunXcodebuildTool` and `RunXcodetestsTool`.
///
/// Everything those copies did with the subprocess *output* had already been extracted and
/// covered (`parseIssues`, `parseTestOutcome`, `combinedLog`, `truncateLog`,
/// `aggregateBuild`, `aggregateTests`). What stayed unreachable was the part that binds
/// them: the per-scheme loop, the argv assembly per iteration, the stop-on-first-failure
/// rule, and the assembly of the success envelope. A single line in the middle of it
/// spawned a real multi-minute `xcodebuild`, so the whole surrounding body was untestable —
/// and being untestable is how the two copies drifted apart without anyone noticing.
///
/// RED markers name a mutation and the assertion it breaks. `RecordingXcodebuildRunner`
/// scripts per-scheme results; `ForbiddenXcodebuildRunner` fails on being reached, which is
/// how the "this path must not spawn anything" claims are enforced rather than commented.
final class XcodeSweepCoverageTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt_sweep_\(UUID().uuidString.prefix(8))", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeProject(_ name: String = "App.xcodeproj") throws -> XcodeProjectRef {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        return XcodeProjectRef(kind: "project", path: name)
    }

    private func configureScheme(_ scheme: String) throws {
        let paths = NTMSPaths(workFolderRoot: root)
        try FileManager.default.createDirectory(
            at: paths.internalDir, withIntermediateDirectories: true)
        try #"{"selectedScheme":"\#(scheme)"}"#
            .write(to: paths.settingsJSON, atomically: true, encoding: .utf8)
    }

    // MARK: - runSchemes: the loop both tools share

    /// The stop rule. A scheme that fails invalidates everything downstream of it, so the
    /// sweep must not continue — and it is that rule which lets `aggregateBuild` treat the
    /// last failing exit code as *the* exit code, because there is only ever one.
    ///
    /// RED: delete `if !result.success { break }` → the second scheme runs, `calls.count`
    /// becomes 2 and `runs.count` becomes 2.
    func testRunSchemes_stopsAtTheFirstFailure() throws {
        let ref = try makeProject()
        let runner = RecordingXcodebuildRunner(responses: [
            .failed(65, stdout: "boom"),
            .ok("never reached"),
        ])

        let sweep = try XcodeBuildRunner.runSchemes(
            ["Alpha", "Beta"], xcodeRef: ref, workFolderRoot: root,
            action: "build", timeout: 1, runner: runner)

        XCTAssertEqual(runner.callCount, 1, "Beta must not be attempted after Alpha failed")
        XCTAssertEqual(sweep.runs.count, 1)
        XCTAssertEqual(sweep.runs.first?.scheme, "Alpha")
        XCTAssertEqual(sweep.runs.first?.exitCode, 65)
        XCTAssertEqual(sweep.runs.first?.success, false)
    }

    /// …and the converse: when every scheme succeeds, every scheme runs. Without this the
    /// stop-rule test above would also pass against a loop that always ran exactly once.
    func testRunSchemes_allSucceeding_runsEveryScheme() throws {
        let ref = try makeProject()
        let runner = RecordingXcodebuildRunner(responses: [.ok("one"), .ok("two"), .ok("three")])

        let sweep = try XcodeBuildRunner.runSchemes(
            ["A", "B", "C"], xcodeRef: ref, workFolderRoot: root,
            action: "build", timeout: 1, runner: runner)

        XCTAssertEqual(sweep.runs.map(\.scheme), ["A", "B", "C"])
        XCTAssertEqual(sweep.runs.map(\.output), ["one", "two", "three"])
        XCTAssertTrue(sweep.runs.allSatisfy(\.success))
    }

    /// Each iteration re-derives its argv from the base, so scheme N+1 cannot inherit
    /// scheme N's `-scheme` flag.
    ///
    /// RED: hoist `var args = baseArgs` out of the loop → the second call's argv carries
    /// both schemes and this fails.
    func testRunSchemes_eachIterationGetsExactlyItsOwnScheme() throws {
        let ref = try makeProject()
        let runner = RecordingXcodebuildRunner(responses: [.ok(), .ok()])

        _ = try XcodeBuildRunner.runSchemes(
            ["Alpha", "Beta"], xcodeRef: ref, workFolderRoot: root,
            action: "build", timeout: 42, runner: runner)

        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [["-project", "App.xcodeproj", "-destination", "platform=macOS",
              "-scheme", "Alpha", "build"],
             ["-project", "App.xcodeproj", "-destination", "platform=macOS",
              "-scheme", "Beta", "build"]],
            "the scheme goes before the action keyword, and only one per invocation")
        XCTAssertEqual(runner.calls.map(\.timeout), [42, 42])
        XCTAssertEqual(runner.calls.first?.directory, root, "runs in the work folder")
    }

    /// `stdout` then `stderr`, in that order. The parsers downstream read a single string,
    /// and `xcodebuild` puts compiler diagnostics on stdout and its own errors on stderr —
    /// concatenating the other way round would put the summary before the detail.
    func testRunSchemes_output_isStdoutThenStderr() throws {
        let ref = try makeProject()
        let runner = RecordingXcodebuildRunner(
            responses: [.failed(1, stdout: "OUT", stderr: "ERR")])

        let sweep = try XcodeBuildRunner.runSchemes(
            ["A"], xcodeRef: ref, workFolderRoot: root,
            action: "build", timeout: 1, runner: runner)

        XCTAssertEqual(sweep.runs.first?.output, "OUTERR")
    }

    /// A non-zero exit is data; a timeout is not. `ProcessRunner` only throws for a missing
    /// executable, a cancellation, or an expired deadline, and those must reach the
    /// handler's `ToolErrorHandler.execute` rather than being folded into a `SchemeRun`
    /// that claims the build merely "failed".
    ///
    /// RED: wrap the `runner.run` call in `try?` → the throw becomes a silent empty sweep,
    /// which `aggregateBuild` then reports as `success: true`.
    func testRunSchemes_aThrownError_propagatesRatherThanBecomingAFailedRun() throws {
        let ref = try makeProject()
        let runner = RecordingXcodebuildRunner(
            thrown: ProcessRunnerError.timeout(600, stdout: "partial", stderr: ""))

        XCTAssertThrowsError(
            try XcodeBuildRunner.runSchemes(
                ["A"], xcodeRef: ref, workFolderRoot: root,
                action: "build", timeout: 1, runner: runner))
    }

    func testRunSchemes_noSchemes_runsNothingAndReportsAnEmptySweep() throws {
        let ref = try makeProject()
        let runner = ForbiddenXcodebuildRunner()

        let sweep = try XcodeBuildRunner.runSchemes(
            [], xcodeRef: ref, workFolderRoot: root,
            action: "build", timeout: 1, runner: runner)

        XCTAssertEqual(sweep, .empty)
        XCTAssertFalse(runner.reached)
    }

    // MARK: - sweep: the prologue both tools share

    func testSweep_noProject_errorsWithoutTouchingXcodebuild() throws {
        let runner = ForbiddenXcodebuildRunner()

        guard case .error(let result) = try XcodeBuildRunner.sweep(
            workFolderRoot: root, toolName: ToolNames.runXcodebuild, args: [:],
            action: "build", timeout: 1, runner: runner)
        else { return XCTFail("expected an error outcome") }

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("FILE_NOT_FOUND"), result.outputJSON)
        XCTAssertFalse(runner.reached, "there is nothing to ask xcodebuild about")
    }

    /// A scheme-resolution error stops the sweep before any invocation.
    ///
    /// Uses the undecodable-settings hard error, which is the one resolution failure that
    /// must NOT fall through to auto-detection.
    func testSweep_schemeResolutionError_stopsBeforeRunning() throws {
        _ = try makeProject()
        let paths = NTMSPaths(workFolderRoot: root)
        try FileManager.default.createDirectory(
            at: paths.internalDir, withIntermediateDirectories: true)
        try #"{"selectedScheme":123}"#
            .write(to: paths.settingsJSON, atomically: true, encoding: .utf8)
        let runner = ForbiddenXcodebuildRunner()

        guard case .error(let result) = try XcodeBuildRunner.sweep(
            workFolderRoot: root, toolName: ToolNames.runXcodebuild, args: [:],
            action: "build", timeout: 1, runner: runner)
        else { return XCTFail("expected an error outcome") }

        XCTAssertTrue(result.outputJSON.contains("could not be decoded"), result.outputJSON)
        XCTAssertFalse(runner.reached)
    }

    func testSweep_configuredScheme_runsItAndReportsTheSweep() throws {
        _ = try makeProject()
        try configureScheme("MyScheme")
        let runner = RecordingXcodebuildRunner(responses: [.ok("** BUILD SUCCEEDED **")])

        guard case .swept(let sweep) = try XcodeBuildRunner.sweep(
            workFolderRoot: root, toolName: ToolNames.runXcodebuild, args: [:],
            action: "build", timeout: 7, runner: runner)
        else { return XCTFail("expected a swept outcome") }

        XCTAssertEqual(sweep.runs.map(\.scheme), ["MyScheme"])
        XCTAssertTrue(sweep.runs.first?.success == true)
        XCTAssertGreaterThanOrEqual(sweep.duration, 0)
        XCTAssertEqual(runner.calls.first?.timeout, 7, "the caller's timeout reaches the process")
    }

    /// `sweep` forwards its `fileManager` to `findProject`, which is the only reason a test
    /// can drive the "no project" arm without an empty directory.
    func testSweep_honorsTheInjectedFileManager() throws {
        _ = try makeProject()
        let runner = ForbiddenXcodebuildRunner()

        guard case .error = try XcodeBuildRunner.sweep(
            workFolderRoot: root, toolName: ToolNames.runXcodebuild, args: [:],
            action: "build", timeout: 1, runner: runner,
            fileManager: BlindFileManager())
        else { return XCTFail("a file manager that sees nothing must yield the no-project error") }
    }

    // MARK: - The missing-project error, which the two tools had let drift apart

    /// Both tools now report the SAME thing for the same condition, with the recovery hint.
    ///
    /// They had diverged: `run_xcodebuild` said "…found in project root." and carried a
    /// `list_files` hint; `run_xcodetests` said "…found" and carried none. Identical
    /// condition, identical remedy — but a model that hit it through `run_xcodetests` was
    /// told only that something was missing, with nothing to act on.
    ///
    /// RED: drop the `next:` hint from `missingProjectError` → both hint assertions fail.
    func testMissingProjectError_isIdenticalForBothToolsAndCarriesTheRecoveryHint() throws {
        let build = XcodeBuildRunner.missingProjectError(
            toolName: ToolNames.runXcodebuild, args: [:])
        let test = XcodeBuildRunner.missingProjectError(
            toolName: ToolNames.runXcodetests, args: [:])

        for (name, result) in [("build", build), ("test", test)] {
            XCTAssertTrue(result.isError, name)
            XCTAssertTrue(
                result.outputJSON.contains("found in project root"),
                "\(name): \(result.outputJSON)")
            XCTAssertTrue(
                result.outputJSON.contains(ToolNames.listFiles),
                "\(name) must name the tool that shows the model what IS there: "
                    + result.outputJSON)
            XCTAssertTrue(
                result.outputJSON.contains("Check project structure"),
                "\(name): \(result.outputJSON)")
        }
        XCTAssertEqual(
            build.outputJSON.replacingOccurrences(of: ToolNames.runXcodebuild, with: "<tool>"),
            test.outputJSON.replacingOccurrences(of: ToolNames.runXcodetests, with: "<tool>"),
            "the two envelopes must differ only in which tool is reporting")
    }

    // MARK: - detectSchemes, through the seam

    /// The `Schemes:` block parse. Reachable only by spawning `xcodebuild -list` before the
    /// seam, and dead in practice: a malformed project exits non-zero with no `Schemes:`, so
    /// the only test that reached here never got past the `if let`.
    func testDetectSchemes_parsesTheSchemesBlockAndStopsAtTheNextSection() throws {
        let ref = try makeProject()
        let runner = RecordingXcodebuildRunner(responses: [.ok("""
        Information about project "App":
            Targets:
                AppTarget
        
            Schemes:
                Alpha
                Beta
            Build Configurations:
                Debug
        """)])

        let schemes = XcodeBuildRunner.detectSchemes(
            xcodeRef: ref, workFolderRoot: root, runner: runner)

        XCTAssertEqual(schemes, ["Alpha", "Beta"],
                       "stops at `Build Configurations:` rather than swallowing Debug")
    }

    /// A blank line ends the block — which is the shape `xcodebuild` actually emits, since
    /// `Schemes:` is its LAST section (measured against this project, 2026-08-08).
    ///
    /// This is the defect the seam exposed. `detectSchemes` had its own inlined parser that
    /// claimed to stop here and could not: it split with `split(separator: "\n")`, whose
    /// `omittingEmptySubsequences` defaults to `true`, so the blank line was gone before the
    /// `isEmpty` break could see it. Everything after the list became a scheme — and a
    /// phantom scheme is handed straight to `-scheme <phantom>`, failing the build with an
    /// error about a scheme the user never configured.
    ///
    /// RED: re-inline the old parser → `trailing noise that is not a scheme` comes back as a
    /// second scheme.
    func testDetectSchemes_blankLineEndsTheBlock() throws {
        let ref = try makeProject()
        let runner = RecordingXcodebuildRunner(responses: [.ok("""
        Schemes:
            Only
        
        trailing noise that is not a scheme
        """)])

        XCTAssertEqual(
            XcodeBuildRunner.detectSchemes(xcodeRef: ref, workFolderRoot: root, runner: runner),
            ["Only"])
    }

    /// The tool path and the Settings picker must report the SAME schemes for the same
    /// output. They had two independent parsers that disagreed in both directions — one
    /// swallowed trailing text, the other truncated at an unexpected section header — so the
    /// list the user chose from could differ from the list the build actually accepted.
    ///
    /// Driven off the real measured `-list` shape rather than a hand-written one.
    func testDetectSchemes_agreesWithTheSettingsPickerParser() throws {
        let ref = try makeProject()
        let listOutput = """
        Command line invocation:
            /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -list
        
        Information about project "App":
            Targets:
                App
                AppTests
        
            Build Configurations:
                Debug
                Release
        
            If no build configuration is specified and -scheme is not passed then "Release" is used.
        
            Schemes:
                App
        
        """
        let runner = RecordingXcodebuildRunner(responses: [.ok(listOutput)])

        XCTAssertEqual(
            XcodeBuildRunner.detectSchemes(xcodeRef: ref, workFolderRoot: root, runner: runner),
            XcodeBuildHelpers.parseSchemes(fromListOutput: listOutput))
        XCTAssertEqual(
            XcodeBuildRunner.detectSchemes(xcodeRef: ref, workFolderRoot: root, runner: runner),
            ["App"])
    }

    /// THE on-disk fallback, and the reason it exists: `ProcessRunner.run` returns a
    /// non-zero exit as a value rather than throwing, so a `catch`-based fallback never
    /// ran for the common case. A malformed project makes `-list` exit non-zero with no
    /// `Schemes:` while `xcshareddata/xcschemes` sits there full of them.
    ///
    /// RED: gate the fallback on the subprocess having thrown → this returns `[]` and the
    /// user is told "no schemes could be auto-detected" with the schemes on disk.
    func testDetectSchemes_nonZeroExit_stillFallsBackToTheSchemesOnDisk() throws {
        let ref = try makeProject()
        let schemesDir = root.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemesDir, withIntermediateDirectories: true)
        for name in ["Zebra.xcscheme", "Apple.xcscheme", "notes.txt"] {
            try Data().write(to: schemesDir.appendingPathComponent(name))
        }
        let runner = RecordingXcodebuildRunner(
            responses: [.failed(66, stderr: "could not open App.xcodeproj")])

        let schemes = XcodeBuildRunner.detectSchemes(
            xcodeRef: ref, workFolderRoot: root, runner: runner)

        XCTAssertEqual(schemes, ["Apple", "Zebra"],
                       "sorted by filename, extension stripped, non-scheme files ignored")
    }

    /// A Swift package takes neither `-project` nor `-workspace`: `xcodebuild` auto-detects
    /// `Package.swift`, and passing a flag would name a file that does not exist.
    func testDetectSchemes_package_passesBareList() throws {
        let runner = RecordingXcodebuildRunner(responses: [.ok("Schemes:\n    PackageScheme")])

        let schemes = XcodeBuildRunner.detectSchemes(
            xcodeRef: XcodeProjectRef(kind: "package", path: "."),
            workFolderRoot: root, runner: runner)

        XCTAssertEqual(runner.calls.first?.arguments, ["-list"])
        XCTAssertEqual(schemes, ["PackageScheme"])
    }

    /// `detectSchemes` used to run its on-disk fallback against `FileManager.default` even
    /// when its caller had substituted one, because `resolveSchemes` dropped the argument on
    /// the way in. Same "the DI contract got dropped" defect `fetchAvailableSchemes`
    /// documents on itself.
    ///
    /// RED: stop forwarding `fileManager` from `resolveSchemes` to `detectSchemes` → the
    /// real filesystem answers, the scheme IS found, and the error assertion fails.
    func testResolveSchemes_forwardsItsFileManagerToAutoDetection() throws {
        let ref = try makeProject()
        let schemesDir = root.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemesDir, withIntermediateDirectories: true)
        try Data().write(to: schemesDir.appendingPathComponent("OnDisk.xcscheme"))
        let runner = RecordingXcodebuildRunner(responses: [.failed(66)])

        // Sanity: with the real file manager the scheme IS detected.
        guard case .schemes(let found) = XcodeBuildRunner.resolveSchemes(
            xcodeRef: ref, workFolderRoot: root, toolName: ToolNames.runXcodebuild,
            args: [:], runner: runner)
        else { return XCTFail("arrange: the on-disk scheme should have been detected") }
        XCTAssertEqual(found, ["OnDisk"])

        // With a file manager that sees nothing, the same call must fail to detect.
        guard case .error = XcodeBuildRunner.resolveSchemes(
            xcodeRef: ref, workFolderRoot: root, toolName: ToolNames.runXcodebuild,
            args: [:], runner: runner, fileManager: BlindFileManager())
        else { return XCTFail("the injected file manager was dropped on the way to detectSchemes") }
    }

    /// A settings file that exists but cannot be READ (as opposed to decoded) falls through
    /// to auto-detection rather than failing the call: an I/O error is not schema drift, and
    /// the user's scheme may still be discoverable.
    ///
    /// Induced with a DIRECTORY at the settings path — `fileExists` is true while
    /// `Data(contentsOf:)` throws, the same measured trick `SearchIndexFailureCoverageTests`
    /// uses.
    func testResolveSchemes_unreadableSettings_fallsThroughToAutoDetection() throws {
        let ref = try makeProject()
        let paths = NTMSPaths(workFolderRoot: root)
        try FileManager.default.createDirectory(
            at: paths.settingsJSON, withIntermediateDirectories: true)
        let runner = RecordingXcodebuildRunner(responses: [.ok("Schemes:\n    Detected")])

        guard case .schemes(let schemes) = XcodeBuildRunner.resolveSchemes(
            xcodeRef: ref, workFolderRoot: root, toolName: ToolNames.runXcodebuild,
            args: [:], runner: runner)
        else { return XCTFail("an unreadable settings file must not be a hard error") }

        XCTAssertEqual(schemes, ["Detected"])
    }

    // MARK: - fetchAvailableSchemes (the Settings picker's path)

    /// The detached body. Everything inside `Task.detached` was uncovered: the only thing
    /// standing between a test and it was whether the temp directory happened to contain a
    /// project, and the existing tests all used one that did not — so they returned `[]` from
    /// the `listArguments` guard and never entered.
    func testFetchAvailableSchemes_parsesTheDetectedSchemes() async throws {
        _ = try makeProject()
        let runner = RecordingXcodebuildRunner(
            responses: [.ok("Schemes:\n    Alpha\n    Beta\n")])

        let schemes = await XcodeBuildHelpers.fetchAvailableSchemes(
            workFolderRoot: root, runner: runner)

        XCTAssertEqual(schemes, ["Alpha", "Beta"])
        XCTAssertEqual(runner.calls.first?.arguments, ["-list", "-project", "App.xcodeproj"])
        XCTAssertEqual(runner.calls.first?.timeout, 60)
    }

    /// A workspace wins over a project here too — a workspace that references the project
    /// would otherwise report a SUBSET of the schemes the user actually builds.
    func testFetchAvailableSchemes_prefersTheWorkspace() async throws {
        _ = try makeProject()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App.xcworkspace"), withIntermediateDirectories: true)
        let runner = RecordingXcodebuildRunner(responses: [.ok("Schemes:\n    WS\n")])

        _ = await XcodeBuildHelpers.fetchAvailableSchemes(workFolderRoot: root, runner: runner)

        XCTAssertEqual(runner.calls.first?.arguments, ["-list", "-workspace", "App.xcworkspace"])
    }

    /// A thrown invocation yields no schemes rather than propagating: the picker's job is to
    /// offer what it can find, and a failure to probe is "nothing found", not an error the
    /// Settings pane should surface.
    func testFetchAvailableSchemes_thrownInvocation_yieldsNoSchemes() async throws {
        _ = try makeProject()
        let runner = RecordingXcodebuildRunner(
            thrown: ProcessRunnerError.executableNotFound("/usr/bin/xcodebuild"))

        let schemes = await XcodeBuildHelpers.fetchAvailableSchemes(
            workFolderRoot: root, runner: runner)

        XCTAssertTrue(schemes.isEmpty)
    }

    /// No project, no probe. The `listArguments` guard runs on the CALLING thread with the
    /// injected file manager, before the detached hop.
    func testFetchAvailableSchemes_noProject_neverProbes() async {
        let runner = ForbiddenXcodebuildRunner()

        let schemes = await XcodeBuildHelpers.fetchAvailableSchemes(
            workFolderRoot: root, runner: runner)

        XCTAssertTrue(schemes.isEmpty)
        XCTAssertFalse(runner.reached)
    }

    /// Only the FIRST detected scheme is used, even when several are available — building
    /// all of them on an unconfigured project would be a surprise, and the error path exists
    /// to get the user to choose.
    func testResolveSchemes_severalDetected_usesOnlyTheFirst() throws {
        let ref = try makeProject()
        let runner = RecordingXcodebuildRunner(
            responses: [.ok("Schemes:\n    First\n    Second\n    Third")])

        guard case .schemes(let schemes) = XcodeBuildRunner.resolveSchemes(
            xcodeRef: ref, workFolderRoot: root, toolName: ToolNames.runXcodebuild,
            args: [:], runner: runner)
        else { return XCTFail("expected schemes") }

        XCTAssertEqual(schemes, ["First"])
    }
}

/// A `FileManager` that reports every directory as empty. Used to prove an injected file
/// manager actually reaches the code under test — the real one would answer correctly and
/// hide the drop.
final class BlindFileManager: FileManager {
    override func contentsOfDirectory(atPath path: String) throws -> [String] { [] }
}
