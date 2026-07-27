import XCTest

@testable import NanoTeams

/// Structural invariant over `LLMExecutionService+StepLifecycle.runStep`: **every terminal
/// or suspend arm persists the wire transcript and the token usage together.**
///
/// A source-level pin (house pattern: `TeamActivityFeedContainerInvariantTests`) because the
/// property being protected is "no arm was forgotten", and that is a property of the SET of
/// arms — no single behavioural test can observe an arm that does not exist yet. `runStep`
/// has nine of them (two early returns, four switch cases, the iteration-limit fallthrough,
/// the cancellation catch and the generic catch), and a tenth added without the persist call
/// fails silently: the step still runs, it just resumes from the lossy display-record
/// rebuild instead of the byte-faithful transcript.
///
/// This is not hypothetical. The generic `catch` arm shipped with `persistTokenUsage` and
/// without `persistWireTranscript` — its own comment claimed it "mirrors every other
/// terminal arm" while it did not — and a change request against a step that died on a
/// permanent error re-runs it (`resetStepForRevision` acts on `.failed`, preserving the
/// conversation), so the omission was reachable.
///
/// The two calls are paired rather than counted: a count pin says "the number changed" and
/// leaves the reader to find which arm, whereas the pairing says exactly which line is
/// unaccompanied.
final class StepLifecyclePersistPairingTests: XCTestCase {

    private func lifecycleSource() throws -> [String] {
        // #filePath is this test file; the source sits at a fixed offset from the repo root,
        // which keeps the pin working regardless of where DerivedData puts the bundle.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
        let source = repoRoot
            .appendingPathComponent("NanoTeams/Services/LLM")
            .appendingPathComponent("LLMExecutionService+StepLifecycle.swift")
        return try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
    }

    func testEveryTokenUsagePersist_isImmediatelyPrecededByATranscriptPersist() throws {
        let lines = try lifecycleSource()
        var unpaired: [Int] = []

        for (index, line) in lines.enumerated() where line.contains("persistTokenUsage(") {
            let previous = index > 0 ? lines[index - 1] : ""
            if !previous.contains("persistWireTranscript(") {
                unpaired.append(index + 1)
            }
        }

        XCTAssertTrue(
            unpaired.isEmpty,
            "line(s) \(unpaired) persist token usage without persisting the wire transcript "
                + "first. Every terminal/suspend arm must do both: the transcript is what "
                + "ConversationReplay replays on re-entry, and an arm that skips it silently "
                + "degrades that step to the lossy display-record rebuild. Add "
                + "`await self.persistWireTranscript(stepID:taskID:messages: conversation)` "
                + "immediately above.")
    }

    /// The other direction, so the pairing cannot be satisfied by deleting a token-usage
    /// call instead of adding a transcript call.
    func testEveryTranscriptPersist_isImmediatelyFollowedByATokenUsagePersist() throws {
        let lines = try lifecycleSource()
        var unpaired: [Int] = []

        for (index, line) in lines.enumerated() where line.contains("persistWireTranscript(") {
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            if !next.contains("persistTokenUsage(") {
                unpaired.append(index + 1)
            }
        }

        XCTAssertTrue(
            unpaired.isEmpty,
            "line(s) \(unpaired) persist the wire transcript without persisting token usage "
                + "next — the two are terminal-arm bookkeeping and travel together")
    }

    /// Guards the pin itself: if `runStep` is refactored so these calls move behind a helper,
    /// both loops above would scan zero lines and pass vacuously. Asserting a floor makes
    /// that refactor fail here, where the invariant is documented, rather than silently.
    func testThePinIsNotVacuous() throws {
        let lines = try lifecycleSource()
        let transcripts = lines.filter { $0.contains("persistWireTranscript(") }.count
        XCTAssertGreaterThanOrEqual(
            transcripts, 9,
            "runStep is expected to have at least 9 terminal/suspend arms, each persisting "
                + "the transcript. Far fewer means the calls moved behind a helper and this "
                + "pin no longer sees them — re-point it at the new seam rather than deleting it.")
    }
}
