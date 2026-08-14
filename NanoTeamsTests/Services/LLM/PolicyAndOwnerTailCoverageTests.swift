import XCTest

@testable import NanoTeams

/// Wave 10 — the provider-shaped and owner-shaped tails of the LLM support layer.
///
/// Both targets here are places where a value fans out into per-case text or per-case identity,
/// and where covering only the first case leaves the second one shipping untested to the user.
final class PolicyAndOwnerTailCoverageTests: XCTestCase {

    // MARK: - ContextBudgetPolicy.truncationMessage

    /// The remedy sentence is the whole reason this banner exists. Head-truncation is silent
    /// (HTTP 200, system prompt dropped), so the user sees "the role ignored its instructions"
    /// and has no path from that symptom to the fix — which is a per-provider setting.
    ///
    /// Only the Ollama arm was exercised, which is the arm that matters least: Ollama's stock
    /// window is the one this app deliberately refuses to widen for the user, whereas an LM Studio
    /// instance loaded below its max is a one-click fix in a UI the user already has open. Both
    /// arms are asserted here so neither can degrade into the other's advice.
    ///
    /// RED: point the `.lmStudio` arm at the Ollama remedy → the LM Studio assertions fail.
    func testTruncationMessage_namesTheRemedyForBothProviders() {
        let ollama = ContextBudgetPolicy.truncationMessage(
            modelName: "ornith:35b", serverPromptTokens: 1026, provider: .ollama)
        XCTAssertTrue(ollama.contains("OLLAMA_CONTEXT_LENGTH"), "got: \(ollama)")
        XCTAssertTrue(ollama.contains("num_ctx"), "got: \(ollama)")

        let lmStudio = ContextBudgetPolicy.truncationMessage(
            modelName: "gpt-oss-20b", serverPromptTokens: 1026, provider: .lmStudio)
        XCTAssertTrue(lmStudio.contains("LM Studio"), "got: \(lmStudio)")
        XCTAssertFalse(lmStudio.contains("OLLAMA_CONTEXT_LENGTH"),
                       "an LM Studio user must not be told to set an Ollama variable")

        // Shared spine, per-provider tail: both name the model, the measured count, and the
        // truncate-from-the-START direction that makes the symptom explicable.
        for (message, model) in [(ollama, "ornith:35b"), (lmStudio, "gpt-oss-20b")] {
            XCTAssertTrue(message.contains(model), "got: \(message)")
            XCTAssertTrue(message.contains("1026"), "got: \(message)")
            XCTAssertTrue(message.contains("from the START"), "got: \(message)")
        }
    }

    // MARK: - PrefixCacheMiss.taskID

    /// `taskID` is DERIVED from the owner rather than stored, precisely so a disagreeing pair
    /// cannot be represented. The derivation has two arms and only the `.step` one was covered —
    /// yet the `nil` arm is the one carrying a behavioural claim: it is what routes a taskless
    /// caller (a judge, Vision, a meeting turn, the delegated answer) PAST the on-screen banner
    /// gate instead of onto some arbitrary task's screen.
    ///
    /// RED: return `0` instead of `nil` for a non-`.step` owner → the chain/one-shot assertions
    /// fail, and in production a one-shot judge miss would banner on whichever task is on screen.
    func testPrefixCacheMissTaskID_isNilForEveryOwnerThatHasNoTask() {
        func miss(_ owner: LLMCallOwner) -> PrefixCacheMiss {
            PrefixCacheMiss(
                owner: owner,
                runID: 1,
                modelName: "m",
                diagnosis: PrefixCachePolicy.Diagnosis(
                    cause: .systemPromptChanged,
                    commonSegments: 0,
                    previousSegments: 4,
                    discardedTokens: 4000))
        }

        XCTAssertEqual(miss(.step(taskID: 7, stepID: "engineer")).taskID, 7)
        XCTAssertNil(miss(.chain(id: "meeting:1:0:abc")).taskID,
                     "a meeting/consultation chain has no task — nil is what keeps it off the banner")
        XCTAssertNil(miss(.oneShot(label: "vision")).taskID)
    }
}
