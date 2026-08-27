import XCTest

@testable import NanoTeams

/// `requiredString` answers "was the key present", not "did the model supply a
/// value", so `{"question": ""}` reached every one of these callees as `""`.
///
/// The class is the same one `create_artifact`'s empty body (wave 16) and
/// `git_pull`'s exit status (wave 14) belong to: a guard exists, it is placed
/// where the bad value is OBSERVED, and it never fires because the value it
/// tests is not the value that arrives. Here the split is sharper still — the
/// argument is declared `required` in the schema, so the schema ADVERTISES a
/// promise the handler does not keep, which is the mirror of the house rule
/// against advertising a tool and then rejecting it.
///
/// What made it expensive rather than merely untidy: each of these callees
/// spends real work before anyone can notice. `ask_teammate` runs a full
/// round-trip on the consulted role's own model; `request_team_meeting`
/// convenes N roles for M turns each; `request_changes` holds a vote and can
/// reset every started downstream role; `ask_supervisor` is silently DROPPED by
/// the dispatcher after the handler already answered `ok: true`.
final class RequiredNonEmptyArgumentCoverageTests: XCTestCase {

    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try FileManager.default.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: 0,
            runID: 0,
            roleID: "test_role",
            // Without declared deliverables, `create_artifact` answers an empty
            // name with `tool_not_authorized` — also `isError`, so the row would
            // stay GREEN with the guard reverted and pin nothing.
            expectedArtifacts: ["Release Notes"]
        )
        // Likewise: a missing image file makes `analyze_image` error for a reason
        // that has nothing to do with its arguments.
        try Data("png".utf8).write(to: tempDir.appendingPathComponent("shot.png"))
        // Same reason for `edit_file`: a missing file errors before `old_text` is
        // ever examined, and the anchor row would pin nothing.
        try "keep DROP keep".write(
            to: tempDir.appendingPathComponent("edit.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        runtime = nil
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - The guarded set

    /// Every free-text argument whose empty value buys a success envelope or an
    /// expensive no-op. The `filled` column is the SAME call with the argument
    /// supplied, and it exists so a rejection can never be credited to some other
    /// missing argument in the same payload.
    private static let guardedArguments:
        [(tool: String, key: String, empty: String, filled: String)] = [
            (
                "ask_supervisor", "question",
                #"{"question":""}"#,
                #"{"question":"Which database?"}"#
            ),
            (
                "ask_teammate", "question",
                #"{"teammate":"Tech Lead","question":""}"#,
                #"{"teammate":"Tech Lead","question":"How?"}"#
            ),
            (
                "request_team_meeting", "topic",
                #"{"topic":"","participants":["Tech Lead"]}"#,
                #"{"topic":"Schema","participants":["Tech Lead"]}"#
            ),
            (
                "request_changes", "changes",
                #"{"target_role":"Engineer","changes":"","reasoning":"r"}"#,
                #"{"target_role":"Engineer","changes":"c","reasoning":"r"}"#
            ),
            (
                "request_changes", "reasoning",
                #"{"target_role":"Engineer","changes":"c","reasoning":""}"#,
                #"{"target_role":"Engineer","changes":"c","reasoning":"r"}"#
            ),
            (
                "analyze_image", "path",
                #"{"path":"","prompt":"What is on screen?"}"#,
                #"{"path":"shot.png","prompt":"What is on screen?"}"#
            ),
            (
                "create_artifact", "name",
                #"{"name":"","content":"body text"}"#,
                #"{"name":"Release Notes","content":"body text"}"#
            ),
        ]

    private func run(_ tool: String, _ argumentsJSON: String) async -> ToolExecutionResult {
        await runtime.executeAll(
            context: context,
            toolCalls: [StepToolCall(name: tool, argumentsJSON: argumentsJSON)]
        )[0]
    }

    /// This test answers "is it rejected AT ALL". For six of the eight rows that
    /// is the whole question, and reverting the site flips them to `ok: true`.
    ///
    /// It deliberately does NOT discriminate for the other two, and saying so is
    /// the point: `analyze_image`'s empty `path` would still error (as an
    /// unsupported FORMAT, because `resolveFileURL("")` returns the work-folder
    /// root), and `create_artifact`'s empty name would still error (as a filename).
    /// Both are rejected either way — just for a reason that is not true. Those two
    /// are pinned by `testTheRejectionNamesTheArgumentAndSaysEmpty`, which is the
    /// discriminating test, and a review found this docstring overclaiming before
    /// the split was written down.
    ///
    /// RED: revert any of the six to `requiredString` → that row reports
    /// `isError == false` and ships a success envelope for a call that asked
    /// nothing. `ask_supervisor` is the sharpest: its envelope says `ok: true`
    /// while `+ToolResultDispatching` declines to park, so the step keeps looping
    /// until the non-productive-turn ceiling kills it.
    func testEveryGuardedArgument_rejectsAnEmptyValue() async {
        for c in Self.guardedArguments {
            let result = await run(c.tool, c.empty)
            XCTAssertTrue(
                result.isError,
                "\(c.tool).\(c.key): an empty required argument must be rejected, not carried")
        }
    }

    /// A model that pads with a newline is not supplying a value either, and the
    /// callees that record their input (`conclude_meeting`, `request_changes`)
    /// would file the whitespace verbatim.
    ///
    /// RED: validate `value.isEmpty` instead of the trimmed value → the six rows
    /// that this test discriminates for pass straight through, and the whitespace
    /// is recorded verbatim as the question / topic / reasoning. (Same two-row
    /// caveat as above: `analyze_image` and `create_artifact` reject a
    /// whitespace-only value for their own reasons.)
    func testEveryGuardedArgument_rejectsAWhitespaceOnlyValue() async {
        for c in Self.guardedArguments {
            // Spelled with escapes, not a raw string: `#":""#` does NOT contain
            // `:""` — a raw string closes at the first `"#`, so the literal ends
            // at the first of the two quotes and the replacement corrupted every
            // fixture into unparseable JSON, which `requiredString`'s
            // `__raw_input__` recovery then handed through as a non-empty value.
            let padded = c.empty.replacingOccurrences(of: ":\"\"", with: ":\" \\n \\t\"")
            XCTAssertNotEqual(padded, c.empty, "precondition: the fixture must have changed")
            XCTAssertNotNil(
                try? JSONSerialization.jsonObject(with: Data(padded.utf8)),
                "precondition: the padded fixture must still be valid JSON — \(padded)")
            let result = await run(c.tool, padded)
            XCTAssertTrue(
                result.isError,
                "\(c.tool).\(c.key): a whitespace-only required argument must be rejected")
        }
    }

    /// The rejection has to name the argument, or a call carrying three required
    /// strings (`request_changes`) tells the model only that "something" was
    /// empty — and it has to say EMPTY, not missing, because the model did send
    /// the key and will otherwise hunt for a phantom omission (the reason
    /// `ToolArgumentError.invalidValue` exists at all).
    ///
    /// RED: throw `.missingRequired(key)` instead → the message reads "Missing
    /// required argument: reasoning" for an argument that was present.
    func testTheRejectionNamesTheArgumentAndSaysEmpty() async {
        for c in Self.guardedArguments {
            let out = await run(c.tool, c.empty).outputJSON
            XCTAssertTrue(
                out.contains(c.key),
                "\(c.tool): the error must name `\(c.key)` — got \(out)")
            XCTAssertTrue(
                out.contains("must not be empty"),
                "\(c.tool).\(c.key): the error must say the value was empty — got \(out)")
        }
    }

    /// Anti-vacuity: each rejection above must be attributable to the empty
    /// argument, not to something else missing from the same payload. Every
    /// `filled` variant must get PAST argument validation — it may still fail
    /// downstream (`analyze_image` has no such file; `create_artifact` writes),
    /// but never with an argument complaint.
    ///
    /// RED: leave a required key out of any `filled` fixture → that row's error
    /// names an argument and the negative control catches the bad fixture.
    func testTheFilledVariants_clearArgumentValidation() async {
        for c in Self.guardedArguments {
            let out = await run(c.tool, c.filled).outputJSON
            XCTAssertFalse(
                out.contains("must not be empty"),
                "\(c.tool).\(c.key): the filled fixture must not trip the empty guard — got \(out)")
            XCTAssertFalse(
                out.contains("Missing required argument"),
                "\(c.tool).\(c.key): the filled fixture is missing another argument — got \(out)")
            // `create_artifact`'s body does NOT arrive via `requiredString` — it goes
            // through `resolveContentString(...) ?? ""` — so a fixture that lost its
            // `content` key produces "has no content", which neither assertion above
            // matches. Without this line the control cannot catch the one fixture
            // most likely to rot.
            XCTAssertFalse(
                out.contains("has no content"),
                "\(c.tool).\(c.key): the filled fixture lost its body — got \(out)")
        }
    }

    // MARK: - Where the DOWNSTREAM message is already better

    /// `edit_file`'s `old_text` looks like the missed site — it is `required`, it is
    /// never legitimately empty, and an empty anchor cannot match. A review flagged
    /// it as such. Measuring the envelope refuted the premise: the tolerant-edit
    /// fallback already diagnoses it specifically, and its hint prescribes the
    /// recovery, which a generic "must not be empty" does not.
    ///
    /// So this is exclusion rule 2, not a gap — and the pin belongs on the MESSAGE,
    /// because that is what earns the exclusion.
    ///
    /// RED: drop the whitespace-only candidate filter in `whitespaceTolerantEdit`
    /// → the empty anchor falls through to the generic "matches exactly including
    /// whitespace" steering, which is a treadmill instruction for an anchor the
    /// model never supplied, and this assertion fails.
    func testEditFile_emptyOldText_isDiagnosedSpecificallyNotGenerically() async {
        let out = await run("edit_file", #"{"path":"edit.txt","old_text":"","new_text":"x"}"#)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(
            out.outputJSON.contains("whitespace-only"),
            "the empty anchor must get the specific hint, not only the generic steering — got \(out.outputJSON)")
    }

    // MARK: - Where empty is a legitimate value

    /// The sweep is per-site precisely because "required" does not imply
    /// "non-empty" everywhere: writing an empty file is a real operation.
    ///
    /// RED: apply `requiredNonEmptyString` to `write_file`'s `content` → this
    /// fails and the model loses the only way to create an empty file.
    func testWriteFile_emptyContent_isStillAccepted() async throws {
        let result = await run("write_file", #"{"path":"empty.txt","content":""}"#)
        XCTAssertFalse(result.isError, "an empty file is a legitimate write: \(result.outputJSON)")
        let written = try String(
            contentsOf: tempDir.appendingPathComponent("empty.txt"), encoding: .utf8)
        XCTAssertEqual(written, "")
    }

    /// Deleting a span is spelled as replacing it with nothing.
    ///
    /// RED: apply `requiredNonEmptyString` to `edit_file`'s `new_text` → this
    /// fails and deletion becomes unexpressible.
    func testEditFile_emptyNewText_stillDeletesTheSpan() async throws {
        let file = tempDir.appendingPathComponent("edit.txt")
        try "keep DROP keep".write(to: file, atomically: true, encoding: .utf8)

        let result = await run("edit_file", #"{"path":"edit.txt","old_text":"DROP ","new_text":""}"#)
        XCTAssertFalse(result.isError, "empty new_text is a deletion: \(result.outputJSON)")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep keep")
    }

    // MARK: - The helper itself

    /// Validated on the trimmed value, RETURNED verbatim — the rule
    /// `set_work_folder_context` already states. Trimming here would silently
    /// reformat prose whose leading and trailing structure is the author's, and
    /// the callees record it (`conclude_meeting`'s decision, `create_artifact`'s
    /// name) rather than merely reading it.
    ///
    /// RED: `return trimmed` → the padded value comes back stripped and a
    /// multi-line decision loses its leading indentation on the way to the
    /// meeting record.
    func testHelper_returnsTheValueVerbatim_withoutTrimming() throws {
        let value = try requiredNonEmptyString(["k": "  padded  "], "k")
        XCTAssertEqual(value, "  padded  ")
    }

    /// An absent key is still `missingRequired` — a different fix for the model
    /// than an empty one, and the two must not collapse.
    ///
    /// RED: implement the helper as `extractString(args, key) ?? throw
    /// .invalidValue` → an omitted key reports "must not be empty", telling the
    /// model to fill in an argument it never sent.
    func testHelper_missingKey_stillReportsMissingNotEmpty() {
        XCTAssertThrowsError(try requiredNonEmptyString([:], "k")) { error in
            guard case ToolArgumentError.missingRequired(let key) = error else {
                return XCTFail("expected .missingRequired, got \(error)")
            }
            XCTAssertEqual(key, "k")
        }
    }

    /// The `__raw_input__` recovery path in `requiredString` is the reason the
    /// helper wraps it instead of reading `args[key]` itself: a model that sent
    /// the whole payload as one JSON string still gets its value.
    ///
    /// RED: read `args[key] as? String` directly in the helper → this throws
    /// `missingRequired` for a call that supplied the argument.
    func testHelper_keepsTheRawInputRecoveryPath() throws {
        let value = try requiredNonEmptyString(
            ["__raw_input__": #"{"question":"Which database?"}"#], "question")
        XCTAssertEqual(value, "Which database?")
    }

    // MARK: - The message the empty name used to get

    /// `isValidArtifactName` rejects an empty name AND a file-shaped one, and the
    /// single call site rendered one message for both — so an empty name was told
    /// it "looks like a filename", sending the model to strip an extension it
    /// never wrote.
    ///
    /// RED: revert `create_artifact`'s `name` to `requiredString` → the empty
    /// name falls into the filename branch and this assertion fails on the
    /// message, while `testEveryGuardedArgument_rejectsAnEmptyValue` stays green
    /// (it IS rejected — just for a reason that isn't true).
    func testCreateArtifact_emptyName_isNotBlamedOnAFileExtension() async {
        let out = await run("create_artifact", #"{"name":"","content":"body text"}"#).outputJSON
        XCTAssertFalse(
            out.contains("looks like a filename"),
            "an empty name has no extension to blame — got \(out)")
        // Without this second assertion the test is VACUOUS on this branch: with
        // no declared deliverables the pre-fix handler answered
        // `tool_not_authorized`, which does not contain the filename wording
        // either, so the mutation that reverts the guard leaves it green. The
        // config complaint is also the WRONG diagnosis here — the role's toolset
        // is not the problem, the missing name is.
        XCTAssertTrue(out.contains("must not be empty"), "got \(out)")
    }

    /// Control for the test above: a genuinely file-shaped name must still get
    /// the filename message, or the fix traded one wrong diagnosis for another.
    ///
    /// The filename message is reachable only when the role HAS declared
    /// deliverables — with none, the handler answers `tool_not_authorized`
    /// instead, which is a config complaint rather than a naming one.
    func testCreateArtifact_fileShapedName_stillGetsTheFilenameMessage() async {
        context.expectedArtifacts = ["Release Notes"]
        let out = await run("create_artifact", #"{"name":"index.html","content":"<p/>"}"#).outputJSON
        XCTAssertTrue(out.contains("looks like a filename"), "got \(out)")
    }

    /// The same wrong-diagnosis check on the branch a role with declared
    /// deliverables takes — the one a real producing role actually hits, and the
    /// only one where the misleading message was ever shown to a model.
    ///
    /// RED: revert `create_artifact`'s `name` to `requiredString` → the empty
    /// name is told to pick one of the role's artifacts because it "looks like a
    /// filename".
    func testCreateArtifact_emptyName_withDeclaredArtifacts_isNotBlamedOnAnExtension() async {
        context.expectedArtifacts = ["Release Notes"]
        let out = await run("create_artifact", #"{"name":"","content":"<p/>"}"#).outputJSON
        XCTAssertFalse(out.contains("looks like a filename"), "got \(out)")
        XCTAssertTrue(out.contains("must not be empty"), "got \(out)")
    }

    // MARK: - The array half of the same class

    /// I asserted, in the helper's doc comment, that `requiredStringArray` had
    /// "always" rejected `{"paths": []}` and that only the string case was
    /// wrong. Writing this test refuted it in one run: `coerceStringArray`
    /// matches `[String]` FIRST and returns it as-is, under its own comment
    /// ("an explicitly empty list stays empty rather than collapsing to nil").
    /// Recorded here so the claim cannot be re-derived from memory.
    ///
    /// RED: add an `isEmpty` guard to `requiredStringArray` (the obvious "hardening" edit) → an
    /// explicitly empty list stops reaching the call sites, and the two per-call-site guards that
    /// give `git_add` and `request_team_meeting` their specific diagnoses become unreachable.
    func testRequiredStringArray_emptyArray_reachesTheCallSiteIntact() throws {
        let paths = try requiredStringArray(["paths": [String]()], "paths")
        XCTAssertEqual(paths, [], "the helper deliberately preserves an explicit empty list")
    }

    /// So the emptiness guard for arrays lives per-site. Both `requiredStringArray`
    /// callers have one, and this pins them together — the string sweep chose a
    /// helper over ten call-site guards, and that choice is only defensible while
    /// the two array sites stay guarded.
    ///
    /// RED: delete `git_add`'s `guard !paths.isEmpty` → a bare `git add` exits 0
    /// and the model is told `ok: true` for staging nothing. Delete
    /// `request_team_meeting`'s participants guard → a meeting is convened with
    /// no participants.
    func testTheTwoRequiredArrayCallSites_rejectAnEmptyListThemselves() async {
        for (tool, json) in [
            ("git_add", #"{"paths":[]}"#),
            ("request_team_meeting", #"{"topic":"Schema","participants":[]}"#),
        ] {
            let out = await run(tool, json)
            XCTAssertTrue(out.isError, "\(tool) must reject an empty required list")
            XCTAssertTrue(
                out.outputJSON.lowercased().contains("empty")
                    || out.outputJSON.contains("At least one"),
                "\(tool): the error must say the list was empty — got \(out.outputJSON)")
        }
    }
}
