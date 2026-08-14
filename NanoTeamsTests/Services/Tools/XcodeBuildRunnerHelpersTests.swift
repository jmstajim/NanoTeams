import XCTest

@testable import NanoTeams

// MARK: - File-scope helpers (private: siblings compile into the same module)

/// `XcodeBuildRunner.SchemeResolution` carries associated values and is not `Equatable`,
/// so every assertion has to pattern-match. These two accessors keep the tests readable
/// and keep the `case` spelling in one place.
private func resolvedSchemes(_ r: XcodeBuildRunner.SchemeResolution) -> [String]? {
    if case .schemes(let s) = r { return s }
    return nil
}

private func resolvedError(_ r: XcodeBuildRunner.SchemeResolution) -> ToolExecutionResult? {
    if case .error(let e) = r { return e }
    return nil
}

/// Covers the static helper surface of `XcodeBuildRunner` — the argv builders, the log
/// truncator, project discovery, scheme resolution, and the issue parser.
///
/// Nothing here spawns a subprocess. `buildBaseArgs` / `injectScheme` / `truncateLog` /
/// `parseIssues` are pure; `findProject` and the configured-scheme path of `resolveSchemes`
/// need only a real temp directory tree; and the auto-detection paths — which used to run
/// `/usr/bin/xcodebuild -list` for real behind a `skipUnlessXcodebuildIsInstalled` gate —
/// now go through the `XcodebuildRunning` seam.
///
/// The settings-driven paths get `ForbiddenXcodebuildRunner`, which fails on being reached.
/// Their short-circuit before auto-detection used to be asserted by a section comment
/// saying "(no subprocess)"; now the claim is enforced, and one of those tests
/// (`…neverConsultsTheProjectOnDisk`) had been leaning on a nonexistent project path to
/// make the point indirectly.
final class XcodeBuildRunnerHelpersTests: XCTestCase {

    private var tempDir: URL!

    /// For every path that must NOT reach `xcodebuild`. One instance per test, so
    /// `reached` is attributable.
    private var forbidden: ForbiddenXcodebuildRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt_xcrunner_\(UUID().uuidString.prefix(8))", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        forbidden = ForbiddenXcodebuildRunner()
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        forbidden = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture helpers

    /// A fresh sub-root per test case, so `findProject`'s `first(where:)` never sees leftovers
    /// from a sibling assertion (directory enumeration order is undefined, so two candidates of
    /// the same kind would make the winner nondeterministic).
    private func makeRoot(_ name: String) throws -> URL {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDirectory(_ name: String, in root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true)
    }

    private func makeFile(_ name: String, in root: URL, contents: String = "") throws {
        try contents.write(
            to: root.appendingPathComponent(name, isDirectory: false),
            atomically: true, encoding: .utf8)
    }

    /// Writes `.nanoteams/internal/settings.json` verbatim. `ProjectSettings.init(from:)` is fully
    /// tolerant (`decodeIfPresent` on every key), so a one-key document decodes — which lets these
    /// tests state the exact bytes on disk instead of coupling to an encoder.
    private func writeSettingsJSON(_ raw: String, in root: URL) throws {
        let paths = NTMSPaths(workFolderRoot: root)
        try FileManager.default.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        try raw.write(to: paths.settingsJSON, atomically: true, encoding: .utf8)
    }

    // MARK: - buildBaseArgs (pure)

    /// The three kinds `findProject` can produce, each with the flag pair the handler relies on.
    /// `package` deliberately emits NO `-project`/`-workspace` flag: xcodebuild auto-detects
    /// `Package.swift` from the working directory, and passing a flag would break SPM roots.
    func testBuildBaseArgs_perProjectKind_emitsTheRightSelectorFlag() {
        let cases: [(kind: String, path: String, expected: [String])] = [
            ("workspace", "App.xcworkspace", ["-workspace", "App.xcworkspace",
                                              "-destination", "platform=macOS", "build"]),
            ("project", "App.xcodeproj", ["-project", "App.xcodeproj",
                                          "-destination", "platform=macOS", "build"]),
            ("package", ".", ["-destination", "platform=macOS", "build"]),
        ]

        for c in cases {
            let args = XcodeBuildRunner.buildBaseArgs(
                xcodeRef: XcodeProjectRef(kind: c.kind, path: c.path),
                destination: "platform=macOS",
                action: "build")
            XCTAssertEqual(args, c.expected, "kind=\(c.kind)")
        }
    }

    /// `findProject` is the only producer of `kind`, and it emits exactly three lowercase
    /// literals — so anything else is a programmer error arriving from hand-built refs. The
    /// comparison is a plain `==`, i.e. case-sensitive: an unrecognised kind degrades to the
    /// package shape (no selector flag) rather than trapping.
    func testBuildBaseArgs_unrecognisedKind_degradesToTheNoSelectorShape() {
        for kind in ["", "Workspace", "PROJECT", "spm", "swiftpm"] {
            let args = XcodeBuildRunner.buildBaseArgs(
                xcodeRef: XcodeProjectRef(kind: kind, path: "App.xcodeproj"),
                destination: "platform=macOS",
                action: "build")
            XCTAssertEqual(args, ["-destination", "platform=macOS", "build"], "kind=\(kind)")
        }
    }

    /// The action is the trailing token for every kind and every action the handlers use
    /// (`build` for run_xcodebuild, `test` for run_xcodetests). `injectScheme` depends on this:
    /// it looks the action up positionally to decide where the `-scheme` pair goes.
    func testBuildBaseArgs_actionIsAlwaysTheLastToken() {
        for kind in ["workspace", "project", "package"] {
            for action in ["build", "test"] {
                let args = XcodeBuildRunner.buildBaseArgs(
                    xcodeRef: XcodeProjectRef(kind: kind, path: "App.xcodeproj"),
                    destination: "platform=macOS",
                    action: action)
                XCTAssertEqual(args.last, action, "kind=\(kind) action=\(action)")
                XCTAssertEqual(args.dropLast().suffix(2).first, "-destination")
            }
        }
    }

    /// Degenerate inputs: the builder is purely positional and does no validation, so empty
    /// strings still occupy their slots rather than collapsing the argv (which would silently
    /// shift `-destination`'s value onto the next flag).
    func testBuildBaseArgs_emptyDestinationAndAction_stillOccupyTheirSlots() {
        let args = XcodeBuildRunner.buildBaseArgs(
            xcodeRef: XcodeProjectRef(kind: "project", path: "App.xcodeproj"),
            destination: "",
            action: "")
        XCTAssertEqual(args, ["-project", "App.xcodeproj", "-destination", "", ""])
    }

    // MARK: - injectScheme (pure)

    func testInjectScheme_insertsTheSchemePairImmediatelyBeforeTheAction() {
        var args = ["-project", "App.xcodeproj", "-destination", "platform=macOS", "build"]
        XcodeBuildRunner.injectScheme("App", into: &args, action: "build")

        XCTAssertEqual(args, ["-project", "App.xcodeproj", "-destination", "platform=macOS",
                              "-scheme", "App", "build"])
    }

    /// The `else` arm. If the action token is missing the pair is appended, which keeps the argv
    /// well-formed (flag followed by value) even though xcodebuild would then have no action.
    func testInjectScheme_actionAbsent_appendsInsteadOfDropping() {
        var args = ["-project", "App.xcodeproj", "-destination", "platform=macOS"]
        XcodeBuildRunner.injectScheme("App", into: &args, action: "build")

        XCTAssertEqual(args, ["-project", "App.xcodeproj", "-destination", "platform=macOS",
                              "-scheme", "App"])
    }

    func testInjectScheme_emptyArgs_yieldsJustTheSchemePair() {
        var args: [String] = []
        XcodeBuildRunner.injectScheme("App", into: &args, action: "build")

        XCTAssertEqual(args, ["-scheme", "App"])
    }

    func testInjectScheme_actionAtIndexZero_insertsAtTheFront() {
        var args = ["build"]
        XcodeBuildRunner.injectScheme("App", into: &args, action: "build")

        XCTAssertEqual(args, ["-scheme", "App", "build"])
    }

    /// Positional contract behind the choice of `lastIndex` over `firstIndex`: when the action
    /// token also appears earlier as some flag's VALUE, the real action is the trailing one, and
    /// inserting before the first occurrence would emit `-destination -scheme App build build` —
    /// the scheme name would be consumed as the destination.
    func testInjectScheme_actionTokenAppearsTwice_targetsTheTrailingOccurrence() {
        var args = ["-destination", "build", "build"]
        XcodeBuildRunner.injectScheme("App", into: &args, action: "build")

        XCTAssertEqual(args, ["-destination", "build", "-scheme", "App", "build"])
        XCTAssertEqual(args.last, "build", "the action must remain the trailing token")
    }

    /// Called repeatedly against the same array the action stays last, so the insertion point is
    /// stable rather than drifting past it.
    func testInjectScheme_appliedTwice_keepsTheActionTrailing() {
        var args = ["-project", "App.xcodeproj", "-destination", "platform=macOS", "build"]
        XcodeBuildRunner.injectScheme("Alpha", into: &args, action: "build")
        XcodeBuildRunner.injectScheme("Beta", into: &args, action: "build")

        XCTAssertEqual(args, ["-project", "App.xcodeproj", "-destination", "platform=macOS",
                              "-scheme", "Alpha", "-scheme", "Beta", "build"])
    }

    // MARK: - findProject + argv builders, composed the way the handlers compose them

    /// The whole pre-subprocess pipeline of `RunXcodebuildTool.handle` against a real directory:
    /// discover the project, build the base argv, inject the scheme. Pins the exact argv that
    /// would reach `ProcessRunner.runXcodebuild`, including the fact that `findProject` yields a
    /// BARE directory entry name — the handler runs xcodebuild with `cwd == workFolderRoot`, so an
    /// absolute path here would still work but a path relative to anything else would not.
    func testHandlerPipeline_discoverThenBuildArgsThenInjectScheme_producesTheExpectedArgv() throws {
        let root = try makeRoot("pipeline")
        try makeDirectory("App.xcworkspace", in: root)

        let ref = try XCTUnwrap(XcodeBuildRunner.findProject(in: root))
        XCTAssertEqual(ref.kind, "workspace")
        XCTAssertEqual(ref.path, "App.xcworkspace", "a bare entry name, not an absolute path")

        var args = XcodeBuildRunner.buildBaseArgs(
            xcodeRef: ref, destination: "platform=macOS", action: "build")
        XcodeBuildRunner.injectScheme("App", into: &args, action: "build")

        XCTAssertEqual(args, ["-workspace", "App.xcworkspace", "-destination", "platform=macOS",
                              "-scheme", "App", "build"])
    }

    /// Same pipeline for the test tool, whose action is `test`.
    func testHandlerPipeline_testAction_injectsBeforeTest() throws {
        let root = try makeRoot("pipelineTests")
        try makeDirectory("App.xcodeproj", in: root)

        let ref = try XCTUnwrap(XcodeBuildRunner.findProject(in: root))
        var args = XcodeBuildRunner.buildBaseArgs(
            xcodeRef: ref, destination: "platform=macOS", action: "test")
        XcodeBuildRunner.injectScheme("AppTests", into: &args, action: "test")

        XCTAssertEqual(args, ["-project", "App.xcodeproj", "-destination", "platform=macOS",
                              "-scheme", "AppTests", "test"])
    }

    // MARK: - findProject

    func testFindProject_workspaceWinsOverProjectAndPackage() throws {
        let root = try makeRoot("prefWorkspace")
        try makeDirectory("App.xcworkspace", in: root)
        try makeDirectory("App.xcodeproj", in: root)
        try makeFile("Package.swift", in: root)

        let ref = try XCTUnwrap(XcodeBuildRunner.findProject(in: root))
        XCTAssertEqual(ref.kind, "workspace")
        XCTAssertEqual(ref.path, "App.xcworkspace")
    }

    func testFindProject_projectWinsOverPackage() throws {
        let root = try makeRoot("prefProject")
        try makeDirectory("App.xcodeproj", in: root)
        try makeFile("Package.swift", in: root)

        let ref = try XCTUnwrap(XcodeBuildRunner.findProject(in: root))
        XCTAssertEqual(ref.kind, "project")
        XCTAssertEqual(ref.path, "App.xcodeproj")
    }

    /// The SPM arm: `path` is "." because there is no file to name — `buildBaseArgs` then emits no
    /// selector flag at all and xcodebuild picks the manifest up from the working directory.
    func testFindProject_packageSwiftOnly_yieldsPackageKindWithDotPath() throws {
        let root = try makeRoot("packageOnly")
        try makeFile("Package.swift", in: root, contents: "// manifest")

        let ref = try XCTUnwrap(XcodeBuildRunner.findProject(in: root))
        XCTAssertEqual(ref.kind, "package")
        XCTAssertEqual(ref.path, ".")
        XCTAssertEqual(
            XcodeBuildRunner.buildBaseArgs(xcodeRef: ref, destination: "platform=macOS", action: "build"),
            ["-destination", "platform=macOS", "build"])
    }

    func testFindProject_emptyDirectory_returnsNil() throws {
        let root = try makeRoot("empty")
        XCTAssertNil(XcodeBuildRunner.findProject(in: root))
    }

    /// The `guard let contents = try?` arm — an unreadable/absent directory must be nil, not a
    /// crash and not a bogus ref.
    func testFindProject_nonexistentDirectory_returnsNil() {
        let missing = tempDir.appendingPathComponent("does_not_exist", isDirectory: true)
        XCTAssertNil(XcodeBuildRunner.findProject(in: missing))
    }

    /// Discovery is a strict suffix test. Backup copies and lookalike names must not be handed to
    /// xcodebuild as `-project`, which would fail with a confusing "cannot be opened" message
    /// several seconds into the run instead of a clean FILE_NOT_FOUND up front.
    func testFindProject_lookalikeNames_areNotMistakenForProjects() throws {
        let root = try makeRoot("lookalikes")
        try makeDirectory("App.xcodeproj.bak", in: root)
        try makeDirectory("App.xcworkspace.old", in: root)
        try makeFile("Package.swift.bak", in: root)
        try makeFile("MyPackage.swift", in: root)
        try makeFile("notes.txt", in: root)

        XCTAssertNil(XcodeBuildRunner.findProject(in: root))
    }

    /// The `fileManager` seam is honoured (an explicitly supplied manager reaches the enumeration
    /// rather than the call silently using `.default`).
    func testFindProject_usesTheInjectedFileManager() throws {
        let root = try makeRoot("injected")
        try makeDirectory("App.xcodeproj", in: root)

        let ref = XcodeBuildRunner.findProject(in: root, fileManager: FileManager())
        XCTAssertEqual(ref?.kind, "project")
        XCTAssertEqual(ref?.path, "App.xcodeproj")
    }

    // MARK: - truncateLog (pure)

    func testTruncateLog_underTheCap_returnsTheInputVerbatim() {
        let (log, truncated) = XcodeBuildRunner.truncateLog("l1\nl2\nl3", maxLines: 5)

        XCTAssertEqual(log, "l1\nl2\nl3")
        XCTAssertFalse(truncated)
    }

    /// The boundary: the comparison is `>` not `>=`, so a log of exactly `maxLines` lines is
    /// returned whole and NOT flagged. An off-by-one here would report `truncated: true` on
    /// complete logs and make the meta flag meaningless.
    func testTruncateLog_exactlyAtTheCap_isNotTruncated() {
        let (log, truncated) = XcodeBuildRunner.truncateLog("l1\nl2\nl3", maxLines: 3)

        XCTAssertEqual(log, "l1\nl2\nl3")
        XCTAssertFalse(truncated)
    }

    /// One over the cap. The TAIL is kept — build failures land at the end of xcodebuild output,
    /// so dropping the head is the whole point of the helper.
    func testTruncateLog_oneOverTheCap_keepsTheTailAndDropsTheHead() {
        let (log, truncated) = XcodeBuildRunner.truncateLog("l1\nl2\nl3", maxLines: 2)

        XCTAssertEqual(log, "l2\nl3")
        XCTAssertTrue(truncated)
    }

    func testTruncateLog_wellOverTheCap_keepsExactlyMaxLines() {
        let source = (1...50).map { "line\($0)" }.joined(separator: "\n")

        let (log, truncated) = XcodeBuildRunner.truncateLog(source, maxLines: 30)

        XCTAssertTrue(truncated)
        XCTAssertEqual(log.components(separatedBy: "\n").count, 30)
        XCTAssertEqual(log.components(separatedBy: "\n").first, "line21")
        XCTAssertEqual(log.components(separatedBy: "\n").last, "line50")
    }

    /// Property form of the same contract across a range of caps: a truncated result always has
    /// exactly `maxLines` lines and is always the suffix of the input.
    func testTruncateLog_whenTruncated_resultIsAlwaysTheExactSuffix() {
        let lines = (1...10).map { "l\($0)" }
        let source = lines.joined(separator: "\n")

        for cap in 1...9 {
            let (log, truncated) = XcodeBuildRunner.truncateLog(source, maxLines: cap)
            XCTAssertTrue(truncated, "cap=\(cap)")
            XCTAssertEqual(log, lines.suffix(cap).joined(separator: "\n"), "cap=\(cap)")
            XCTAssertEqual(log.components(separatedBy: "\n").count, cap, "cap=\(cap)")
        }
    }

    func testTruncateLog_noNewlines_isASingleLine() {
        let under = XcodeBuildRunner.truncateLog("one long line with no breaks", maxLines: 1)
        XCTAssertEqual(under.log, "one long line with no breaks")
        XCTAssertFalse(under.truncated)
    }

    func testTruncateLog_emptyLog_isOneEmptyLineAndIsNotTruncated() {
        let (log, truncated) = XcodeBuildRunner.truncateLog("", maxLines: 1)

        XCTAssertEqual(log, "")
        XCTAssertFalse(truncated)
    }

    /// `maxLines: 0` is not reachable from the handlers (both hardcode 30) but is the lower
    /// boundary of the arithmetic: everything is dropped and the flag is set, so the caller can
    /// still tell the log was withheld rather than genuinely empty.
    func testTruncateLog_capOfZero_dropsEverythingAndFlagsIt() {
        let (log, truncated) = XcodeBuildRunner.truncateLog("l1\nl2", maxLines: 0)

        XCTAssertEqual(log, "")
        XCTAssertTrue(truncated)
    }

    /// A trailing newline produces a trailing EMPTY line, which counts against the cap — so a
    /// 2-line log that ends in a newline is three lines to the truncator.
    func testTruncateLog_trailingNewline_countsTheEmptyFinalLine() {
        let (log, truncated) = XcodeBuildRunner.truncateLog("l1\nl2\n", maxLines: 2)

        XCTAssertTrue(truncated, "\"l1\\nl2\\n\" splits into three subsequences, not two")
        XCTAssertEqual(log, "l2\n")
    }

    /// Splitting is on `\n` only, so a CRLF log still counts one line per `\n` and the stray `\r`
    /// rides along inside its line.
    /// In Swift `"\r\n"` is ONE grapheme cluster, so splitting on the `Character`
    /// `"\n"` finds no separator in a CRLF log and the cap silently stops
    /// applying. Splitting on the scalar is what makes this line count as 3.
    func testTruncateLog_carriageReturnsAreNotLineSeparators() {
        let (log, truncated) = XcodeBuildRunner.truncateLog("l1\r\nl2\r\nl3", maxLines: 2)

        XCTAssertTrue(truncated)
        XCTAssertEqual(log, "l2\r\nl3")
    }

    /// `suffix(_:)` traps on a negative count, which in a shared helper means
    /// killing the whole test runner rather than failing one assertion. The
    /// clamp makes a negative cap behave as zero.
    func testTruncateLog_negativeMaxLines_clampsInsteadOfTrapping() {
        let (log, truncated) = XcodeBuildRunner.truncateLog("a\nb\nc", maxLines: -1)

        XCTAssertTrue(truncated)
        XCTAssertEqual(log, "", "a negative cap is treated as zero, not as a crash")
    }

    /// LF-only input must be byte-identical to the pre-fix implementation —
    /// the scalar split changes CRLF handling and nothing else.
    func testTruncateLog_lfOnlyInput_isUnchangedByTheScalarSplit() {
        for cap in 0...4 {
            let (log, truncated) = XcodeBuildRunner.truncateLog("a\nb\nc", maxLines: cap)
            let expected = ["a", "b", "c"].suffix(cap).joined(separator: "\n")
            XCTAssertEqual(truncated, 3 > cap)
            XCTAssertEqual(log, truncated ? expected : "a\nb\nc", "cap \(cap)")
        }
    }

    // MARK: - resolveSchemes: settings.json is the source of truth (no subprocess)

    /// The happy path. A configured scheme short-circuits before auto-detection ever runs.
    func testResolveSchemes_configuredScheme_isReturnedAsTheOnlyScheme() throws {
        let root = try makeRoot("configured")
        try writeSettingsJSON(#"{"selectedScheme":"MyScheme"}"#, in: root)

        let resolution = XcodeBuildRunner.resolveSchemes(
            xcodeRef: XcodeProjectRef(kind: "project", path: "App.xcodeproj"),
            workFolderRoot: root,
            toolName: ToolNames.runXcodebuild,
            args: [:],
            runner: forbidden)

        XCTAssertEqual(resolvedSchemes(resolution), ["MyScheme"])
        XCTAssertNil(resolvedError(resolution))
    }

    /// Behavioural proof of the short-circuit: the ref names a project that does not exist on
    /// disk, so any attempt to consult it would have to fail. The configured scheme still comes
    /// back cleanly, which is only possible if the settings branch returns before auto-detection.
    func testResolveSchemes_configuredScheme_neverConsultsTheProjectOnDisk() throws {
        let root = try makeRoot("configuredNoProject")
        try writeSettingsJSON(#"{"schemaVersion":3,"selectedScheme":"Ghost"}"#, in: root)

        let resolution = XcodeBuildRunner.resolveSchemes(
            xcodeRef: XcodeProjectRef(kind: "project", path: "NoSuchProject.xcodeproj"),
            workFolderRoot: root,
            toolName: ToolNames.runXcodetests,
            args: [:],
            runner: forbidden)

        XCTAssertEqual(resolvedSchemes(resolution), ["Ghost"])
    }

    /// THE HARD-ERROR CONTRACT. A settings file that exists but cannot be decoded must fail the
    /// tool call rather than silently auto-detecting: the user's configured scheme is the source
    /// of truth when the file exists, so falling back would build the wrong target and surface as
    /// confusing compile errors instead of a fixable settings problem.
    func testResolveSchemes_undecodableSettings_isAHardErrorNotSilentAutoDetection() throws {
        let root = try makeRoot("badTypeSettings")
        // A type mismatch on a present key: `decodeIfPresent(String.self)` throws. Chosen over a
        // syntax error because it fails identically regardless of how lenient the JSON parser is.
        try writeSettingsJSON(#"{"selectedScheme":123}"#, in: root)

        let resolution = XcodeBuildRunner.resolveSchemes(
            xcodeRef: XcodeProjectRef(kind: "project", path: "App.xcodeproj"),
            workFolderRoot: root,
            toolName: ToolNames.runXcodebuild,
            args: [:],
            runner: forbidden)

        XCTAssertNil(resolvedSchemes(resolution), "must not fall through to a detected scheme")
        let error = try XCTUnwrap(resolvedError(resolution))
        XCTAssertTrue(error.isError)
        XCTAssertTrue(error.outputJSON.contains("INVALID_ARGS"), error.outputJSON)
        XCTAssertTrue(
            error.outputJSON.contains("Project settings file exists but could not be decoded"),
            error.outputJSON)
        XCTAssertTrue(
            error.outputJSON.contains("re-select the Xcode scheme"),
            "the message must name the user-facing remedy")
    }

    func testResolveSchemes_malformedJSONSettings_isAlsoAHardError() throws {
        let root = try makeRoot("malformedSettings")
        try writeSettingsJSON("{ this is not json", in: root)

        let resolution = XcodeBuildRunner.resolveSchemes(
            xcodeRef: XcodeProjectRef(kind: "project", path: "App.xcodeproj"),
            workFolderRoot: root,
            toolName: ToolNames.runXcodebuild,
            args: [:],
            runner: forbidden)

        let error = try XCTUnwrap(resolvedError(resolution))
        XCTAssertTrue(error.isError)
        XCTAssertTrue(error.outputJSON.contains("could not be decoded"), error.outputJSON)
    }

    /// A top-level JSON array cannot open a keyed container, so it throws before any key is read.
    func testResolveSchemes_settingsIsAJSONArray_isAHardError() throws {
        let root = try makeRoot("arraySettings")
        try writeSettingsJSON("[]", in: root)

        let error = try XCTUnwrap(resolvedError(XcodeBuildRunner.resolveSchemes(
            xcodeRef: XcodeProjectRef(kind: "project", path: "App.xcodeproj"),
            workFolderRoot: root,
            toolName: ToolNames.runXcodebuild,
            args: [:],
            runner: forbidden)))

        XCTAssertTrue(error.outputJSON.contains("could not be decoded"), error.outputJSON)
    }

    /// The error result is a normal tool envelope: it carries the calling tool's name and echoes
    /// the arguments, so the model sees the failure attributed to the call it actually made.
    func testResolveSchemes_errorResult_carriesTheToolNameAndEchoesArgs() throws {
        let root = try makeRoot("errorEnvelope")
        try writeSettingsJSON(#"{"selectedScheme":true}"#, in: root)

        let error = try XCTUnwrap(resolvedError(XcodeBuildRunner.resolveSchemes(
            xcodeRef: XcodeProjectRef(kind: "project", path: "App.xcodeproj"),
            workFolderRoot: root,
            toolName: ToolNames.runXcodetests,
            args: ["scheme_hint": "Alpha"],
            runner: forbidden)))

        XCTAssertEqual(error.toolName, ToolNames.runXcodetests)
        XCTAssertTrue(error.argumentsJSON.contains("scheme_hint"), error.argumentsJSON)
        XCTAssertTrue(error.argumentsJSON.contains("Alpha"), error.argumentsJSON)
    }

    // MARK: - parseIssues (pure)

    /// Every capture group lands on the right field, and `severity` is the bare lowercase token —
    /// `RunXcodebuildTool.handle` counts errors/warnings with `filter { $0.severity == "error" }`,
    /// so any normalisation here would silently zero those counters.
    func testParseIssues_populatesEveryFieldAndKeepsSeverityLowercase() {
        let root = URL(fileURLWithPath: "/Users/x/Proj", isDirectory: true)
        let output = """
            /Users/x/Proj/Sources/App/main.swift:12:34: error: cannot find 'foo' in scope
            /Users/x/Proj/Sources/App/Util.swift:9:5: warning: initialization of immutable value 'x' was never used
            /Users/x/Proj/Sources/App/Util.swift:9:5: note: did you mean 'y'?
            """

        let issues = XcodeBuildRunner.parseIssues(from: output, workFolderRoot: root)

        XCTAssertEqual(issues.count, 3)
        XCTAssertEqual(issues.map(\.severity), ["error", "warning", "note"])
        XCTAssertEqual(issues[0].file, "Sources/App/main.swift")
        XCTAssertEqual(issues[0].line, 12)
        XCTAssertEqual(issues[0].column, 34)
        XCTAssertEqual(issues[0].message, "cannot find 'foo' in scope")
        XCTAssertNil(issues[0].raw, "raw is reserved and never populated by this parser")
        XCTAssertEqual(issues[2].message, "did you mean 'y'?")

        XCTAssertEqual(issues.filter { $0.severity == "error" }.count, 1)
        XCTAssertEqual(issues.filter { $0.severity == "warning" }.count, 1)
    }

    /// The file group is lazy (`(.+?)`), so a path that itself contains a colon must backtrack past
    /// the false split rather than reporting a truncated file with a garbage line number — the
    /// first `:` in `a:b.swift` is not followed by digits, so the group has to keep growing.
    /// Deliberately a RELATIVE path so `relativizeIssuePath` short-circuits and this stays a pure
    /// test of the regex.
    func testParseIssues_pathContainingAColon_backtracksToTheRealLineAndColumn() {
        let root = URL(fileURLWithPath: "/Users/x/Proj", isDirectory: true)
        let output = "Sources/a:b.swift:7:3: error: boom"

        let issues = XcodeBuildRunner.parseIssues(from: output, workFolderRoot: root)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.file, "Sources/a:b.swift")
        XCTAssertEqual(issues.first?.line, 7)
        XCTAssertEqual(issues.first?.column, 3)
    }

    /// An already-relative path reported by a tool that ran with the work folder as cwd is left
    /// alone — `relativizeIssuePath` only rewrites absolute paths, so it can never double-strip.
    func testParseIssues_alreadyRelativePath_isLeftAlone() {
        let root = URL(fileURLWithPath: "/Users/x/Proj", isDirectory: true)
        let output = "Sources/App/main.swift:4:1: warning: unused"

        let issues = XcodeBuildRunner.parseIssues(from: output, workFolderRoot: root)

        XCTAssertEqual(issues.map(\.file), ["Sources/App/main.swift"])
    }

    /// Lines that carry no `file:line:column:severity:` prefix are not issues. Linker diagnostics
    /// and ordinary build chatter must contribute nothing, or the error counters inflate and the
    /// model chases phantom locations.
    func testParseIssues_nonIssueOutput_yieldsNothing() {
        let root = URL(fileURLWithPath: "/Users/x/Proj", isDirectory: true)
        let output = """
            note: Using new build system
            Build system information
            ld: error: duplicate symbol _main in:
            /Users/x/Proj/build/obj1.o
            /Users/x/Proj/build/obj2.o
            xcodebuild: error: The project 'Sample' cannot be opened because it is missing.
            ** BUILD FAILED **
            """

        XCTAssertTrue(XcodeBuildRunner.parseIssues(from: output, workFolderRoot: root).isEmpty)
    }

    func testParseIssues_emptyOutput_yieldsNothing() {
        let root = URL(fileURLWithPath: "/Users/x/Proj", isDirectory: true)
        XCTAssertTrue(XcodeBuildRunner.parseIssues(from: "", workFolderRoot: root).isEmpty)
    }

    /// `remark:` is not in the severity alternation, so it is ignored even though it carries a
    /// well-formed location prefix — and its presence must not knock the following real issue out.
    func testParseIssues_unlistedSeverities_areIgnored() {
        let root = URL(fileURLWithPath: "/Users/x/Proj", isDirectory: true)
        let output = """
            /Users/x/Proj/A.swift:1:1: remark: inlined
            /Users/x/Proj/A.swift:2:1: error: real one
            """

        let issues = XcodeBuildRunner.parseIssues(from: output, workFolderRoot: root)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.line, 2)
    }

    /// `.anchorsMatchLines` scopes each match to its own line, so a multi-line blob yields one
    /// issue per matching line and a message never swallows the following line.
    func testParseIssues_messageStopsAtTheEndOfItsLine() {
        let root = URL(fileURLWithPath: "/Users/x/Proj", isDirectory: true)
        let output = """
            /Users/x/Proj/A.swift:1:1: error: first problem
            some continuation text that is not an issue line
            /Users/x/Proj/B.swift:2:2: error: second problem
            """

        let issues = XcodeBuildRunner.parseIssues(from: output, workFolderRoot: root)

        XCTAssertEqual(issues.map(\.message), ["first problem", "second problem"])
    }

    // MARK: - Auto-detection (through the seam; no subprocess)

    /// The no-scheme error path end to end, with a runner that reports what a real
    /// `xcodebuild -list` reports for an unopenable project: a non-zero exit and no
    /// `Schemes:` block. Both tool names are exercised so the guidance ternary is pinned in
    /// both directions.
    ///
    /// RED: drop the `Detected Xcode project:` line from the message → the third assertion
    /// fails and the user is told to "select a scheme" without being told where.
    func testResolveSchemes_noSettingsAndUndetectableSchemes_errorsWithActionableGuidance() throws {
        let root = try makeRoot("autodetect")
        try makeDirectory("App.xcodeproj", in: root)
        let ref = XcodeProjectRef(kind: "project", path: "App.xcodeproj")
        let runner = RecordingXcodebuildRunner(
            responses: [.failed(66, stderr: "xcodebuild: error: could not open App.xcodeproj")])

        // No settings.json at all — the expected first-run state, and the branch that must stay
        // silent (it is only a PRESENT-but-broken file that raises the schema-drift error).
        let paths = NTMSPaths(workFolderRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.settingsJSON.path))

        let buildError = try XCTUnwrap(resolvedError(XcodeBuildRunner.resolveSchemes(
            xcodeRef: ref, workFolderRoot: root,
            toolName: ToolNames.runXcodebuild, args: [:], runner: runner)))

        XCTAssertTrue(buildError.isError)
        XCTAssertFalse(
            buildError.outputJSON.contains("could not be decoded"),
            "an ABSENT settings file is not schema drift")
        XCTAssertTrue(buildError.outputJSON.contains("INVALID_ARGS"), buildError.outputJSON)
        XCTAssertTrue(
            buildError.outputJSON.contains("No scheme configured in project settings."),
            buildError.outputJSON)
        XCTAssertTrue(
            buildError.outputJSON.contains("Detected Xcode project: App.xcodeproj"),
            "the message must name the project it found, so the user knows where to configure")
        XCTAssertTrue(
            buildError.outputJSON.contains("No schemes could be auto-detected."),
            buildError.outputJSON)
        XCTAssertTrue(
            buildError.outputJSON.contains("before building"),
            "run_xcodebuild phrasing")
        XCTAssertEqual(runner.calls.first?.arguments, ["-project", "App.xcodeproj", "-list"],
                       "the -project branch of the -list argv selection")

        let testError = try XCTUnwrap(resolvedError(XcodeBuildRunner.resolveSchemes(
            xcodeRef: ref, workFolderRoot: root,
            toolName: ToolNames.runXcodetests, args: [:], runner: runner)))

        XCTAssertTrue(
            testError.outputJSON.contains("before running tests"),
            "run_xcodetests phrasing")
    }

    /// `detectSchemes` never propagates a failure: an unopenable workspace yields an empty list so
    /// the caller can emit its own actionable message. Also exercises the `-workspace` branch of
    /// the `-list` argument selection.
    func testDetectSchemes_unopenableWorkspace_returnsEmptyRatherThanFailing() throws {
        let root = try makeRoot("detectWorkspace")
        try makeDirectory("App.xcworkspace", in: root)
        let runner = RecordingXcodebuildRunner(responses: [.failed(66)])

        let schemes = XcodeBuildRunner.detectSchemes(
            xcodeRef: XcodeProjectRef(kind: "workspace", path: "App.xcworkspace"),
            workFolderRoot: root, runner: runner)

        XCTAssertTrue(schemes.isEmpty, "got \(schemes)")
        XCTAssertEqual(runner.calls.first?.arguments,
                       ["-workspace", "App.xcworkspace", "-list"])
    }
}
