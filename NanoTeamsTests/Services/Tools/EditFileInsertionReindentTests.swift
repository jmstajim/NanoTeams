import XCTest

@testable import NanoTeams

/// Replays the `edit_file` failures of MeditationApp task 28 / run 0
/// (`qwen3.8:27b-mlx` on Ollama) — the INSERTION half of the indentation class.
///
/// Task 24 recorded the replacement half: the model re-emits the anchor at a
/// different depth, and `reindentToFileConvention` translates it. That repair can
/// only fire when every depth in `new_text` also appears in the anchor, which is
/// true when `new_text` REWRITES the window and structurally false when it APPENDS
/// to it. All four failures here append a fresh SwiftUI struct after a closing
/// brace, so the three-line anchor (depths 0, 5, 9) meets a `new_text` carrying
/// 4, 8, 12 and 18 — and the whole edit was refused.
///
/// What that cost, from the run: four refusals over 2 min 31 s of an 8 min 28 s
/// run, three of them byte-identical in `old_text`. The model was handed the file's
/// exact bytes each time and could not act on them — it read the 8-space line back
/// as "9 leading spaces" in its own reasoning. It escaped only by abandoning the
/// indented anchor for a zero-indent one (`// MARK: - Profile Tab`), which applied
/// first try.
///
/// The rule under test: lines of `new_text` that ALIGN with the anchor are a rewrite
/// of the file's window and must be translated (the file has a convention there);
/// lines beyond the aligned region are new code the file has no opinion about, and
/// keep the model's own indentation. A refusal survives only where the evidence
/// genuinely conflicts.
///
/// Clock times below are `EditFileTask28Fixtures`' rebased ones (+5 h off the run
/// log, for the test target's 20:00–02:00 band) — subtract 5 h to read them against
/// the log. Durations are unaffected: only the hour field moved.
final class EditFileInsertionReindentTests: XCTestCase {
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

    @discardableResult
    private func replay(
        _ failure: EditFileTask28Fixtures.FailedEdit
    ) async throws -> ToolExecutionResult {
        let url = tempDir.appendingPathComponent(EditFileTask28Fixtures.path)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EditFileTask28Fixtures.contentAtFailure
            .write(to: url, atomically: true, encoding: .utf8)

        let args: [String: Any] = [
            "path": EditFileTask28Fixtures.path,
            "old_text": failure.oldText,
            "new_text": failure.newText,
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let call = StepToolCall(
            name: "edit_file", argumentsJSON: String(data: data, encoding: .utf8)!)
        return await runtime.executeAll(context: context, toolCalls: [call])[0]
    }

    private func onDisk() throws -> String {
        try String(
            contentsOf: tempDir.appendingPathComponent(EditFileTask28Fixtures.path),
            encoding: .utf8)
    }

    private func warnings(_ result: ToolExecutionResult) -> [String] {
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
            as? [String: Any],
            let meta = json["meta"] as? [String: Any],
            let warnings = meta["warnings"] as? [String]
        else { return [] }
        return warnings
    }

    private static func linesExactly(_ text: String, in content: String) -> Int {
        content.components(separatedBy: "\n").filter { $0 == text }.count
    }

    // MARK: - The run

    /// 22:29:12.726 — the anchor the model then repeated twice more verbatim.
    ///
    /// `old_text` is three lines at depths 9, 5, 0 where the file has 8, 4, 0 — a
    /// clean map. `new_text` reproduces those three lines and appends a 25-line
    /// `LibraryCategoryEmptyState` at depths 4/8/12/18.
    ///
    /// RED (before the fix): ANCHOR_NOT_FOUND, file untouched.
    func testReal_libraryEmptyStateInsertion_applies() async throws {
        let failure = EditFileTask28Fixtures.failure(at: "2026-08-15T22:29:12.726")
        let result = try await replay(failure)

        XCTAssertFalse(result.isError, result.outputJSON)

        let written = try onDisk()
        XCTAssertTrue(written.contains("private struct LibraryCategoryEmptyState: View {"),
                      "the appended struct must reach the file")

        // The ALIGNED head is translated into the file's convention: the anchor's
        // 9-space label and 5-space closer land at 8 and 4. Counted as a delta so
        // the assertion cannot pass on lines the file already had.
        XCTAssertEqual(
            Self.linesExactly(
                "         .accessibilityLabel(\"Library empty. No meditation sessions are available yet.\")",
                in: written),
            0,
            "the model's nine-space label must not reach the file")
        XCTAssertEqual(
            Self.linesExactly("     }", in: written),
            Self.linesExactly("     }", in: EditFileTask28Fixtures.contentAtFailure),
            "the edit must not add a five-space closer")
    }

    /// The pass-through is DISCLOSED. A model whose indentation was partly rewritten
    /// and partly kept has to be told which, or the next anchor it builds from memory
    /// is wrong again — the same no-silent-caps rule the walk and the search obey.
    ///
    /// RED: emit no warning → empty.
    func testReal_insertion_disclosesThePassedThroughLines() async throws {
        let failure = EditFileTask28Fixtures.failure(at: "2026-08-15T22:29:12.726")
        let result = try await replay(failure)

        let texts = warnings(result)
        XCTAssertTrue(
            texts.contains(where: { $0.contains("indentation") }),
            "the model must be told which lines kept its own indentation: \(texts)")
    }

    /// …and the disclosure survives the trip to the WIRE, which is a separate claim.
    ///
    /// The test above reads the handler's envelope. The model never sees that envelope:
    /// `MemoryTagStore.processEdit` REBUILDS one field by field, so any disclosure the
    /// handler writes and the store does not copy is silently dropped between them. Both
    /// `matched_ignoring_indentation` and `meta.warnings` were being dropped exactly that
    /// way — the first since the tolerance that introduced it — so an edit whose leading
    /// whitespace had been rewritten reached the model as an unqualified success.
    ///
    /// RED: remove either forwarding branch in `processEdit` → the matching assertion fails.
    func testReal_insertion_disclosuresSurviveTheTagStore() async throws {
        let failure = EditFileTask28Fixtures.failure(at: "2026-08-15T22:29:12.726")
        let result = try await replay(failure)
        XCTAssertFalse(result.isError, result.outputJSON)

        guard case .tagged(let wire, _) = MemoryTagStore().processToolResult(result) else {
            return XCTFail("a successful edit must be tagged")
        }
        XCTAssertTrue(
            wire.contains("\"matched_ignoring_indentation\":true"),
            "the model must learn its indentation was rewritten: \(wire)")
        XCTAssertTrue(
            wire.contains("\"warnings\":["),
            "the kept-indentation disclosure must reach the wire: \(wire)")
        XCTAssertTrue(wire.contains("indentation"), wire)
    }

    /// A clean edit stays clean: nothing is added to the wire envelope when there was
    /// nothing to disclose, so the forwarding above cannot become noise on every call.
    ///
    /// RED: forward the keys unconditionally → both assertions fail.
    func testCleanEdit_addsNoDisclosureToTheWire() async throws {
        let url = tempDir.appendingPathComponent(EditFileTask28Fixtures.path)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EditFileTask28Fixtures.contentAtFailure
            .write(to: url, atomically: true, encoding: .utf8)

        let args: [String: Any] = [
            "path": EditFileTask28Fixtures.path,
            "old_text": EditFileTask28Fixtures.escapeAnchor,
            "new_text": EditFileTask28Fixtures.escapeAnchor + "\n// appended",
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let call = StepToolCall(
            name: "edit_file", argumentsJSON: String(data: data, encoding: .utf8)!)
        let result = await runtime.executeAll(context: context, toolCalls: [call])[0]
        XCTAssertFalse(result.isError, result.outputJSON)

        guard case .tagged(let wire, _) = MemoryTagStore().processToolResult(result) else {
            return XCTFail("a successful edit must be tagged")
        }
        XCTAssertFalse(wire.contains("matched_ignoring_indentation"), wire)
        XCTAssertFalse(wire.contains("warnings"), wire)
    }

    /// All four failures of the run apply, and none of them corrupts the file's own
    /// four-space convention at the seam.
    ///
    /// RED (before the fix): 4 errors.
    func testReal_everyFailureFromTheRun_nowApplies() async throws {
        for failure in EditFileTask28Fixtures.failures {
            let result = try await replay(failure)
            XCTAssertFalse(
                result.isError, "\(failure.timestamp) still refused: \(result.outputJSON)")

            let written = try onDisk()
            XCTAssertTrue(
                written.contains("private struct LibraryCategoryEmptyState: View {"),
                "\(failure.timestamp): the appended struct is missing")
            XCTAssertEqual(
                Self.linesExactly("     }", in: written),
                Self.linesExactly("     }", in: EditFileTask28Fixtures.contentAtFailure),
                "\(failure.timestamp): added a five-space closer")
        }
    }

    /// The fixture set is the run, not a sample, and every case is insertion-shaped —
    /// which is the property that made the old refusal unreachable-by-retry.
    func testFixtures_matchTheRun() {
        XCTAssertEqual(EditFileTask28Fixtures.failures.count, 4, "fixture set drifted")
        for failure in EditFileTask28Fixtures.failures {
            XCTAssertTrue(
                failure.newText.hasPrefix(failure.oldText),
                "\(failure.timestamp) (\(failure.note)) is not insertion-shaped")
        }
    }

    /// The last three calls held `old_text` BYTE-IDENTICAL and changed only the
    /// appended block's depth. That is why nothing stopped the loop: the failure
    /// detector keys on `(tool, argumentsIdentity)`, and a canonical re-encode of
    /// these arguments differs every time.
    ///
    /// The fixture asserts the premise so the detector test below cannot quietly
    /// stop describing the run it was written for.
    func testFixtures_theLoopHeldTheAnchorAndMovedOnlyTheReplacement() {
        let looping = EditFileTask28Fixtures.failures.suffix(3)
        XCTAssertEqual(looping.count, 3)

        let anchors = Set(looping.map(\.oldText))
        XCTAssertEqual(anchors.count, 1, "the three retries must share one anchor")

        let replacements = Set(looping.map(\.newText))
        XCTAssertEqual(
            replacements.count, 3,
            "each retry must differ in new_text — that is what defeated the detector")
    }
}
