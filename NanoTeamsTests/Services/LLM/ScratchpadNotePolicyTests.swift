import XCTest

@testable import NanoTeams

/// `ScratchpadNotePolicy` decides what a successful `update_scratchpad` says on
/// each of two surfaces — and, for most writers, that it says nothing at all.
///
/// The subject is the SPLIT. A plain confirmation used to ship to the model on
/// every write, worded for a phase most roles do not have: the Autovisor, whose
/// scratchpad is its standing MEMORY, was told "Plan updated. Continue with the
/// next step." at exactly the point its own prompt sends it to `wait_for_events`.
/// `ScratchpadNotePolicy` is `nonisolated` value-in/value-out, so a plain
/// `XCTestCase` is correct here — no main-actor hop, no `@unchecked Sendable`.
final class ScratchpadNotePolicyTests: XCTestCase {

    // MARK: - The wire: silent except where the app declined the request

    /// The reason the whole ack could leave the wire: a plain confirmation is
    /// already in the tool's own envelope, so repeating it as an app-authored
    /// `.user` turn buys nothing and costs a turn on every write, forever.
    ///
    /// RED: return a non-nil string for `.ordinaryRole` / `.planningPhase` /
    /// `.autovisorMemory(.persisted)` → this fails, and so does
    /// `ProcessToolResultsTests.testProcessToolResults_scratchpadResult_updatesScratchpadAndSaysNothing`.
    func testWire_isSilentForEveryWriterThatGotWhatItAskedFor() {
        for writer: ScratchpadNotePolicy.Writer in [
            .ordinaryRole, .planningPhase, .autovisorMemory(.persisted),
        ] {
            XCTAssertNil(ScratchpadNotePolicy.wireMessage(for: writer),
                         "the tool envelope already confirms the write; got a turn for \(writer)")
        }
    }

    /// The one wire turn that survives. Without it the manager believes it wiped
    /// its memory, then meets the old text in its prompt next pass with nothing
    /// anywhere explaining why.
    ///
    /// RED: drop the `.clearedWithoutPersisting` arm from `wireMessage` → this fails.
    func testWire_tellsTheManagerWhenItsMemoryWasNotCleared() throws {
        let message = try XCTUnwrap(
            ScratchpadNotePolicy.wireMessage(for: .autovisorMemory(.clearedWithoutPersisting)),
            "a declined clear must reach the model — it corrects a false belief")
        XCTAssertTrue(message.contains("unchanged"),
                      "the model must learn the memory did NOT change; got: \(message)")
    }

    /// A failed write already reached both surfaces as a `.runtimeWarning` carrying
    /// the retry instruction. A second turn here would be the "two adjacent turns
    /// with opposite readings" defect this type exists to remove.
    ///
    /// RED: return a confirmation for `.writeFailed` on either surface → this fails,
    /// and so does `ToolResultSideEffectsCornerTests.testScratchpad_onAutovisorStep_persistFailure_addsNoContradictorySecondTurn`.
    func testWriteFailure_addsNothingOnEitherSurface() {
        XCTAssertNil(ScratchpadNotePolicy.wireMessage(for: .autovisorMemory(.writeFailed)))
        XCTAssertNil(ScratchpadNotePolicy.note(for: .autovisorMemory(.writeFailed)))
    }

    // MARK: - The feed: a note only where the tool card falls short

    /// The card already renders `$ update_scratchpad → ok`. For an ordinary role
    /// there is no second fact, so a note would be pure duplication.
    ///
    /// RED: return any string for `.ordinaryRole` → this fails.
    func testNote_ordinaryRole_addsNothingTheToolCardDoesNotAlreadyShow() {
        XCTAssertNil(ScratchpadNotePolicy.note(for: .ordinaryRole))
    }

    /// The write-through to `settings.autovisorMemory` is invisible to the tool
    /// handler (it runs detached and never sees the service), so the card cannot
    /// report it. That is the fact this note carries.
    ///
    /// RED: return nil for `.persisted` → this fails.
    func testNote_managerPersisted_namesTheWriteThrough() throws {
        let note = try XCTUnwrap(ScratchpadNotePolicy.note(for: .autovisorMemory(.persisted)))
        XCTAssertTrue(note.lowercased().contains("memory"),
                      "the note's whole purpose is the memory write-through; got: \(note)")
    }

    /// `contains("memory")` is satisfied by the text that NEGATES the write-through
    /// ("your standing memory is unchanged"), so on its own it cannot tell the two
    /// manager outcomes apart. This states the discriminator directly: a merge of
    /// the two cases, or a reworded `.persisted` note that reports failure, must be
    /// loud. (Exactly the trap recorded on 2026-08-13 — asserting a word rather
    /// than the word's position in the sentence's own hinge.)
    ///
    /// RED: `case .autovisorMemory(.persisted), .autovisorMemory(.clearedWithoutPersisting):
    /// return Self.memoryUnchanged` → this fails.
    func testNote_managerOutcomes_areNotInterchangeable() throws {
        let persisted = try XCTUnwrap(ScratchpadNotePolicy.note(for: .autovisorMemory(.persisted)))
        let cleared = try XCTUnwrap(
            ScratchpadNotePolicy.note(for: .autovisorMemory(.clearedWithoutPersisting)))
        XCTAssertNotEqual(persisted, cleared,
                          "a successful write and a declined clear are opposite facts")
        XCTAssertFalse(persisted.lowercased().contains("unchanged"),
                       "the success note must not report the memory as unchanged; got: \(persisted)")
        XCTAssertTrue(cleared.lowercased().contains("unchanged"),
                      "the declined clear must say the memory did NOT change; got: \(cleared)")
    }

    /// Explains why the next bubble looks like a brand-new conversation.
    ///
    /// RED: return nil for `.planningPhase` → this fails.
    func testNote_planningPhase_explainsTheFreshConversation() throws {
        let note = try XCTUnwrap(ScratchpadNotePolicy.note(for: .planningPhase))
        XCTAssertTrue(note.contains("implementation phase"), "got: \(note)")
        XCTAssertTrue(note.contains("fresh conversation"), "got: \(note)")
    }

    /// The manager sees the same sentence the model was told — the Supervisor must
    /// not have to infer what the app declined to do.
    func testNote_managerClearedWithoutPersisting_matchesTheWireVerbatim() {
        XCTAssertEqual(
            ScratchpadNotePolicy.note(for: .autovisorMemory(.clearedWithoutPersisting)),
            ScratchpadNotePolicy.wireMessage(for: .autovisorMemory(.clearedWithoutPersisting)),
            "one text, both surfaces — a divergence would leave the two readers disagreeing")
    }

    // MARK: - Vocabulary: nothing names a concept its reader does not have

    /// The reported defect, stated as a property rather than as one string.
    /// "Plan updated" named a thing the manager does not have, and
    /// "Continue with the next step" pushed against `wait_for_events` — the step
    /// its own prompt sends it to immediately after the memory write.
    ///
    /// RED: let the manager fall through to the old generic wording (or restore
    /// "Continue with the next step." to any manager text) → this fails.
    func testManagerText_neverNamesAPlanAndNeverDirectsItToContinue() {
        let outcomes: [ScratchpadNotePolicy.MemoryOutcome] =
            [.persisted, .writeFailed, .clearedWithoutPersisting]
        for outcome in outcomes {
            let texts = [
                ScratchpadNotePolicy.note(for: .autovisorMemory(outcome)),
                ScratchpadNotePolicy.wireMessage(for: .autovisorMemory(outcome)),
            ].compactMap { $0 }
            for text in texts {
                XCTAssertFalse(text.lowercased().contains("plan updated"),
                               "the manager records memory, not a plan; \(outcome) got: \(text)")
                XCTAssertFalse(text.lowercased().contains("next step"),
                               "a directive here pushes against wait_for_events; \(outcome) got: \(text)")
            }
        }
    }

    /// A transition announcement is true for exactly one writer. Telling a role
    /// with no phase that its conversation is about to be replaced describes an
    /// event that will never happen.
    ///
    /// RED: return the planning wording for any non-planning writer → this fails.
    func testTransitionWording_appearsForThePlanningWriterOnly() {
        let others: [ScratchpadNotePolicy.Writer] = [
            .ordinaryRole,
            .autovisorMemory(.persisted),
            .autovisorMemory(.writeFailed),
            .autovisorMemory(.clearedWithoutPersisting),
        ]
        for writer in others {
            let texts = [
                ScratchpadNotePolicy.note(for: writer),
                ScratchpadNotePolicy.wireMessage(for: writer),
            ].compactMap { $0 }
            for text in texts {
                XCTAssertFalse(text.contains("implementation phase"),
                               "\(writer) has no boundary to cross; got: \(text)")
            }
        }
    }

    /// Anti-vacuum: the sweeps above pass trivially if every writer returns nil.
    /// Three writers must produce SOMETHING, or those tests prove nothing.
    func testTheSweepsAboveAreNotVacuous() {
        let emitting: [ScratchpadNotePolicy.Writer] = [
            .planningPhase,
            .autovisorMemory(.persisted),
            .autovisorMemory(.clearedWithoutPersisting),
        ]
        for writer in emitting {
            let any = ScratchpadNotePolicy.note(for: writer)
                ?? ScratchpadNotePolicy.wireMessage(for: writer)
            XCTAssertNotNil(any, "\(writer) must emit on at least one surface")
        }
    }
}
