import XCTest

@testable import NanoTeams

/// `DelegationInterruptionEnvelope` is `nonisolated` and pure, so this suite is a plain
/// `XCTestCase`.
final class DelegationInterruptionEnvelopeTests: XCTestCase {

    /// RED: swap `.delegationInterrupted` for `.commandFailed` → indistinguishable from the
    /// awaiter's "the child ran and failed" envelope, so the model cannot tell "read its
    /// output" from "it never ran" and the two need different next moves.
    func testEnvelope_usesTheDelegationInterruptedCode() {
        let json = DelegationInterruptionEnvelope.envelope(childTaskID: 42)
        XCTAssertTrue(json.contains(ToolErrorCode.delegationInterrupted.rawValue), json)
    }

    /// RED: return a raw string instead of going through `makeErrorEnvelope` →
    /// `LLMExecutionService.envelopeStatus` reads `.indeterminate`, and every consumer that
    /// tests `== .failure` treats a dead delegation as a non-failure.
    func testEnvelope_parsesAsAFailure() {
        let json = DelegationInterruptionEnvelope.envelope(childTaskID: 42)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return XCTFail("not JSON: \(json)") }
        XCTAssertEqual(obj["ok"] as? Bool, false)
    }

    /// RED: drop the child id from `details` → the model cannot tell WHICH of its
    /// `delegationChildIDs` died, and has no argument for a follow-up.
    func testEnvelope_namesTheChildTaskID() {
        XCTAssertTrue(DelegationInterruptionEnvelope.envelope(childTaskID: 4242).contains("4242"))
    }

    /// The closure has to be self-describing because the transcript being replayed usually does
    /// NOT contain the call it answers: the delegation await has no `persistWireTranscript` arm,
    /// so `wireTranscript` on disk predates the call or is empty.
    ///
    /// RED: emit the bare envelope as the tool message → the `[CALL]` header is gone and the
    /// result names nothing the model can locate.
    func testToolMessage_restatesTheCallItAnswers() {
        let msg = DelegationInterruptionEnvelope.toolMessage(childTaskID: 7)
        XCTAssertTrue(msg.contains("[CALL] \(ToolNames.delegateToTeam)"), msg)
        XCTAssertTrue(msg.contains("[RESULT]"), msg)
        XCTAssertTrue(msg.contains("7"), msg)
    }

    /// One wire shape, one producer. `commitCollaborationOutcome` held this as a literal until
    /// recovery became a second producer; two copies would surface as a recovery-written tool
    /// message rendering differently from every other tool message in the same feed.
    ///
    /// RED: inline the skeleton in either producer → the two stop agreeing and this fails.
    func testToolMessage_usesTheSharedComposite() {
        let expected = TaskMutationService.toolResultComposite(
            toolName: ToolNames.delegateToTeam,
            argumentsJSON: "{\"child_task_id\":7}",
            resultJSON: DelegationInterruptionEnvelope.envelope(childTaskID: 7))
        XCTAssertEqual(DelegationInterruptionEnvelope.toolMessage(childTaskID: 7), expected)
    }
}
