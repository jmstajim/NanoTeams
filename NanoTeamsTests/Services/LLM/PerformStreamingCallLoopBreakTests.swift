import XCTest
@testable import NanoTeams

/// Integration coverage for the in-stream loop scan inside `performStreamingCall`
/// (`scanForStreamLoop`): routing by task kind, the `.thinkingOnly` (top-level) vs
/// `.thinkingAndContent` (child) scope, the break+discard wiring, and the I4
/// throttle-baseline honoring. The pure callees are covered by `LoopScannerTests`;
/// this pins the caller's wiring, which lives only in the closure.
@MainActor
final class PerformStreamingCallLoopBreakTests: XCTestCase {
    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
    }

    override func tearDown() {
        service = nil; delegate = nil
        super.tearDown()
    }

    // A 600-char thinking buffer whose 24-char phrase repeats 25× → fires the
    // within-message detector (>minRepeats) and exceeds the 400-char scan cadence.
    private func loopThinking() -> String { String(repeating: "Wait, let me reconsider.", count: 25) }
    private func cleanThinking() -> String {
        "I will read the config, validate the schema, then write the result. " +
        "Each step builds on the previous; nothing repeats pathologically here at all."
    }

    /// Builds a task (top-level or child) with one running step whose id is `stepID`,
    /// registers it, and wires it as the delegate's mutable task.
    private func setUpStep(stepID: String, taskID: Int, parentTaskID: Int? = nil, team: Team? = nil) {
        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "Step", status: .running)
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "goal", runs: [run],
            generatedTeam: team,
            parentTaskID: parentTaskID,
            parentRoleID: parentTaskID == nil ? nil : "coding_agent",
            delegationDepth: parentTaskID == nil ? 0 : 1)
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    private func stubConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://localhost", modelName: "stub", maxTokens: 100, temperature: nil)
    }

    private func run(_ events: [StreamEvent], stepID: String, taskID: Int) async throws -> LLMExecutionService.StreamingResult {
        try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: ScriptedClient(events: events), config: stubConfig(),
            tools: [], conversationMessages: [], session: nil, networkLogger: nil)
    }

    // MARK: - Top-level

    func testTopLevel_thinkingLoop_breaks_discards_doesNotCommit() async throws {
        setUpStep(stepID: "s", taskID: 1)  // top-level (parentTaskID nil)

        let result = try await run([StreamEvent(thinkingDelta: loopThinking())], stepID: "s", taskID: 1)

        XCTAssertNotNil(result.thinkingLoopSignal, "Top-level thinking loop must set thinkingLoopSignal")
        XCTAssertEqual(delegate.discardStreamingCalls.count, 1, "Looping generation must be DISCARDED")
        XCTAssertTrue(delegate.commitStreamingCalls.isEmpty, "A discarded looping turn must NOT be committed")
        // NOTE: the recording `MockLLMExecutionDelegate.beginStreaming` plants nothing,
        // so asserting `llmConversation.isEmpty` here would be tautological. The faithful
        // plant→discard orphan-removal round-trip is pinned by
        // `PausePreservesStreamingContentTests.testTopLevelThinkingLoop_discardRemovesPlantedOrphan_doesNotCommit`.
    }

    /// Real models stream small chunks — the loop accumulates across many deltas,
    /// not in one big delta. Once the combined buffer crosses the 400-char scan
    /// cadence, the accumulated repeat must be detected and broken.
    func testTopLevel_loopBuiltAcrossManySmallDeltas_breaks() async throws {
        setUpStep(stepID: "s", taskID: 1)
        let phrase = "I should reconsider this step.\n"  // 31 chars, >= minSubstringChars
        let events = Array(repeating: StreamEvent(thinkingDelta: phrase), count: 16)  // ~496 chars > cadence

        let result = try await run(events, stepID: "s", taskID: 1)

        XCTAssertNotNil(result.thinkingLoopSignal,
                        "A loop built incrementally across small deltas must still break once cadence is crossed")
        XCTAssertEqual(delegate.discardStreamingCalls.count, 1)
    }

    func testTopLevel_cleanStream_noSignal_commits() async throws {
        setUpStep(stepID: "s", taskID: 1)

        let result = try await run([
            StreamEvent(thinkingDelta: cleanThinking()),
            StreamEvent(contentDelta: "Here is the answer."),
        ], stepID: "s", taskID: 1)

        XCTAssertNil(result.thinkingLoopSignal, "Clean stream must not break")
        XCTAssertEqual(delegate.commitStreamingCalls.count, 1, "Clean stream commits normally")
        XCTAssertTrue(delegate.discardStreamingCalls.isEmpty)
    }

    /// `.thinkingOnly` scope for top-level: a loop ONLY in visible content (clean
    /// thinking) must NOT break — this is the false-positive avoidance (tables/code)
    /// the scope split exists for.
    func testTopLevel_contentLoopOnly_thinkingClean_doesNotBreak() async throws {
        setUpStep(stepID: "s", taskID: 1)
        let loopContent = String(repeating: "| col | col |\n", count: 60)  // repeats, but it's CONTENT

        let result = try await run([
            StreamEvent(thinkingDelta: cleanThinking()),
            StreamEvent(contentDelta: loopContent),
        ], stepID: "s", taskID: 1)

        XCTAssertNil(result.thinkingLoopSignal,
                     "Top-level scans thinking only — a content-only loop must not trigger the abort path")
        XCTAssertTrue(delegate.discardStreamingCalls.isEmpty)
    }

    // MARK: - Child

    func testChild_thinkingLoop_notesLoop_noBreak_commits() async throws {
        setUpStep(stepID: "s", taskID: 2, parentTaskID: 1)  // child

        let result = try await run([StreamEvent(thinkingDelta: loopThinking())], stepID: "s", taskID: 2)

        XCTAssertNil(result.thinkingLoopSignal, "Child loop must NOT break the stream (top-level-only)")
        XCTAssertGreaterThanOrEqual(delegate.noteStreamLoopCalls.count, 1,
                                    "Child loop must route to noteStreamLoop (parent interrupt)")
        XCTAssertEqual(delegate.commitStreamingCalls.count, 1, "Child stream commits (parent decides, no discard)")
        XCTAssertTrue(delegate.discardStreamingCalls.isEmpty)
    }

    /// I4: when `noteStreamLoop` returns false (no-waiter race), the in-stream
    /// throttle baseline is HELD, so subsequent growth windows re-scan and call
    /// `noteStreamLoop` again — strictly more often than when it returns true
    /// (baseline advances, skipping windows).
    func testChild_I4_falseReturnHoldsBaseline_rescansMoreThanTrue() async throws {
        // 5 sub-cadence (200-char) looping deltas: cumulative 200,400,600,800,1000.
        let delta = StreamEvent(thinkingDelta: String(repeating: "abcdefgh", count: 25))  // 200 chars, loops
        let events = Array(repeating: delta, count: 5)

        setUpStep(stepID: "hold", taskID: 3, parentTaskID: 1)
        delegate.noteStreamLoopReturn = false
        _ = try await run(events, stepID: "hold", taskID: 3)
        let heldCalls = delegate.noteStreamLoopCalls.count

        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        setUpStep(stepID: "adv", taskID: 4, parentTaskID: 1)
        delegate.noteStreamLoopReturn = true
        _ = try await run(events, stepID: "adv", taskID: 4)
        let advancedCalls = delegate.noteStreamLoopCalls.count

        XCTAssertGreaterThan(heldCalls, advancedCalls,
                             "I4: false (no waiter) holds the baseline → re-scans more (\(heldCalls)) than true → advances (\(advancedCalls))")
    }

    // MARK: - Scripted client

    private final class ScriptedClient: LLMClient, @unchecked Sendable {
        let events: [StreamEvent]
        init(events: [StreamEvent]) { self.events = events }
        func streamChat(
            config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
            session _: LLMSession?, logger _: NetworkLogger?, stepID _: String?, roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let scripted = events
            return AsyncThrowingStream { continuation in
                for event in scripted { continuation.yield(event) }
                continuation.finish()
            }
        }
        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }
}
