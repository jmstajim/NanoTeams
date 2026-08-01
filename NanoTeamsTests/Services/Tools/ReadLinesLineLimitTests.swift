import XCTest

@testable import NanoTeams

/// Pins the silent-truncation behavior of `read_lines`: requests whose
/// effective range exceeds the configured limit succeed but return only
/// the first `lineLimit` lines (`end_line` in the result reflects the
/// truncation point, while `total_lines` exposes the true file size so
/// the LLM can paginate via `start_line: end_line + 1`).
/// Mirrors `ReadFileLineLimitTests` so both tools honor the same
/// Settings → Tool Behavior → Line limit value uniformly. `0` is the
/// "unlimited" sentinel — the cap is skipped entirely.
final class ReadLinesLineLimitTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("ReadLinesLineLimitTests_\(UUID().uuidString)", isDirectory: true)
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
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func runReadLines(args: String, customLimit: Int? = nil) -> ToolExecutionResult {
        let activeRuntime: ToolRuntime
        if let customLimit {
            let paths = NTMSPaths(workFolderRoot: tempDir)
            let (_, run) = ToolRegistry.defaultRegistry(
                workFolderRoot: tempDir,
                toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0),
                readFileMaxLines: customLimit
            )
            activeRuntime = run
        } else {
            activeRuntime = runtime
        }
        let call = StepToolCall(name: "read_lines", argumentsJSON: args)
        return activeRuntime.executeAll(context: context, toolCalls: [call])[0]
    }

    private func writeFile(name: String, lineCount: Int) throws -> URL {
        let body = (1...lineCount).map { "Line \($0)" }.joined(separator: "\n")
        let url = tempDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func assertEndLine(_ json: String, _ expected: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            json.contains("\"end_line\":\(expected)") || json.contains("\"end_line\" : \(expected)"),
            "expected end_line=\(expected) in result; got: \(json)",
            file: file, line: line
        )
    }

    private func assertStartLine(_ json: String, _ expected: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            json.contains("\"start_line\":\(expected)") || json.contains("\"start_line\" : \(expected)"),
            "expected start_line=\(expected) in result; got: \(json)",
            file: file, line: line
        )
    }

    private func assertTotalLines(_ json: String, _ expected: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            json.contains("\"total_lines\":\(expected)") || json.contains("\"total_lines\" : \(expected)"),
            "expected total_lines=\(expected) in result; got: \(json)",
            file: file, line: line
        )
    }

    /// Extracts the `content` string from a result envelope and counts how many
    /// lines it actually contains. Used to verify the slice reflects the cap.
    private func contentLineCount(_ json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let dataField = obj["data"] as? [String: Any] ?? obj
        guard let content = dataField["content"] as? String else { return nil }
        if content.isEmpty { return 0 }
        return content.components(separatedBy: "\n").count
    }

    // MARK: - Range within limit (no truncation)

    // MARK: - Continuation cursor

    /// The description tells the model to repeat the call with `start_line: next_start_line`,
    /// which replaced an instruction to notice `end_line < total_lines` and then compute
    /// `end_line + 1`. The field has to be present exactly when there is more to read.
    private func rangeData(_ args: String, customLimit: Int? = nil) throws -> [String: Any] {
        let r = runReadLines(args: args, customLimit: customLimit)
        XCTAssertFalse(r.isError, r.outputJSON)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(r.outputJSON.utf8)) as? [String: Any])
        return try XCTUnwrap(obj["data"] as? [String: Any])
    }

    func testNextStartLine_presentWhenTheRangeWasCapped() throws {
        _ = try writeFile(name: "big.txt", lineCount: 40)

        let d = try rangeData("{\"path\": \"big.txt\", \"start_line\": 1, \"end_line\": 10}")
        XCTAssertEqual(d["end_line"] as? Int, 10)
        XCTAssertEqual(d["next_start_line"] as? Int, 11)
    }

    /// The cap that matters most is the configured line limit, not an explicit `end_line`.
    func testNextStartLine_presentWhenTheLineLimitCappedTheRead() throws {
        _ = try writeFile(name: "big.txt", lineCount: 40)

        let d = try rangeData(
            "{\"path\": \"big.txt\", \"start_line\": 1}", customLimit: 5)
        XCTAssertEqual(d["end_line"] as? Int, 5)
        XCTAssertEqual(d["next_start_line"] as? Int, 6)
    }

    func testNextStartLine_absentAtEndOfFile() throws {
        _ = try writeFile(name: "small.txt", lineCount: 5)

        let d = try rangeData("{\"path\": \"small.txt\", \"start_line\": 1, \"end_line\": 5}")
        XCTAssertEqual(d["end_line"] as? Int, 5)
        XCTAssertNil(d["next_start_line"], "nothing left, so no cursor to follow")
    }

    /// Following the cursor verbatim reads the file exactly once: no gap, no overlap.
    func testNextStartLine_followingItCoversTheFileExactlyOnce() throws {
        _ = try writeFile(name: "walk.txt", lineCount: 23)

        var covered: [Int] = []
        var start = 1
        for _ in 0..<30 {
            let d = try rangeData(
                "{\"path\": \"walk.txt\", \"start_line\": \(start), \"end_line\": \(start + 6)}")
            let from = try XCTUnwrap(d["start_line"] as? Int)
            let to = try XCTUnwrap(d["end_line"] as? Int)
            covered += Array(from...to)
            guard let next = d["next_start_line"] as? Int else { break }
            start = next
        }
        XCTAssertEqual(covered, Array(1...23), "contiguous, in order, no repeats")
    }

    func testReadLines_rangeWithinLimit_returnsRequestedRange() throws {
        // 250-line file, default cap 500, request first 200 lines → exact match.
        _ = try writeFile(name: "small.txt", lineCount: 250)

        let r = runReadLines(args: "{\"path\": \"small.txt\", \"start_line\": 1, \"end_line\": 200}")

        XCTAssertFalse(r.isError, "in-limit read must succeed; got: \(r.outputJSON)")
        assertEndLine(r.outputJSON, 200)
        assertTotalLines(r.outputJSON, 250)
    }

    func testReadLines_rangeExactlyAtLimit_returnsFullRange() throws {
        // 600-line file, default cap 500, request first 500 lines → exact match
        // (range == cap, not strictly greater, so no truncation).
        let limit = AppDefaults.readFileMaxLines
        _ = try writeFile(name: "atLimit.txt", lineCount: 600)

        let r = runReadLines(args: "{\"path\": \"atLimit.txt\", \"start_line\": 1, \"end_line\": \(limit)}")

        XCTAssertFalse(r.isError)
        assertEndLine(r.outputJSON, limit)
        assertTotalLines(r.outputJSON, 600)
    }

    // MARK: - Range over limit (silent truncation)

    func testReadLines_rangeOneOverLimit_truncatesToCap() throws {
        // 600-line file, default cap 500, request 1..501 → returned range capped to 500.
        let limit = AppDefaults.readFileMaxLines
        _ = try writeFile(name: "over.txt", lineCount: 600)

        let r = runReadLines(args: "{\"path\": \"over.txt\", \"start_line\": 1, \"end_line\": \(limit + 1)}")

        XCTAssertFalse(r.isError, "oversized range must succeed (silent cap), not error")
        assertEndLine(r.outputJSON, limit)
        assertTotalLines(r.outputJSON, 600)
        // Body sanity: line `limit` is included, line `limit + 1` is not.
        XCTAssertTrue(r.outputJSON.contains("Line \(limit)"))
        XCTAssertFalse(r.outputJSON.contains("Line \(limit + 1)\\n") || r.outputJSON.contains("Line \(limit + 1)\""),
                       "line beyond cap must NOT appear in returned content")
    }

    func testReadLines_endLineSentinelOnLargeFile_truncatesToCap() throws {
        // 1000-line file with `end_line: -1` → readToEOF resolves to 1000, then
        // cap clamps to 500. Result reports end_line=500 + total_lines=1000 so
        // the LLM can paginate from line 501.
        let limit = AppDefaults.readFileMaxLines
        _ = try writeFile(name: "huge.txt", lineCount: 1000)

        let r = runReadLines(args: "{\"path\": \"huge.txt\", \"start_line\": 1, \"end_line\": -1}")

        XCTAssertFalse(r.isError, "end_line=-1 must succeed even when file > cap (silent cap)")
        assertEndLine(r.outputJSON, limit)
        assertTotalLines(r.outputJSON, 1000)
    }

    func testReadLines_offsetStart_capRelativeToStart() throws {
        // 1500-line file, start=200, end=-1 → readToEOF=1500, cap clamps to
        // start + lineLimit - 1 = 200 + 500 - 1 = 699. Pagination friendly:
        // next call from 700 picks up exactly where this one left off.
        let limit = AppDefaults.readFileMaxLines
        _ = try writeFile(name: "tail.txt", lineCount: 1500)

        let r = runReadLines(args: "{\"path\": \"tail.txt\", \"start_line\": 200, \"end_line\": -1}")

        XCTAssertFalse(r.isError)
        assertEndLine(r.outputJSON, 200 + limit - 1)
        assertTotalLines(r.outputJSON, 1500)
    }

    // MARK: - Sentinel paths that don't trigger the cap

    func testReadLines_endLineSentinelOnSmallFile_returnsFullFile() throws {
        // 100-line file with `end_line: -1` → resolves to 100, well under cap;
        // returned end_line == total_lines so the LLM knows it has everything.
        _ = try writeFile(name: "tiny.txt", lineCount: 100)

        let r = runReadLines(args: "{\"path\": \"tiny.txt\", \"start_line\": 1, \"end_line\": -1}")

        XCTAssertFalse(r.isError)
        assertEndLine(r.outputJSON, 100)
        assertTotalLines(r.outputJSON, 100)
    }

    func testReadLines_endLineBeyondTotalLines_clampedToFile() throws {
        // 100-line file, request 1..10000 → clamped to file length first, then
        // cap (100 ≤ 500). end_line == total_lines → no pagination needed.
        _ = try writeFile(name: "clamp.txt", lineCount: 100)

        let r = runReadLines(args: "{\"path\": \"clamp.txt\", \"start_line\": 1, \"end_line\": 10000}")

        XCTAssertFalse(r.isError)
        assertEndLine(r.outputJSON, 100)
        assertTotalLines(r.outputJSON, 100)
    }

    func testReadLines_emptyFileSentinel_succeeds() throws {
        // Empty file: `components(separatedBy: .newlines)` returns [""] → totalLines = 1.
        let url = tempDir.appendingPathComponent("empty.txt")
        try "".write(to: url, atomically: true, encoding: .utf8)

        let r = runReadLines(args: "{\"path\": \"empty.txt\", \"start_line\": 1, \"end_line\": -1}")

        XCTAssertFalse(r.isError)
        assertEndLine(r.outputJSON, 1)
        assertTotalLines(r.outputJSON, 1)
    }

    func testReadLines_legacyQwenSentinelRegression_stillWorks() throws {
        _ = try writeFile(name: "qwen.txt", lineCount: 5)

        let r = runReadLines(args: "{\"path\": \"qwen.txt\", \"start_line\": 2, \"end_line\": -1}")

        XCTAssertFalse(r.isError)
        assertEndLine(r.outputJSON, 5)
    }

    // MARK: - Cap arithmetic invariants

    func testReadLines_offsetStartWithSubCapRange_capDoesNotFire() throws {
        // 1000-line file, cap 500, start=600, end=-1. Effective range = 401 (≤ cap),
        // so cap MUST NOT fire. Pins the cap-anchored-to-start invariant —
        // collapsing the formula to `min(end, lineLimit)` would clamp this to
        // 500 and produce an inverted slice.
        _ = try writeFile(name: "offset.txt", lineCount: 1000)

        let r = runReadLines(args: "{\"path\": \"offset.txt\", \"start_line\": 600, \"end_line\": -1}")

        XCTAssertFalse(r.isError)
        assertEndLine(r.outputJSON, 1000)
        assertTotalLines(r.outputJSON, 1000)
    }

    func testReadLines_returnedContentLineCount_neverExceedsCap() throws {
        // The metadata reports the cap, but the actual returned content must
        // contain the same number of lines. Catches slicing bugs that leave
        // metadata correct but content out of sync.
        let limit = AppDefaults.readFileMaxLines
        _ = try writeFile(name: "huge.txt", lineCount: 1000)

        let r = runReadLines(args: "{\"path\": \"huge.txt\", \"start_line\": 1, \"end_line\": -1}")

        XCTAssertFalse(r.isError)
        guard let count = contentLineCount(r.outputJSON) else {
            return XCTFail("could not parse content from result: \(r.outputJSON)")
        }
        XCTAssertEqual(count, limit, "content must contain exactly \(limit) lines (one per cap line); got \(count)")
    }

    // MARK: - Custom limit threading

    func testReadLines_customLimit_isHonored() throws {
        // Registry built with limit=50 → request 1..-1 on 200-line file must
        // truncate at line 50, proving the value flowed all the way from
        // `defaultRegistry(readFileMaxLines:)` into the handler.
        _ = try writeFile(name: "custom.txt", lineCount: 200)

        let r = runReadLines(
            args: "{\"path\": \"custom.txt\", \"start_line\": 1, \"end_line\": -1}",
            customLimit: 50
        )

        XCTAssertFalse(r.isError)
        assertEndLine(r.outputJSON, 50)
        assertTotalLines(r.outputJSON, 200)
    }

    // MARK: - Unlimited sentinel (0)

    func testReadLines_unlimitedSentinel_readsHugeRange() throws {
        // 5000-line file with limit=0 (unlimited) must succeed for any range.
        _ = try writeFile(name: "huge.txt", lineCount: 5000)

        let r = runReadLines(
            args: "{\"path\": \"huge.txt\", \"start_line\": 1, \"end_line\": -1}",
            customLimit: 0
        )

        XCTAssertFalse(r.isError, "limit=0 must skip the cap entirely")
        assertEndLine(r.outputJSON, 5000)
        assertTotalLines(r.outputJSON, 5000)
    }

    // MARK: - Optional `end_line`

    func testEndLineOmitted_returnsLineLimitWindowFromStart() throws {
        // `end_line` absent → identical to passing the EOF sentinel: read from
        // `start_line` and let the per-call cap clamp.
        let limit = AppDefaults.readFileMaxLines
        _ = try writeFile(name: "omit.txt", lineCount: 1000)

        let r = runReadLines(args: "{\"path\": \"omit.txt\", \"start_line\": 1}")

        XCTAssertFalse(r.isError, "missing end_line must succeed silently. Got: \(r.outputJSON)")
        assertEndLine(r.outputJSON, limit)
        assertTotalLines(r.outputJSON, 1000)
    }

    func testEndLineOmitted_paginates() throws {
        // Second pagination call also omits end_line → reads the second window.
        let limit = AppDefaults.readFileMaxLines
        _ = try writeFile(name: "paginate.txt", lineCount: 1000)

        let r = runReadLines(args: "{\"path\": \"paginate.txt\", \"start_line\": \(limit + 1)}")

        XCTAssertFalse(r.isError)
        assertEndLine(r.outputJSON, 1000)
        assertTotalLines(r.outputJSON, 1000)
    }

    func testEndLineOmitted_unlimitedSentinel() throws {
        // Omitted end_line + limit=0 → read the entire file in one call.
        _ = try writeFile(name: "huge_omit.txt", lineCount: 1000)

        let r = runReadLines(
            args: "{\"path\": \"huge_omit.txt\", \"start_line\": 1}",
            customLimit: 0
        )

        XCTAssertFalse(r.isError)
        assertEndLine(r.outputJSON, 1000)
        assertTotalLines(r.outputJSON, 1000)
    }

    func testEndLineOmitted_equivalentToAnyNonPositive() throws {
        // Any non-positive `end_line` value (or absent) collapses to the same
        // read-to-EOF path. Pins that the sentinel branch is `<= 0`, not
        // strictly `0 or -1` — small models routinely emit arbitrary negatives
        // and the runtime should treat them identically (per CORE_PRINCIPLES).
        _ = try writeFile(name: "equiv.txt", lineCount: 50)

        let omit = runReadLines(args: "{\"path\": \"equiv.txt\", \"start_line\": 1}")
        let zero = runReadLines(args: "{\"path\": \"equiv.txt\", \"start_line\": 1, \"end_line\": 0}")
        let minusOne = runReadLines(args: "{\"path\": \"equiv.txt\", \"start_line\": 1, \"end_line\": -1}")
        let minusHundred = runReadLines(args: "{\"path\": \"equiv.txt\", \"start_line\": 1, \"end_line\": -100}")

        for r in [omit, zero, minusOne, minusHundred] {
            XCTAssertFalse(r.isError, "expected success for read; got: \(r.outputJSON)")
            assertEndLine(r.outputJSON, 50)
            XCTAssertEqual(contentLineCount(r.outputJSON), 50)
        }
    }

    // MARK: - Transposed range (silent swap)

    func testTransposedRange_swapsStartAndEnd() throws {
        // start: 100, end: 50 on a 1000-line file → swap to 50..100. Range
        // (51 lines) is well under the 500-line cap, so end_line lands exactly
        // at 100 — no further clamping.
        _ = try writeFile(name: "swap.txt", lineCount: 1000)

        let r = runReadLines(args: "{\"path\": \"swap.txt\", \"start_line\": 100, \"end_line\": 50}")

        XCTAssertFalse(r.isError, "transposed range must succeed (silent swap). Got: \(r.outputJSON)")
        assertStartLine(r.outputJSON, 50)
        assertEndLine(r.outputJSON, 100)
        assertTotalLines(r.outputJSON, 1000)
    }

    func testTransposedRange_respectsLineLimit() throws {
        // start: 1000, end: 1, file: 1500 lines, lineLimit: 500 → swap to 1..1000,
        // then per-call cap clamps to 1..500. The next pagination call (start=501)
        // continues normally.
        let limit = AppDefaults.readFileMaxLines
        _ = try writeFile(name: "swap_cap.txt", lineCount: 1500)

        let r = runReadLines(args: "{\"path\": \"swap_cap.txt\", \"start_line\": 1000, \"end_line\": 1}")

        XCTAssertFalse(r.isError)
        assertStartLine(r.outputJSON, 1)
        assertEndLine(r.outputJSON, limit)
        assertTotalLines(r.outputJSON, 1500)
    }

    func testTransposedRange_startBeyondTotalLines_swapRescues() throws {
        // start: 5000, end: 10 on a 100-line file → swap to 10..5000, then
        // clamp to file length: 10..100. Without the swap, startLine=5000
        // would hit the "exceeds file length" guard and error.
        _ = try writeFile(name: "rescue.txt", lineCount: 100)

        let r = runReadLines(args: "{\"path\": \"rescue.txt\", \"start_line\": 5000, \"end_line\": 10}")

        XCTAssertFalse(r.isError, "swap must rescue start_line that's out of bounds when end_line is in bounds. Got: \(r.outputJSON)")
        assertStartLine(r.outputJSON, 10)
        assertEndLine(r.outputJSON, 100)
        assertTotalLines(r.outputJSON, 100)
    }

    func testTransposedRange_negativeStartLineWithPositiveEndLine_stillErrors() throws {
        // start: -3, end: 10. No swap fires (endLineRaw=10 is not less than
        // startLineRaw=-3), so post-resolution startLine stays -3 and the
        // `>= 1` guard errors. Pins the ordering of (swap → guard) so a
        // future refactor that swapped (guard → swap) silently produces
        // wrong reads instead.
        _ = try writeFile(name: "neg.txt", lineCount: 50)

        let r = runReadLines(args: "{\"path\": \"neg.txt\", \"start_line\": -3, \"end_line\": 10}")

        XCTAssertTrue(r.isError, "negative start_line must error even when end_line is valid. Got: \(r.outputJSON)")
        XCTAssertTrue(r.outputJSON.contains("start_line must be >= 1"))
    }

    func testTransposedRange_zeroStartLineWithPositiveEndLine_stillErrors() throws {
        // start: 0, end: 5. Same shape as the negative case — no swap (endLineRaw
        // is not less than startLineRaw=0), guard errors.
        _ = try writeFile(name: "zero.txt", lineCount: 50)

        let r = runReadLines(args: "{\"path\": \"zero.txt\", \"start_line\": 0, \"end_line\": 5}")

        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.outputJSON.contains("start_line must be >= 1"))
    }

    func testEndLineEqualsStartLine_singleLineRead() throws {
        // Boundary: swap condition is strict `<` (not `<=`), so start == end
        // is a valid one-line read, not a no-op-then-swap. Without this pin,
        // a regression that flipped the comparison to `<=` would silently
        // swap and still return the same single line — invisible until
        // someone reads `start_line: 5, end_line: 5` expecting line 5 and
        // gets it via the wrong code path.
        _ = try writeFile(name: "single.txt", lineCount: 10)

        let r = runReadLines(args: "{\"path\": \"single.txt\", \"start_line\": 5, \"end_line\": 5}")

        XCTAssertFalse(r.isError)
        assertStartLine(r.outputJSON, 5)
        assertEndLine(r.outputJSON, 5)
        XCTAssertEqual(contentLineCount(r.outputJSON), 1, "single-line range must return exactly one line")
        XCTAssertTrue(r.outputJSON.contains("Line 5"))
    }

    // MARK: - Numeric strings (small-model emission)

    func testStringEncodedRange_readsRequestedRange() throws {
        // Verbatim payload from a production failure: the model emitted both
        // bounds as JSON strings. Strict `as? Int` rejection reported
        // "Missing required argument: start_line" for an argument that was
        // plainly present, wedging the model into retry loops.
        _ = try writeFile(name: "strings.txt", lineCount: 800)

        let r = runReadLines(
            args: "{\"path\": \"strings.txt\", \"start_line\": \"501\", \"end_line\": \"754\"}"
        )

        XCTAssertFalse(r.isError, "string-encoded bounds must succeed. Got: \(r.outputJSON)")
        assertStartLine(r.outputJSON, 501)
        assertEndLine(r.outputJSON, 754)
        assertTotalLines(r.outputJSON, 800)
        XCTAssertEqual(contentLineCount(r.outputJSON), 254)
    }

    func testStringEncodedStartLine_withNumericEndLine() throws {
        // Mixed types in one payload — models are inconsistent within a single
        // emission, so each argument must coerce independently.
        _ = try writeFile(name: "mixed.txt", lineCount: 100)

        let r = runReadLines(args: "{\"path\": \"mixed.txt\", \"start_line\": \"10\", \"end_line\": 20}")

        XCTAssertFalse(r.isError, "Got: \(r.outputJSON)")
        assertStartLine(r.outputJSON, 10)
        assertEndLine(r.outputJSON, 20)
    }

    func testStringEncodedEOFSentinel_readsToEOF() throws {
        // Pins the fully string-encoded shape end-to-end: both bounds quoted,
        // `end_line` carrying the EOF sentinel, reads the whole file without
        // erroring. (Pre-fix this failed on `start_line: "1"`.)
        //
        // It deliberately does NOT claim to pin the coercion of `"-1"` itself —
        // that is unobservable here: the handler collapses omitted / 0 / -1 into
        // one `readToEOF` branch, so a `"-1"` that degraded to nil would produce
        // an identical envelope. The discriminating pin lives at the seam, in
        // `ToolArgumentHelpersTests.testOptionalInt_negativeNumericString_coerces`.
        _ = try writeFile(name: "sentinel.txt", lineCount: 40)

        let r = runReadLines(args: "{\"path\": \"sentinel.txt\", \"start_line\": \"1\", \"end_line\": \"-1\"}")

        XCTAssertFalse(r.isError, "Got: \(r.outputJSON)")
        assertEndLine(r.outputJSON, 40)
    }

    func testStringEncodedBounds_withStringEncodedBool_honorsBool() throws {
        // Mixed quoting in one payload — the shape a numeric-quoting model
        // actually emits. Before int coercion this call aborted at `start_line`
        // and never reached `include_line_numbers`; once the int is accepted,
        // a still-strict bool would silently fall back to its `true` default
        // and return gutter-numbered text under a success envelope, with the
        // model believing it asked for raw lines.
        _ = try writeFile(name: "mixedtypes.txt", lineCount: 20)

        let r = runReadLines(
            args: "{\"path\": \"mixedtypes.txt\", \"start_line\": \"1\", \"end_line\": \"5\", \"include_line_numbers\": \"false\"}"
        )

        XCTAssertFalse(r.isError, "Got: \(r.outputJSON)")
        XCTAssertFalse(r.outputJSON.contains("\u{2502}"),
                       "include_line_numbers:\"false\" must suppress the line-number gutter. Got: \(r.outputJSON)")
    }

    func testStartLineNonNumericValue_errorsWithTypeNotMissing() throws {
        // `start_line` is required, so an uncoercible value must error — but the
        // message has to name the type problem. Reporting "Missing" for an
        // argument the model just sent is what caused the original confusion.
        _ = try writeFile(name: "badstart.txt", lineCount: 20)

        let r = runReadLines(args: "{\"path\": \"badstart.txt\", \"start_line\": \"five\"}")

        XCTAssertTrue(r.isError)
        XCTAssertFalse(r.outputJSON.contains("Missing required argument"),
                       "present-but-wrong-type must not report Missing. Got: \(r.outputJSON)")
        XCTAssertTrue(r.outputJSON.contains("start_line"), "Got: \(r.outputJSON)")
    }

    func testEndLineNonNumericValue_treatedAsAbsent() throws {
        // `optionalInt` returns nil for non-numeric values; the handler then
        // collapses to readToEOF. Per CORE_PRINCIPLES, sloppy LLM types map
        // to the most charitable interpretation (here: the same shape as
        // omitting the field) rather than an error envelope.
        _ = try writeFile(name: "junk.txt", lineCount: 20)

        let r = runReadLines(args: "{\"path\": \"junk.txt\", \"start_line\": 1, \"end_line\": \"fifty\"}")

        XCTAssertFalse(r.isError, "non-numeric end_line must collapse to read-to-EOF, not error. Got: \(r.outputJSON)")
        assertEndLine(r.outputJSON, 20)
        assertTotalLines(r.outputJSON, 20)
    }
}
