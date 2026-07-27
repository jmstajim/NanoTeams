import XCTest

@testable import NanoTeams

/// Pins the rule that decides whether a tool-emitting turn re-arms the no-tool ceiling.
///
/// The defect this guards: `runOneLLMToolIteration` used to zero
/// `consecutiveNonProductiveTurns` for ANY batch containing a non-`ask_supervisor` call,
/// and it did so BEFORE the tools ran. So a turn whose every call came back
/// `tool_not_authorized` still reset the ceiling — and since `maxToolIterations` is `0`
/// (unlimited) and the Autovisor manager is excluded from its own stuck detector,
/// "emit one rejected call per turn" was unbounded. Observed in a real pass: one live
/// `task_status` on turn 8 restarted the whole 20-turn budget from zero.
///
/// The rule is pure so it can be pinned at all — its production consumer sits inside
/// `runOneLLMToolIteration`, which no test drives end-to-end without a full client +
/// runtime. The wiring is pinned separately, below.
final class ToolTurnProductivityTests: XCTestCase {

    // MARK: - Fixtures

    private func ok(_ name: String = "task_status") -> ToolExecutionResult {
        ToolExecutionResult(toolName: name, argumentsJSON: "{}", outputJSON: #"{"ok":true}"#, isError: false)
    }

    private func failed(_ name: String = "swift_build") -> ToolExecutionResult {
        ToolExecutionResult(
            toolName: name, argumentsJSON: "{}",
            outputJSON: #"{"ok":false,"error":{"code":"tool_not_authorized"}}"#, isError: true)
    }

    // MARK: - Truth table

    func testAllResultsError_isNonProductive() {
        XCTAssertEqual(
            ToolTurnProductivity.classify(
                isAskSupervisorOnly: false, toolResults: [failed(), failed("wait_for_evts")]),
            .nonProductive,
            "A batch that advanced nothing must not re-arm the ceiling — this is the whole defect")
    }

    func testOneSuccessAmongErrors_isProductive() {
        XCTAssertEqual(
            ToolTurnProductivity.classify(
                isAskSupervisorOnly: false, toolResults: [failed(), ok(), failed()]),
            .productive,
            "One tool really ran; the model acted")
    }

    func testAllResultsSucceed_isProductive() {
        XCTAssertEqual(
            ToolTurnProductivity.classify(isAskSupervisorOnly: false, toolResults: [ok(), ok()]),
            .productive)
    }

    /// Corner: `executeToolCalls` can early-return `[]` (nil delegate), and the
    /// gate-merge loop can leave `toolResults` shorter than the emitted calls. Both mean
    /// nothing ran, so both must count AGAINST the ceiling — the empty case must not
    /// accidentally read as "no errors, therefore productive".
    func testEmptyResults_isNonProductive() {
        XCTAssertEqual(
            ToolTurnProductivity.classify(isAskSupervisorOnly: false, toolResults: []),
            .nonProductive,
            "Every call dropped before execution advanced nothing")
    }

    /// `ask_supervisor`-only turns are counted BEFORE execution (they are auto-answered
    /// under autonomous mode, so the model can ping itself forever). Counting them again
    /// here would halve the budget, so the classifier must report them as already handled
    /// regardless of how their results came back.
    func testAskSupervisorOnly_isAlreadyCounted_whateverTheResults() {
        for results in [[ok("ask_supervisor")], [failed("ask_supervisor")], []] {
            XCTAssertEqual(
                ToolTurnProductivity.classify(isAskSupervisorOnly: true, toolResults: results),
                .alreadyCounted,
                "ask_supervisor-only is accounted for at its own site, before execution")
        }
    }

    // MARK: - Wiring pin

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
    }

    /// The file the wiring pin scans — also the resolves-pin's marker, so the marker is a
    /// file every compiling checkout carries (the public mirror ships no CLAUDE.md).
    private static let scannedPath = "NanoTeams/Services/LLM/LLMExecutionService+ToolIteration.swift"

    /// The ceiling's reset must be reachable only through the classifier.
    ///
    /// A source pin because the property is "no OTHER site zeroes the counter in the
    /// iteration", and no behavioural test can observe a site that does not exist yet.
    /// The reset used to be an unconditional `else` branch; a refactor re-introducing one
    /// would compile, pass every existing test, and silently restore the unbounded loop.
    func testIterationResetsTheCeilingOnlyThroughTheClassifier() throws {
        let path = Self.scannedPath
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)

        // Assembled at runtime so this test's own prose never matches itself.
        let resetNeedle = "consecutiveNonProductiveTurns" + " = 0"
        let resets = source.components(separatedBy: resetNeedle).count - 1
        XCTAssertEqual(resets, 1, "\(path) must zero the no-tool ceiling in exactly one place")

        XCTAssertTrue(
            source.contains("ToolTurnProductivity" + ".classify"),
            "\(path) must route that reset through the classifier, not an inline condition")
    }

    /// A broken `#filePath`→repoRoot derivation would read nothing and pass vacuously.
    func testRepoRootResolves() {
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent(Self.scannedPath).path),
            "repoRoot derivation is wrong — the wiring pin above would pass vacuously")
    }
}
