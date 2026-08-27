import XCTest

@testable import NanoTeams

/// Replays the `edit_file` failures of a real NanoTeams run against the tool.
///
/// Run: MeditationApp task 24 / run 0, `qwen3.8:27b-mlx` on Ollama. 40 `edit_file`
/// calls, **31 failed — every one `ANCHOR_NOT_FOUND`**. Two independent causes, both
/// represented here verbatim:
///
///  - the project's own indentation was irregular (5-space doc comments beside
///    4-space members, left by earlier agent runs). `read_file` returns that
///    faithfully; the model re-emitted canonical 4/8-space anchors and missed
///    forever, then began perturbing spaces at random — 9 spaces where the file has
///    8 — because the error told it to check whitespace and nothing else.
///  - 22 anchors named code that was not in the file at all, and were answered with
///    the same whitespace advice.
///
/// Fixtures are byte-exact (`EditFileRealRunFixtures`); the ugly indentation is the
/// point. Each test names the log timestamp so a failure points back at the call.
final class EditFileRealRunRegressionTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fileManager.removeItem(at: tempDir) }
        context = nil
        tempDir = nil
        runtime = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Stages the file exactly as it was on disk when the recorded call ran, then
    /// replays that call.
    @discardableResult
    private func replay(
        _ failure: EditFileRealRunFixtures.FailedEdit
    ) async throws -> ToolExecutionResult {
        let url = tempDir.appendingPathComponent(failure.path)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try failure.contentAtFailure.write(to: url, atomically: true, encoding: .utf8)

        let args: [String: Any] = [
            "path": failure.path, "old_text": failure.oldText, "new_text": failure.newText,
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let call = StepToolCall(
            name: "edit_file", argumentsJSON: String(data: data, encoding: .utf8)!)
        return await runtime.executeAll(context: context, toolCalls: [call])[0]
    }

    private func onDisk(_ failure: EditFileRealRunFixtures.FailedEdit) throws -> String {
        try String(contentsOf: tempDir.appendingPathComponent(failure.path), encoding: .utf8)
    }

    private func message(_ result: ToolExecutionResult) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
            as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return "" }
        return message
    }

    private func dataField(_ result: ToolExecutionResult, _ key: String) -> Any? {
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
            as? [String: Any],
            let data = json["data"] as? [String: Any]
        else { return nil }
        return data[key]
    }

    // MARK: - Tier 3a: the model's indentation is translatable

    /// 10:08:26.484 — `SettingsModel.swift`. The model opened the block with four
    /// spaces and closed it with FIVE; the file uses four for both. That is a
    /// well-defined map (`4→4, 8→8, 5→4`), so the edit applies and the replacement's
    /// stray fifth space is rewritten into the file's convention.
    ///
    /// RED: drop the tier-3 branch in `whitespaceTolerantEdit` → ANCHOR_NOT_FOUND.
    /// RED: return `newLines` unmapped instead of `reindented` → the file keeps `     }`.
    func testReal_settingsModelInit_isAutoReindented() async throws {
        let failure = EditFileRealRunFixtures.failure(at: "2026-08-15T10:08:26.484")
        let result = try await replay(failure)

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(dataField(result, "matched_ignoring_indentation") as? Bool, true,
                       "the model must be told its indentation was rewritten")
        XCTAssertNil(dataField(result, "matched_ignoring_trailing_whitespace"),
                     "this was an indentation match, not a trailing-whitespace one")

        let written = try onDisk(failure)
        XCTAssertTrue(written.contains("        self.loadError = loaded.error\n    }"),
                      "the block must close at the file's four-space depth, not the model's five")
        // Line-ANCHORED, and stated as a delta. A bare `contains("     }")` is
        // meaningless here twice over: an eight-space closer contains a five-space
        // one as a suffix, and this file independently carries four five-space
        // closers of its own (the same corruption, elsewhere). What must hold is
        // that the edit introduced no NEW one.
        XCTAssertEqual(
            Self.linesExactly("     }", in: written),
            Self.linesExactly("     }", in: failure.contentAtFailure),
            "the edit must not add a five-space closer")
    }

    private static func linesExactly(_ text: String, in content: String) -> Int {
        content.components(separatedBy: "\n").filter { $0 == text }.count
    }

    // MARK: - Tier 3b: the irregular window, resolved per line

    /// 09:58:38.469 — `SessionHistoryStore.swift`, the very first failure of the run.
    /// The anchor's `"    "` corresponds to `"     "` on the doc-comment lines and to
    /// `"    "` on the members — the per-depth map's one genuine conflict, and the
    /// run's only located-but-refused call. Per line the conflict never existed:
    /// each reproduced line pairs with its own file line and takes its bytes, and
    /// the model's new properties keep the model's own (disclosed).
    ///
    /// RED: emit the model's bytes for a PAIRED line (skip the file-leading arm in
    /// `reindentToFileConvention`) → the five-space doc comment collapses to four
    /// and the first line-anchored assert fails.
    func testReal_sessionHistoryDocComments_landsKeepingTheFilesFiveSpaceDocs() async throws {
        let failure = EditFileRealRunFixtures.failure(at: "2026-08-15T09:58:38.469")
        let result = try await replay(failure)

        XCTAssertFalse(result.isError, result.outputJSON)
        let written = try onDisk(failure)
        // The reproduced doc comments PAIR with their own file lines and keep the
        // file's irregular FIVE spaces — under the per-depth map this very window
        // was the one genuine conflict refusal of the run (4sp → {5sp, 4sp}).
        XCTAssertTrue(
            written.contains("\n     /// Raw, persisted history. Streaks and totals are derived from this."),
            "the file's five-space line survives, line-anchored")
        XCTAssertTrue(
            written.contains("\n     /// Directory + file where history is persisted."),
            "both irregular doc lines keep the file's bytes")
        // The NEW properties land with the model's own four-space docs — the
        // conflicted key is unusable, so nothing is guessed for them — disclosed.
        XCTAssertTrue(
            written.contains("\n    /// Transient, non-persisted message when the last save failed."),
            "the inserted properties keep the model's bytes")
        XCTAssertEqual(dataField(result, "matched_ignoring_indentation") as? Bool, true,
                       "a paired doc line's leading DID change (model 4sp → file 5sp): \(result.outputJSON)")
        XCTAssertTrue(Self.warningTexts(result).contains { $0.contains("kept your own indentation") },
                      "the kept depths are disclosed: \(Self.warningTexts(result))")
    }

    /// 09:59:01.393 — the guess-loop escalation, 23 seconds after the failure above.
    /// Having been told to check whitespace, the model shifted its anchor to NINE and
    /// FIVE spaces where the file has eight and four. That map is consistent, and the
    /// replacement reproduces the anchor and then APPENDS two properties at depths the
    /// two-line anchor could not have shown.
    ///
    /// This used to refuse, on the reasoning that a depth with no evidence must not be
    /// invented. The reasoning holds for a rewrite and not for an append: measured
    /// across task 24 and task 28, the refusal never once produced a corrected retry,
    /// while the appended block is new code the file has no convention for, so the
    /// model's own indentation is the only defensible thing to write there.
    ///
    /// The accepted cost is visible below and is the reason the tail is DISCLOSED: the
    /// six-space doc comments land in a file that uses none. That is cosmetic in Swift
    /// and recoverable from the warning; the refusal was neither.
    ///
    /// RED: restore `return nil` for unmapped prefixes → ANCHOR_NOT_FOUND, file untouched.
    func testReal_encoderTail_appendsAndKeepsTheNewLinesIndentation() async throws {
        let failure = EditFileRealRunFixtures.failure(at: "2026-08-15T09:59:01.393")
        let result = try await replay(failure)

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(dataField(result, "matched_ignoring_indentation") as? Bool, true)

        let written = try onDisk(failure)
        // The ALIGNED head is translated into the file's eight/four convention…
        XCTAssertTrue(written.contains("        return encoder\n    }()"),
                      "the reproduced anchor must land at the file's depth")
        XCTAssertEqual(
            Self.linesExactly("         return encoder", in: written), 0,
            "the model's nine-space line must not reach the file")
        // …and the APPENDED lines keep the model's own indentation, disclosed.
        XCTAssertTrue(written.contains("      /// Transient, non-persisted message when the last save failed."),
                      "the appended six-space doc comment is kept verbatim")
        XCTAssertTrue(
            Self.warningTexts(result).contains(where: { $0.contains("indentation") }),
            "the kept indentation must be disclosed: \(Self.warningTexts(result))")
    }

    private static func warningTexts(_ result: ToolExecutionResult) -> [String] {
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
            as? [String: Any],
            let meta = json["meta"] as? [String: Any],
            let warnings = meta["warnings"] as? [String]
        else { return [] }
        return warnings
    }

    // MARK: - Absent anchors: the dominant real failure

    /// 10:08:30.067 — `ContentView.swift`. `struct StatCard` does not exist in that
    /// file under any spelling; the model invented it while emitting 56 tool calls in
    /// one response, before any of the reads in the same batch had returned.
    ///
    /// The old message answered this with "make sure it matches exactly including
    /// whitespace and indentation", which is unactionable — there is nothing to
    /// match. That sentence must not appear.
    ///
    /// RED: fold `.absent` back into the generic `anchorNotFoundMessage` → the
    /// whitespace assertion fails.
    func testReal_hallucinatedStatCard_reportsAbsentNotWhitespace() async throws {
        let failure = EditFileRealRunFixtures.failure(at: "2026-08-15T10:08:30.067")
        XCTAssertTrue(failure.oldText.hasPrefix("    struct StatCard"), "fixture drifted")

        let result = try await replay(failure)
        let text = message(result)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(text.contains("none of its lines appear"), text)
        XCTAssertTrue(text.contains(failure.path), "name the file: \(text)")
        XCTAssertFalse(text.contains("whitespace and indentation"),
                       "must not send the model hunting whitespace: \(text)")
        XCTAssertEqual(try onDisk(failure), failure.contentAtFailure)
    }

    // MARK: - Diverging anchors: stale, not absent

    /// 10:08:30.143 — the anchor starts matching, then breaks: the model wrote
    /// `VStack(spacing: 20)`, the file says `24`. It cannot diff its anchor against a
    /// file it is not looking at, so the message names both sides and the line.
    ///
    /// RED: report `.absent` for a partial match → the divergence assertions fail.
    func testReal_vStackSpacing_reportsTheDivergingLine() async throws {
        let failure = EditFileRealRunFixtures.failure(at: "2026-08-15T10:08:30.143")
        let result = try await replay(failure)
        let text = message(result)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(text.contains("VStack(spacing: 20)"), "quote what the model sent: \(text)")
        XCTAssertTrue(text.contains("VStack(spacing: 24)"), "quote what the file has: \(text)")
        XCTAssertFalse(text.contains("none of its lines appear"),
                       "a partial match is stale, not absent: \(text)")
    }

    /// 10:08:30.362 — `SettingsView.swift`, a second diverging case in a different
    /// file so the first is not pinning a coincidence. `Section("General")` vs the
    /// file's `Section("Daily Reminder")`.
    func testReal_settingsViewSection_reportsTheDivergingLine() async throws {
        let failure = EditFileRealRunFixtures.failure(at: "2026-08-15T10:08:30.362")
        let result = try await replay(failure)
        let text = message(result)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(text.contains("Section(\"General\")"), text)
        XCTAssertTrue(text.contains("Section(\"Daily Reminder\")"), text)
    }

    // MARK: - The batch that produced most of this

    /// 10:08:30.191 and .213 — the SAME `edit_file`, byte-for-byte (2795 characters of
    /// arguments), twice in one assistant response. `deduplicateToolCalls` existed but
    /// was gated on a streaming break that this reply never tripped, so both executed.
    ///
    /// RED: re-gate the collapse on a streaming break having fired → two calls survive.
    func testReal_identicalMainContentCall_executesOnce() throws {
        let first = EditFileRealRunFixtures.failure(at: "2026-08-15T10:08:30.191")
        let second = EditFileRealRunFixtures.failure(at: "2026-08-15T10:08:30.213")
        XCTAssertEqual(first.oldText, second.oldText, "fixture drifted")
        XCTAssertEqual(first.newText, second.newText, "fixture drifted")

        func call(_ f: EditFileRealRunFixtures.FailedEdit) throws -> StepToolCall {
            let args: [String: Any] = [
                "path": f.path, "old_text": f.oldText, "new_text": f.newText,
            ]
            let data = try JSONSerialization.data(withJSONObject: args)
            return StepToolCall(
                name: "edit_file", argumentsJSON: String(data: data, encoding: .utf8)!)
        }

        let calls = [try call(first), try call(second)]
        XCTAssertTrue(LLMExecutionService.containsDuplicateToolCalls(calls))
        XCTAssertEqual(LLMExecutionService.deduplicateToolCalls(calls).count, 1)
    }

    /// The collapse above must be UNCONDITIONAL at its call site.
    ///
    /// Structural, because the behavioural test cannot see this: it calls the helper
    /// directly, so re-gating the call site leaves it green — verified by mutation.
    /// The streaming path that holds the gate has no test seam, and this is the house
    /// pattern for a wiring invariant that cannot be reached behaviourally.
    ///
    /// A gate is what let the duplicate through in the field: the collapse used to run only
    /// when a streaming `break` had already fired, and that break's own preconditions were
    /// never met by the 56-call reply. This pin used to name the flag that carried the gate;
    /// the flag outlived its last reader and was removed, which retired that spelling — and
    /// with it the anti-vacuum assertion that the identifier must still exist. The durable
    /// property is the one asserted here: the call is a plain statement of its `do` body,
    /// not the inside of any conditional.
    ///
    /// RED: wrap the call in `if thinkingLoopSignal != nil { … }` → BOTH arms fire, the
    /// window arm because a conditional opens above it and the indentation arm because it
    /// sits one level deeper. The indentation arm is the one that survives distance: a gate
    /// opened twenty lines up still deepens the call, where the window sees nothing.
    func testDeduplication_isNotGatedAtItsCallSite() throws {
        let source = try String(
            contentsOf: RatchetSourceScan.repoRoot.appendingPathComponent(
                "NanoTeams/Services/LLM/LLMExecutionService+Streaming.swift"),
            encoding: .utf8)
        // Comments stripped first: the call site is documented with prose that describes the
        // very gate this pin forbids, and a raw scan would read the explanation as the thing.
        let lines = RatchetSourceScan.strippingLineComments(source).components(separatedBy: "\n")

        let scan = Self.scanDedupCallSite(lines)
        XCTAssertEqual(scan.callSiteCount, 1, "expected exactly one call site to police")
        XCTAssertNotNil(
            scan.doBodyIndent,
            "anti-vacuum: the enclosing `do {` was not found, so the indentation arm proves nothing")
        XCTAssertEqual(scan.offenders, [], "the duplicate collapse must not be conditional")
    }

    /// The half the scan above structurally cannot prove: that the rule REJECTS the shape it
    /// exists to reject (CLAUDE.md #57). Runs the SAME predicate over a synthetic gated
    /// fixture, one per arm, so a rule that silently stopped firing cannot pass as a clean
    /// tree. Written as literal lines rather than a file so the fixture can never drift into
    /// the corpus the pin scans.
    func testTheRuleFiresOnAGatedCallSite() {
        let needle = "deduplicateToolCalls" + "("

        let gatedNearby = [
            "        do {",
            "            if somethingFired {",
            "                resolvedToolCalls = Self.\(needle)resolvedToolCalls)",
            "            }",
        ]
        XCTAssertFalse(
            Self.scanDedupCallSite(gatedNearby).offenders.isEmpty,
            "a conditional opening directly above the call must be rejected")

        // The same gate, opened far enough above that a three-line window cannot see it —
        // only the indentation arm can. Without this the window arm could carry both cases
        // and the indentation arm would be untested.
        let gatedFarAway = [
            "        do {",
            "            if somethingFired {",
            "                let a = 1", "                let b = 2", "                let c = 3",
            "                let d = 4", "                let e = 5",
            "                resolvedToolCalls = Self.\(needle)resolvedToolCalls)",
            "            }",
        ]
        XCTAssertFalse(
            Self.scanDedupCallSite(gatedFarAway).offenders.isEmpty,
            "a gate opened beyond the window must still be rejected, by indentation")

        let ungated = [
            "        do {",
            "            resolvedToolCalls = Self.\(needle)resolvedToolCalls)",
        ]
        XCTAssertEqual(
            Self.scanDedupCallSite(ungated).offenders, [],
            "the rule must ACCEPT the shape production actually has")
    }

    /// Where the single `deduplicateToolCalls(…)` call sits relative to the `do {` body it
    /// must be a plain statement of.
    private struct DedupCallSite {
        let callSiteCount: Int
        /// Indentation of the enclosing `do {`. `nil` means the scan could not anchor, which
        /// makes the indentation arm vacuous — asserted separately rather than silently
        /// passing.
        let doBodyIndent: Int?
        /// Non-empty when the call is gated.
        let offenders: [String]
    }

    private static func scanDedupCallSite(_ lines: [String]) -> DedupCallSite {
        func indentation(of line: String) -> Int {
            line.prefix(while: { $0 == " " }).count
        }
        func trimmed(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespaces)
        }

        let needle = "deduplicateToolCalls" + "("
        let callSites = lines.indices.filter {
            lines[$0].contains(needle) && !lines[$0].contains("func ")
        }
        let doBodyIndent = lines.first { trimmed($0) == "do {" }.map(indentation(of:))

        guard let call = callSites.first else {
            return DedupCallSite(
                callSiteCount: callSites.count, doBodyIndent: doBodyIndent, offenders: [])
        }

        var offenders: [String] = []
        let openers = ["if ", "guard ", "switch ", "else {", "else if ", "} else"]
        for line in lines[max(0, call - 3)..<call]
            where line.contains("{") && openers.contains(where: { trimmed(line).hasPrefix($0) }) {
            offenders.append(line)
        }
        // Catches a gate opened at ANY distance: one statement level below `do {` is the only
        // depth an ungated call can have.
        if let doBodyIndent, indentation(of: lines[call]) > doBodyIndent + 4 {
            offenders.append(lines[call])
        }
        return DedupCallSite(
            callSiteCount: callSites.count, doBodyIndent: doBodyIndent, offenders: offenders)
    }

    // MARK: - Whole-run classification

    /// Replays all 31 recorded failures and asserts how many land in each bucket.
    ///
    /// This is the anti-vacuum pin for the whole change: the individual tests above
    /// each prove one bucket is reachable, and this one proves the split has not
    /// silently shifted. It is also the number that justifies the work — 10 of the
    /// 31 calls now simply succeed, and the remaining 21 get a diagnosis naming the
    /// actual problem instead of whitespace advice.
    ///
    /// RED: collapse `.diverges` into `.absent` (drop the `bestPartialMatch` arm) →
    /// `diverging` reads 0 and `absent` reads 21, so both equality assertions fail.
    func testReal_everyFailingAnchorFromTheRun_isClassified() async throws {
        var applied = 0
        var indentationRefusal = 0
        var diverging = 0
        var absent = 0
        var unclassified: [String] = []

        for failure in EditFileRealRunFixtures.failures {
            let result = try await replay(failure)
            if !result.isError {
                XCTAssertEqual(dataField(result, "matched_ignoring_indentation") as? Bool, true,
                               "a recovered call must disclose the re-indent (\(failure.timestamp))")
                applied += 1
                continue
            }
            let text = message(result)
            if text.contains("ignoring indentation") {
                indentationRefusal += 1
                XCTAssertEqual(try onDisk(failure), failure.contentAtFailure,
                               "refusal must not write (\(failure.timestamp))")
            } else if text.contains("none of its lines appear") {
                absent += 1
            } else if text.contains("but line") {
                diverging += 1
            } else {
                unclassified.append("\(failure.timestamp): \(text)")
            }
        }

        XCTAssertEqual(EditFileRealRunFixtures.failures.count, 31, "fixture set drifted")
        XCTAssertTrue(unclassified.isEmpty, "unclassified: \(unclassified)")
        // 10 across three steps of the same tolerance: 8 when tier 3 landed, +1
        // when the append rule landed (09:59:01.393), +1 when per-line alignment
        // dissolved the map conflict at 09:58:38.469 — the run's ONE
        // located-but-refused call, whose anchor depth corresponded to two file
        // depths. No located refusals remain in this corpus; the buckets left are
        // the honest ones — stale copies and hallucinated code.
        XCTAssertEqual(applied, 10, "calls recovered outright")
        XCTAssertEqual(indentationRefusal, 0, "located windows all translate per line now")
        XCTAssertEqual(diverging, 7, "stale anchors")
        XCTAssertEqual(absent, 14, "anchors naming code that never existed")
    }

    /// Not one of the 31 may be ADVISED to correct whitespace unless the tool
    /// actually located the region — that misdiagnosis is what kept the run looping.
    /// Stated separately from the counts so it survives a re-split.
    ///
    /// Keys on the two advice phrases, never on the bare word "whitespace": the
    /// `.absent` message legitimately contains that word inside a DENIAL ("this is
    /// not a whitespace problem"), and a `contains("whitespace")` probe passes
    /// against prose that says the opposite of what it is checking for.
    ///
    /// RED: restore the unconditional `anchorNotFoundMessage` prefix → 21 violations.
    func testReal_whitespaceAdviceOnlyWhenTheRegionWasFound() async throws {
        let advicePhrases = ["whitespace and indentation", "check leading whitespace"]
        for failure in EditFileRealRunFixtures.failures {
            let result = try await replay(failure)
            guard result.isError else { continue }
            let text = message(result)
            guard advicePhrases.contains(where: text.contains) else { continue }
            XCTAssertTrue(
                text.contains("ignoring indentation"),
                "\(failure.timestamp) advises a whitespace fix without having located the region: \(text)")
        }
    }
}
