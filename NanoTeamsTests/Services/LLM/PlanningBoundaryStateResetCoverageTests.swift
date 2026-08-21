import XCTest

@testable import NanoTeams

/// Wave 27 — the enumeration that was one field short of its own stated rule.
///
/// `resetConversationScopedState` is the planning boundary's per-step reset. Its doc comment states
/// the rule it applies: a field whose meaning is "about the conversation" cannot survive the one
/// event that REPLACES the conversation, and it names the justification for carrying
/// `didWarnContextOverflow` along — "its once-per-step latch is justified by 'the conversation
/// only grows', and the boundary is the one place that makes it shrink".
///
/// `lastServerPromptTokens` is a DELTA baseline whose entire premise is that same sentence, and
/// it was not in the list. It was inert anyway, but only by an accident in another file:
/// `PromptPrefixLedger.record` prices `appendedTokens` on the `.reused` branch alone, so the
/// boundary's own first request — a structural miss — reports 0 appended and dies on
/// `shouldReportTruncation`'s material-append gate before the stale baseline is read. That zero is
/// documented in the ledger as an optimization, not as a safety property of the detector two
/// subsystems away, which is what made it worth pinning from both ends.
@MainActor
final class PlanningBoundaryStateResetCoverageTests: XCTestCase {

    private var sut: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!

    private let stepID = "engineer"
    private let taskID = 7
    private let config = LLMConfig(
        provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "llama3.1")

    override func setUp() async throws {
        try await super.setUp()
        sut = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        sut.attach(delegate: delegate)
        sut._testRegisterStepTask(stepID: stepID, taskID: taskID)
        sut._testSetPrefixCacheState(stepID: stepID, taskID: taskID)
    }

    override func tearDown() async throws {
        sut = nil
        delegate = nil
        try await super.tearDown()
    }

    /// One request through the post-send truncation observer. The detector is a delta, so a
    /// verdict needs at least two.
    private func confirm(appended: Int, server: Int?) async {
        await sut.confirmContextTruncation(
            stepID: stepID, taskID: taskID, config: config,
            appendedTokens: appended, serverPromptTokens: server)
    }

    private var didWarn: Bool {
        sut._testDidWarnContextOverflow(stepID: stepID, taskID: taskID) == true
    }

    // MARK: - The reset itself

    /// The direct statement of the rule.
    ///
    /// RED: drop `lastServerPromptTokens = nil` from `resetConversationScopedState` → the pre-boundary
    /// count is still there afterwards.
    func testTheBoundaryClearsTheServerTokenDeltaBaseline() async {
        await confirm(appended: 0, server: 9_000)
        XCTAssertEqual(sut._testLastServerPromptTokens(stepID: stepID, taskID: taskID), 9_000,
                       "precondition: a request that reports nothing still leaves its baseline")

        sut._testResetConversationScopedState(stepID: stepID, taskID: taskID)

        XCTAssertNil(sut._testLastServerPromptTokens(stepID: stepID, taskID: taskID),
                     "the array that count described no longer exists")
    }

    /// The consequence the rule prevents. After the slice the prompt is legitimately far smaller
    /// than it was, so measuring the next request against the pre-boundary count reads as
    /// "the conversation grew but the server processed no more than last time" — the exact
    /// signature of head truncation, on a perfectly healthy request.
    ///
    /// RED: drop the reset → this warns.
    func testAfterTheBoundary_aLegitimatelySmallerPromptIsNotReportedAsTruncation() async {
        await confirm(appended: 0, server: 9_000)      // deep in the planning phase
        sut._testResetConversationScopedState(stepID: stepID, taskID: taskID)
        await confirm(appended: 3_000, server: 1_500)  // first implementation-phase request

        XCTAssertFalse(didWarn,
                       "the prompt shrank because we replaced it, not because the server dropped its head")
        XCTAssertNil(delegate.lastErrorMessages.last)
    }

    /// And the detector is not merely disarmed: the very next pair re-establishes it, so a server
    /// that really is truncating in the implementation phase is still caught. Without this the
    /// "fix" would be indistinguishable from deleting the check.
    func testTheDetectorRearmsImmediatelyAfterTheBoundary() async {
        await confirm(appended: 0, server: 9_000)
        sut._testResetConversationScopedState(stepID: stepID, taskID: taskID)
        await confirm(appended: 3_000, server: 1_500)   // rebuilds the baseline at 1_500
        await confirm(appended: 3_000, server: 1_500)   // grew again, server did not

        XCTAssertTrue(didWarn, "a real stall in the implementation phase is still reported")
        XCTAssertEqual(delegate.lastErrorMessages.last,
                       ContextBudgetPolicy.truncationMessage(
                           modelName: config.modelName, serverPromptTokens: 1_500, provider: .ollama))
    }

    // MARK: - The non-local protection that made the omission inert

    /// Why nobody ever saw the false banner: the boundary request is a structural MISS, and the
    /// ledger prices `appendedTokens` only on the reuse branch. Zero appended fails
    /// `shouldReportTruncation`'s material gate before the baseline is consulted.
    ///
    /// Pinned here rather than left implicit because it is an optimization detail in a different
    /// subsystem — pricing the tail on a miss too is a reasonable future change, and it would
    /// silently re-arm the case this file exists to close.
    ///
    /// RED: price `appended` on the miss branch of `PromptPrefixLedger.record` → this fails, and
    /// (with the reset removed) so does the boundary test above.
    func testAStructuralMissPricesNoAppendedTokens() async {
        let ledger = PromptPrefixLedger()
        let owner = LLMCallOwner.step(taskID: taskID, stepID: stepID)
        let long = String(repeating: "plan step ", count: 3_000)

        // The planning phase's last request: prefix, the brief, then the exploration.
        _ = await ledger.record(
            baseURL: config.baseURLString, model: config.modelName, owner: owner,
            messages: [ChatMessage(role: .system, content: "s"),
                       ChatMessage(role: .user, content: "task"),
                       ChatMessage(role: .user, content: "BRIEF"),
                       ChatMessage(role: .assistant, content: long)],
            toolSchemaText: "")

        // The boundary: the head is kept verbatim, everything from the brief on is replaced by
        // one seed turn carrying the recorded notes.
        let observation = await ledger.record(
            baseURL: config.baseURLString, model: config.modelName, owner: owner,
            messages: [ChatMessage(role: .system, content: "s"),
                       ChatMessage(role: .user, content: "task"),
                       ChatMessage(role: .user, content: "SEED \(long)")],
            toolSchemaText: "")

        XCTAssertNotNil(observation.structural.diagnosis, "the slice diverges at the brief")
        XCTAssertEqual(observation.appendedTokens, 0,
                       "a miss prices the discarded prefix, never the appended tail")
    }

    /// The other half of the same statement: on a reuse the tail IS priced, so the material gate
    /// is reachable at all. Without this the test above would pass against a ledger that simply
    /// never reports appended tokens.
    func testAReuseDoesPriceTheAppendedTail() async {
        let ledger = PromptPrefixLedger()
        let owner = LLMCallOwner.step(taskID: taskID, stepID: stepID)
        let long = String(repeating: "word ", count: 4_000)

        _ = await ledger.record(
            baseURL: config.baseURLString, model: config.modelName, owner: owner,
            messages: [ChatMessage(role: .system, content: "s"), ChatMessage(role: .user, content: "a")],
            toolSchemaText: "")
        let observation = await ledger.record(
            baseURL: config.baseURLString, model: config.modelName, owner: owner,
            messages: [ChatMessage(role: .system, content: "s"), ChatMessage(role: .user, content: "a"),
                       ChatMessage(role: .user, content: long)],
            toolSchemaText: "")

        XCTAssertNil(observation.structural.diagnosis, "an append is a hit")
        XCTAssertGreaterThan(observation.appendedTokens, 0)
    }

    // MARK: - The rest of the list still holds

    /// The reset is a list, and a list is the kind of thing a later edit drops one line from.
    /// Every field it clears means "about the conversation that was just replaced", so they are
    /// pinned together — a partial reset is the failure mode, not a total one.
    /// (The list deliberately shrank on 2026-08-11: `planMessageIndex` /
    /// `memoriesMessageIndex` / `memoriesVersion` left with the Memories-injection
    /// feature; the remaining fields are latches and baselines, not indices.)
    func testTheBoundaryClearsEveryConversationScopedField() async {
        // Baseline first: `confirmContextTruncation` returns on the latch, so seeding the latch
        // ahead of it would leave the field this test is here for unset for the wrong reason.
        await confirm(appended: 0, server: 9_000)
        sut._testSetPrefixCacheState(
            stepID: stepID, taskID: taskID, didWarnContextOverflow: true)

        sut._testResetConversationScopedState(stepID: stepID, taskID: taskID)

        XCTAssertFalse(didWarn)
        XCTAssertNil(sut._testLastServerPromptTokens(stepID: stepID, taskID: taskID))
    }
}
