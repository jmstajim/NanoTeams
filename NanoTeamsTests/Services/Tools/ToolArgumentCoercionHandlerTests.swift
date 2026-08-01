import XCTest

@testable import NanoTeams

/// End-to-end proof that string-typed arguments reach real tool BEHAVIOR.
///
/// Small local models routinely quote their numerics and booleans
/// (`{"depth": "2"}`, `{"replace_all": "true"}`). Before `ToolArgumentHelpers`
/// grew its coercers, a strict `as? Int` / `as? Bool` cast made those values
/// invisible — and because `optionalInt`/`optionalBool` have no failure
/// channel, the rejection did not surface as an error. It silently became the
/// handler's DEFAULT, so the wrong branch ran under a success envelope:
/// `search paths` widened to the whole tree, `edit_file replace_all` rewrote
/// one occurrence instead of all, `write_file create_dirs` created a tree the
/// model asked it not to.
///
/// Every test here drives a real `ToolRuntime` and asserts on an OBSERVABLE
/// behavioral difference (which files were traversed, how many replacements
/// landed, whether a directory exists on disk) — never merely "no error",
/// which is exactly what the pre-fix bug produced.
///
/// `read_lines` coercion is pinned separately in `ReadLinesLineLimitTests`;
/// only the error-message contrast is (re)asserted here, because that pair is
/// what proves the new `invalidValue` case is distinguishable from
/// `missingRequired` on the wire.
final class ToolArgumentCoercionHandlerTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("ToolArgumentCoercionHandlerTests_\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fm.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        runtime = nil
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func run(_ tool: String, _ argsJSON: String) -> ToolExecutionResult {
        let call = StepToolCall(name: tool, argumentsJSON: argsJSON)
        return runtime.executeAll(context: context, toolCalls: [call])[0]
    }

    /// Writes `body` at `relativePath`, creating intermediate directories.
    @discardableResult
    private func write(_ relativePath: String, _ body: String) throws -> URL {
        let url = tempDir.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func envelope(_ json: String) -> [String: Any]? {
        guard let d = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private func payload(_ json: String) -> [String: Any]? {
        envelope(json)?["data"] as? [String: Any]
    }

    private func errorMessage(_ json: String) -> String? {
        (envelope(json)?["error"] as? [String: Any])?["message"] as? String
    }

    private func errorCode(_ json: String) -> String? {
        (envelope(json)?["error"] as? [String: Any])?["code"] as? String
    }

    /// Every path `list_files` returned — files and dirs merged, sorted for stable
    /// comparison. Paths are relative to the work-folder root, so a listing of
    /// `tree` yields `tree/lvl1`, not `lvl1`.
    private func entryPaths(_ json: String) -> [String] {
        let data = payload(json)
        let files = data?["files"] as? [String] ?? []
        let dirs = data?["dirs"] as? [String] ?? []
        return (files + dirs).sorted()
    }

    private func searchMatches(_ json: String) -> [[String: Any]] {
        payload(json)?["matches"] as? [[String: Any]] ?? []
    }

    private func searchMatchPaths(_ json: String) -> [String] {
        searchMatches(json).compactMap { $0["path"] as? String }.sorted()
    }

    /// Builds `tree/lvl1/lvl2/deep.txt` — three nesting levels, one entry per
    /// level, so each depth value yields a distinct entry set.
    private func makeNestedTree() throws {
        try write("tree/lvl1/lvl2/deep.txt", "deep")
    }

    // MARK: - list_files: depth

    /// `depth` defaults to 1, so a still-strict `as? Int` would swallow `"2"`
    /// and return the depth-1 set while still reporting success. Asserting
    /// against the no-arg baseline is what makes the claim falsifiable:
    /// it proves the deeper entry appeared BECAUSE of the argument.
    func testListFiles_depthAsString_deepensTraversalVersusDefault() throws {
        try makeNestedTree()

        let baseline = run("list_files", "{\"path\": \"tree\"}")
        let stringDepth = run("list_files", "{\"path\": \"tree\", \"depth\": \"1\"}")

        XCTAssertFalse(baseline.isError, "baseline listing must succeed; got: \(baseline.outputJSON)")
        XCTAssertFalse(stringDepth.isError, "string depth must succeed; got: \(stringDepth.outputJSON)")

        // `depth` is 0-indexed recursion depth, so the default (omitted == 0) is the
        // direct contents and "1" is exactly one level deeper.
        XCTAssertEqual(entryPaths(baseline.outputJSON), ["tree/lvl1"],
                       "default depth must stop at the direct contents")
        XCTAssertEqual(entryPaths(stringDepth.outputJSON), ["tree/lvl1", "tree/lvl1/lvl2"],
                       "depth:\"1\" must traverse one level deeper than the default; a rejected "
                       + "string silently falls back to the default")
    }

    /// A coercion that parses but off-by-ones (or truncates) would pass the
    /// versus-default test above while still returning the wrong tier. Pinning
    /// string == literal at a third depth closes that gap.
    func testListFiles_depthAsString_equivalentToNumericLiteral() throws {
        try makeNestedTree()

        let asString = run("list_files", "{\"path\": \"tree\", \"depth\": \"3\"}")
        let asNumber = run("list_files", "{\"path\": \"tree\", \"depth\": 3}")

        XCTAssertFalse(asString.isError, "got: \(asString.outputJSON)")
        XCTAssertFalse(asNumber.isError, "got: \(asNumber.outputJSON)")

        XCTAssertEqual(entryPaths(asNumber.outputJSON),
                       ["tree/lvl1", "tree/lvl1/lvl2", "tree/lvl1/lvl2/deep.txt"],
                       "sanity: literal depth 3 must reach the leaf file")
        XCTAssertEqual(entryPaths(asString.outputJSON), entryPaths(asNumber.outputJSON),
                       "depth:\"3\" must be indistinguishable from depth:3")
    }

    // MARK: - search: numeric caps

    /// `max_results` defaults to 50, so a rejected `"2"` returns every hit —
    /// a cap the model asked for and silently did not get.
    func testSearch_maxResultsAsString_capsMatchCount() throws {
        for i in 1...6 {
            try write("cap/hit\(i).txt", "NEEDLE")
        }

        let uncapped = run("search", "{\"query\": \"NEEDLE\"}")
        let capped = run("search", "{\"query\": \"NEEDLE\", \"max_results\": \"2\"}")

        XCTAssertFalse(uncapped.isError, "got: \(uncapped.outputJSON)")
        XCTAssertFalse(capped.isError, "got: \(capped.outputJSON)")

        XCTAssertEqual(searchMatches(uncapped.outputJSON).count, 6,
                       "sanity: all six needles are findable without a cap")
        XCTAssertEqual(searchMatches(capped.outputJSON).count, 2,
                       "max_results:\"2\" must cap the result list; a rejected string falls back "
                       + "to the default cap and returns everything")
    }

    /// `context_before` defaults to 2. Requesting 4 as a string must widen the
    /// window — a rejected value leaves the default in place, so the model
    /// receives less context than it asked for with no signal.
    func testSearch_contextBeforeAsString_widensContextWindow() throws {
        let lines = (1...20).map { $0 == 10 ? "CTXNEEDLE" : "filler \($0)" }
        try write("ctx/file.txt", lines.joined(separator: "\n"))

        let r = run("search", "{\"query\": \"CTXNEEDLE\", \"context_before\": \"4\"}")

        XCTAssertFalse(r.isError, "got: \(r.outputJSON)")
        guard let match = searchMatches(r.outputJSON).first else {
            return XCTFail("expected one match; got: \(r.outputJSON)")
        }
        let before = match["context_before"] as? [[String: Any]] ?? []
        XCTAssertEqual(before.count, 4,
                       "context_before:\"4\" must emit four preceding lines (default is "
                       + "\(AppDefaults.searchContextBefore)); got \(before.count)")
    }

    /// Zero is the value most likely to be lost: a coercer that treats "0" as
    /// falsy-and-therefore-absent hands back nil, and the default applies.
    /// `context_before` is passed EXPLICITLY as a live control — its presence proves the context
    /// machinery ran, so the absence of `context_after` is a real suppression rather than a dead
    /// code path. It used to rely on `context_before`'s default being non-zero; both context
    /// defaults are now 0 (search returns just the matching line unless asked otherwise), which
    /// would have made this test vacuous.
    func testSearch_contextAfterAsStringZero_suppressesTrailingContext() throws {
        let lines = (1...20).map { $0 == 10 ? "ZERONEEDLE" : "filler \($0)" }
        try write("ctx/zero.txt", lines.joined(separator: "\n"))

        let r = run("search",
                    "{\"query\": \"ZERONEEDLE\", \"context_before\": 2, \"context_after\": \"0\"}")

        XCTAssertFalse(r.isError, "got: \(r.outputJSON)")
        guard let match = searchMatches(r.outputJSON).first else {
            return XCTFail("expected one match; got: \(r.outputJSON)")
        }
        XCTAssertNotNil(match["context_before"],
                        "control: an explicit context_before must be populated")
        XCTAssertNil(match["context_after"],
                     "context_after:\"0\" must suppress trailing context entirely; a rejected "
                     + "zero would fall back to a non-zero default")
    }

    // MARK: - search: paths scoping

    /// The headline silent-widening case. `paths` is a narrowing constraint
    /// with no failure channel: when the bare string was rejected, `paths`
    /// became nil and the executor walked the WHOLE work folder while still
    /// reporting success — the model believed it had searched one directory.
    func testSearch_pathsAsBareString_scopesTheWalk() throws {
        try write("inside/hit.txt", "SCOPENEEDLE")
        try write("outside/hit.txt", "SCOPENEEDLE")

        let scoped = run("search", "{\"query\": \"SCOPENEEDLE\", \"paths\": \"inside\"}")

        XCTAssertFalse(scoped.isError, "got: \(scoped.outputJSON)")
        XCTAssertEqual(searchMatchPaths(scoped.outputJSON), ["inside/hit.txt"],
                       "paths:\"inside\" must exclude the identical needle under outside/; "
                       + "a rejected bare string widens the search to the whole tree")
    }

    /// The `[Any]` branch: JSON `null` inside the list makes the array fail to
    /// bridge to `[String]`. Dropping the NSNull keeps the constraint alive;
    /// rejecting the whole array re-opens the same scope widening, and mapping
    /// NSNull through `String(describing:)` would inject a bogus "null" path.
    func testSearch_pathsArrayWithNullElement_stillScopesTheWalk() throws {
        try write("inside/hit.txt", "NULLNEEDLE")
        try write("outside/hit.txt", "NULLNEEDLE")

        let scoped = run("search", "{\"query\": \"NULLNEEDLE\", \"paths\": [\"inside\", null]}")

        XCTAssertFalse(scoped.isError,
                       "a null element must be dropped, not turned into an unresolvable path; "
                       + "got: \(scoped.outputJSON)")
        XCTAssertEqual(searchMatchPaths(scoped.outputJSON), ["inside/hit.txt"],
                       "the surviving element must still scope the walk")
    }

    // MARK: - write_file: create_dirs

    /// `create_dirs` defaults to TRUE, so a rejected `"false"` does the exact
    /// opposite of the instruction: it builds the tree the model refused. The
    /// on-disk assertion is the load-bearing one — an error envelope alone
    /// would not prove the directory was left alone.
    func testWriteFile_createDirsAsStringFalse_refusesToCreateParent() throws {
        let r = run("write_file",
                    "{\"path\": \"nodir/f.txt\", \"content\": \"body\", \"create_dirs\": \"false\"}")

        XCTAssertTrue(r.isError, "create_dirs:\"false\" with a missing parent must fail; got: \(r.outputJSON)")
        XCTAssertEqual(errorCode(r.outputJSON), ToolErrorCode.notADirectory.rawValue,
                       "got: \(r.outputJSON)")
        XCTAssertFalse(fm.fileExists(atPath: tempDir.appendingPathComponent("nodir").path),
                       "the parent directory must NOT have been created")
    }

    /// The other half of the bool contract: only unambiguous spellings are
    /// honored, and anything else keeps the CALLER's default rather than
    /// collapsing to `false`. A coercer that mapped unknown strings to false
    /// would break every write into a not-yet-existing directory.
    func testWriteFile_createDirsUncoercible_keepsCallerDefault() throws {
        let r = run("write_file",
                    "{\"path\": \"yesdir/f.txt\", \"content\": \"body\", \"create_dirs\": \"maybe\"}")

        XCTAssertFalse(r.isError,
                       "an uncoercible bool must fall back to the default (true), not to false; "
                       + "got: \(r.outputJSON)")
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("yesdir/f.txt").path),
                      "the file must have been written through a created parent directory")
    }

    // MARK: - edit_file: replace_all

    /// The headline silent-degradation case. `replace_all` defaults to false,
    /// so a rejected `"true"` rewrites exactly one of three occurrences and
    /// still returns a success envelope — the model reads "done" and moves on
    /// with two stale call sites behind it.
    func testEditFile_replaceAllAsStringTrue_replacesEveryOccurrence() throws {
        let body = ["let a = OLD", "let b = OLD", "let c = OLD"].joined(separator: "\n")
        let url = try write("edit/target.swift", body)

        let r = run("edit_file",
                    "{\"path\": \"edit/target.swift\", \"old_text\": \"OLD\", "
                    + "\"new_text\": \"NEW\", \"replace_all\": \"true\"}")

        XCTAssertFalse(r.isError, "got: \(r.outputJSON)")
        XCTAssertEqual(payload(r.outputJSON)?["replacements_made"] as? Int, 3,
                       "replace_all:\"true\" must report three replacements; a rejected string "
                       + "falls back to false and reports one")

        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(after.contains("OLD"),
                       "no occurrence may survive on disk; got: \(after)")
        XCTAssertEqual(after.components(separatedBy: "NEW").count - 1, 3,
                       "all three occurrences must be rewritten; got: \(after)")
    }

    // MARK: - delete_file: must_exist

    /// `must_exist` defaults to TRUE, so a rejected `"false"` turns an
    /// explicitly-tolerant delete into a hard error the model has to recover
    /// from — the opposite of the requested semantics.
    func testDeleteFile_mustExistAsStringFalse_succeedsOnMissingPath() throws {
        let r = run("delete_file", "{\"path\": \"ghost.txt\", \"must_exist\": \"false\"}")

        XCTAssertFalse(r.isError,
                       "must_exist:\"false\" on a missing path must succeed; got: \(r.outputJSON)")
        XCTAssertEqual(payload(r.outputJSON)?["deleted"] as? Bool, false,
                       "the envelope must report that nothing was deleted; got: \(r.outputJSON)")
    }

    // MARK: - Error surface: present-but-uncoercible vs absent

    /// The whole point of the new `invalidValue` case, proven on the wire.
    ///
    /// Both calls fail with INVALID_ARGS, so the CODE cannot distinguish them —
    /// only the message can, and the two must not be interchangeable. Asserting
    /// the pair (rather than either alone) is what catches a `requiredInt` that
    /// throws one variant unconditionally: a mutation always reporting
    /// `invalidValue` passes a lone "must not say Missing" test, and one always
    /// reporting `missingRequired` is the original bug that sent models hunting
    /// for a phantom omission.
    func testRequiredInt_uncoercibleVersusAbsent_produceDistinctMessages() throws {
        try write("err/file.txt", "line one")

        let uncoercible = run("read_lines", "{\"path\": \"err/file.txt\", \"start_line\": \"five\"}")
        let absent = run("read_lines", "{\"path\": \"err/file.txt\"}")

        XCTAssertTrue(uncoercible.isError, "got: \(uncoercible.outputJSON)")
        XCTAssertTrue(absent.isError, "got: \(absent.outputJSON)")
        XCTAssertEqual(errorCode(uncoercible.outputJSON), ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(errorCode(absent.outputJSON), ToolErrorCode.invalidArgs.rawValue)

        let uncoercibleMessage = errorMessage(uncoercible.outputJSON) ?? ""
        let absentMessage = errorMessage(absent.outputJSON) ?? ""

        XCTAssertFalse(uncoercibleMessage.contains("Missing"),
                       "a present-but-wrong-type argument must not be reported as missing; "
                       + "got: \(uncoercibleMessage)")
        XCTAssertTrue(uncoercibleMessage.contains("start_line"),
                      "the type error must name the offending key; got: \(uncoercibleMessage)")
        XCTAssertTrue(absentMessage.contains("Missing"),
                      "a genuinely absent required argument must still be reported as missing; "
                      + "got: \(absentMessage)")
        XCTAssertNotEqual(uncoercibleMessage, absentMessage,
                          "the two failure modes must be distinguishable by the model")
    }

    /// JSON `null` counts as ABSENT, not as a malformed value — the model
    /// omitted a value rather than supplying garbage, so the guidance it needs
    /// is "you forgot this", not "fix your type".
    func testRequiredInt_jsonNull_reportedAsMissingNotInvalid() throws {
        try write("err/null.txt", "line one")

        let r = run("read_lines", "{\"path\": \"err/null.txt\", \"start_line\": null}")

        XCTAssertTrue(r.isError, "got: \(r.outputJSON)")
        XCTAssertTrue((errorMessage(r.outputJSON) ?? "").contains("Missing"),
                      "a null-valued required argument must read as absent; got: \(r.outputJSON)")
    }
}
