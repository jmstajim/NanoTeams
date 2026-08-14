import XCTest

@testable import NanoTeams

/// The tool-aware nudge builders in `LLMExecutionService+ToolLoopState` are pure
/// truth tables over `allowedToolNames`, and their whole reason to exist is that
/// naming a tool the role does NOT hold sends it into a `tool_not_authorized`
/// ping-pong: the error guidance says "don't retry" while the nudge says "call it".
///
/// The middle arms of both tables were unreached — `loopWarningMessage`'s
/// create_artifact fallback (a producing role with no write tools) and
/// `repetitiveNonToolNudge`'s ask_supervisor fallback (an advisory role that
/// neither produces artifacts nor is the Autovisor manager). Both describe real
/// bundled roles, so the arms are production paths, not defensive ones.
///
/// Every case asserts BOTH halves of the contract: the message names the tool the
/// role has, AND names no tool it lacks. Asserting only the first would pass for
/// an implementation that lists every candidate unconditionally — which is exactly
/// the pre-fix behavior these branches replaced.
final class NudgeToolAwarenessBranchTests: XCTestCase {

    private typealias Svc = LLMExecutionService

    /// The scratchpad spin. Was `.repetitiveTool(tool: update_scratchpad, …)` — a value
    /// `detectLoopPattern` could never construct, because the repetition counter filters
    /// `update_scratchpad` out one line before it counts. The ladder these tests pin was
    /// therefore dead, and a plan spin got no warning at all; `.repetitivePlanning` is the
    /// detection that makes the header comment above true.
    private let scratchpadLoop = LoopDetection.repetitivePlanning(count: 4)

    // MARK: - loopWarningMessage: the scratchpad-loop first-step ladder

    /// A producing role WITHOUT file-write tools (a PM / TPM shape: it submits a
    /// document, it does not edit the repo). Steering it to `edit_file` — the top
    /// rung — would name a tool the runtime rejects, on the very turn it is
    /// already stuck.
    func testScratchpadLoop_noWriteTools_steersToCreateArtifact() {
        let msg = Svc.loopWarningMessage(
            loopDetection: scratchpadLoop,
            allowedToolNames: [ToolNames.createArtifact, ToolNames.readFile])

        XCTAssertTrue(msg.contains(ToolNames.createArtifact),
                      "a producing role with no write tools must be steered to its deliverable tool; got: \(msg)")
        XCTAssertFalse(msg.contains(ToolNames.editFile),
                       "edit_file is not in this role's schema — naming it guarantees tool_not_authorized; got: \(msg)")
        XCTAssertFalse(msg.contains(ToolNames.writeFile),
                       "write_file is not in this role's schema either; got: \(msg)")
        XCTAssertTrue(msg.contains("4"),
                      "the observed repeat count is the evidence — it must survive into the message; got: \(msg)")
    }

    /// The top rung still wins when the role holds it: `edit_file` outranks
    /// `create_artifact`. Pins the ORDER, not just the membership — an
    /// implementation that checked create_artifact first would pass the test
    /// above and silently demote every engineer to "submit a document".
    func testScratchpadLoop_withEditFile_prefersEditFileOverCreateArtifact() {
        let msg = Svc.loopWarningMessage(
            loopDetection: scratchpadLoop,
            allowedToolNames: [ToolNames.editFile, ToolNames.createArtifact])

        XCTAssertTrue(msg.contains(ToolNames.editFile), "got: \(msg)")
        XCTAssertFalse(msg.contains(ToolNames.createArtifact),
                       "only ONE directive is emitted — a conditional menu is what small models mis-follow; got: \(msg)")
    }

    /// Bottom rung: an observer/read-only role gets the tool-free directive.
    func testScratchpadLoop_noActionTools_namesNoTool() {
        let msg = Svc.loopWarningMessage(
            loopDetection: scratchpadLoop,
            allowedToolNames: [ToolNames.readFile, ToolNames.search])

        XCTAssertTrue(msg.contains("Execute step 1 of your plan now."), "got: \(msg)")
        XCTAssertFalse(msg.contains(ToolNames.editFile), "got: \(msg)")
        XCTAssertFalse(msg.contains(ToolNames.createArtifact), "got: \(msg)")
        XCTAssertFalse(msg.contains(ToolNames.askSupervisor),
                       "no ask_supervisor in schema ⇒ no escalation clause; got: \(msg)")
    }

    /// The escalation clause is appended independently of the ladder rung, so it
    /// has to be pinned on a rung other than the one the existing suite covers.
    func testScratchpadLoop_createArtifactRung_stillAppendsEscalation() {
        let msg = Svc.loopWarningMessage(
            loopDetection: scratchpadLoop,
            allowedToolNames: [ToolNames.createArtifact, ToolNames.askSupervisor])

        XCTAssertTrue(msg.contains(ToolNames.createArtifact), "got: \(msg)")
        XCTAssertTrue(msg.contains("call ask_supervisor"),
                      "a role holding ask_supervisor must be told it can escalate; got: \(msg)")
    }

    /// A non-scratchpad loop takes the generic arm regardless of schema — the
    /// scratchpad ladder must not leak into it.
    /// A repeated read is not a plan spin: it must not borrow the scratchpad ladder's
    /// WORDING, which tells the role its plan is already recorded — false here, and it
    /// answers a question the role did not ask.
    ///
    /// What it may never do is name a tool the role lacks — pinned by
    /// `testReadLoop_readOnlyRole_namesNoToolItLacks`.
    func testGenericLoop_neverNamesTheScratchpadLadder() {
        let msg = Svc.loopWarningMessage(
            loopDetection: .repetitiveTool(tool: ToolNames.readFile, count: 3),
            allowedToolNames: [ToolNames.createArtifact, ToolNames.editFile])

        XCTAssertTrue(msg.hasPrefix("Loop detected:"), "got: \(msg)")
        XCTAssertFalse(msg.contains("Plan already recorded"), "got: \(msg)")
        XCTAssertFalse(msg.contains("Execute step 1"), "got: \(msg)")
    }

    // MARK: - repetitiveNonToolNudge: the action ladder

    /// The uncovered third rung: an advisory role that produces no artifact and is
    /// not the manager, but can escalate. Its ONLY completion channel is
    /// `ask_supervisor`, so telling it to "call the tool that advances your next
    /// step" (the bottom rung) would leave it with no way to finish.
    func testRepetitiveNonTool_askSupervisorOnly_steersToAskSupervisor() {
        let msg = Svc.repetitiveNonToolNudge(
            count: 3, allowedToolNames: [ToolNames.askSupervisor, ToolNames.readFile])

        XCTAssertTrue(msg.contains("send it via ask_supervisor"),
                      "an advisory role's only completion channel must be named; got: \(msg)")
        XCTAssertFalse(msg.contains(ToolNames.createArtifact), "got: \(msg)")
        XCTAssertFalse(msg.contains(ToolNames.waitForEvents), "got: \(msg)")
        XCTAssertTrue(msg.contains("3"),
                      "the repeat count is the evidence; got: \(msg)")
    }

    /// Rung order, top: create_artifact wins over ask_supervisor even though both
    /// are present — a producing role must submit, not escalate.
    func testRepetitiveNonTool_producingRole_prefersCreateArtifact() {
        let msg = Svc.repetitiveNonToolNudge(
            count: 3, allowedToolNames: [ToolNames.createArtifact, ToolNames.askSupervisor])

        XCTAssertTrue(msg.contains("call create_artifact"), "got: \(msg)")
        XCTAssertTrue(msg.contains("call ask_supervisor with a specific question"),
                      "the escalation suffix rides alongside the primary action; got: \(msg)")
    }

    /// Rung order, middle: the Autovisor manager (holds `wait_for_events`, never
    /// holds `ask_supervisor` — `resolveToolSchemas` strips it) is told to go idle.
    func testRepetitiveNonTool_manager_steersToWaitForEvents() {
        let msg = Svc.repetitiveNonToolNudge(
            count: 5, allowedToolNames: [ToolNames.waitForEvents, ToolNames.listTasks])

        XCTAssertTrue(msg.contains(ToolNames.waitForEvents), "got: \(msg)")
        XCTAssertFalse(msg.contains(ToolNames.askSupervisor),
                       "the manager provably does not hold ask_supervisor; got: \(msg)")
    }

    /// Bottom rung: nothing recognizable in the schema ⇒ no tool is named at all.
    func testRepetitiveNonTool_noRecognizedTools_namesNoTool() {
        let msg = Svc.repetitiveNonToolNudge(count: 2, allowedToolNames: [ToolNames.readFile])

        XCTAssertTrue(msg.contains("Call the tool that advances your next step."), "got: \(msg)")
        for tool in [ToolNames.createArtifact, ToolNames.waitForEvents, ToolNames.askSupervisor] {
            XCTAssertFalse(msg.contains(tool), "\(tool) is absent from the schema; got: \(msg)")
        }
    }

    /// An EMPTY schema is the degenerate input every one of these builders can
    /// receive (the planning phase narrows aggressively, and `_testHandleNoToolCalls`
    /// defaults to it). None of them may name a tool.
    func testEmptySchema_noBuilderNamesAnyTool() {
        let messages = [
            Svc.loopWarningMessage(loopDetection: scratchpadLoop, allowedToolNames: []),
            Svc.repetitiveNonToolNudge(count: 3, allowedToolNames: []),
            Svc.noToolCallNudge(allowedToolNames: []),
        ]
        let everyTool = [
            ToolNames.createArtifact, ToolNames.editFile, ToolNames.writeFile,
            ToolNames.askSupervisor, ToolNames.waitForEvents, ToolNames.updateScratchpad,
        ]
        for msg in messages {
            for tool in everyTool where tool != ToolNames.updateScratchpad {
                XCTAssertFalse(msg.contains(tool),
                               "an empty schema must yield a tool-free message; '\(tool)' leaked into: \(msg)")
            }
        }
    }
}
