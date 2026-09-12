import XCTest

@testable import NanoTeams

/// The two questionnaire fields on `StepExecution` — round trip, legacy decode, and the reset
/// paths that must forget them.
final class StepExecutionInquiryPersistenceTests: XCTestCase {

    private func makeStep() -> StepExecution {
        StepExecution.make(for: TeamRoleDefinition(
            id: "planner", name: "Planner", prompt: "", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()))
    }

    private func inquiry() -> SupervisorInquiry {
        SupervisorInquiry(headline: "Three questions", questions: [
            SupervisorInquiryQuestion(
                id: "scheme", prompt: "Which scheme?", kind: .singleChoice,
                options: [
                    SupervisorInquiryOption(id: "debug", label: "Debug"),
                    SupervisorInquiryOption(id: "release", label: "Release"),
                ]),
            SupervisorInquiryQuestion(id: "notes", prompt: "Anything else?", kind: .freeText),
        ])
    }

    private func roundTrip(_ step: StepExecution) throws -> StepExecution {
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(step)
        // `makeDateDecoder`, not `makeWireDecoder`: the persistence encoder writes ISO-8601
        // dates and the wire decoder expects epoch seconds.
        return try JSONCoderFactory.makeDateDecoder().decode(StepExecution.self, from: data)
    }

    func testInquiryAndAnswerRoundTrip() throws {
        var step = makeStep()
        step.supervisorQuestion = "Three questions"
        step.supervisorInquiry = inquiry()
        step.supervisorInquiryAnswer = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"]),
            "notes": .init(freeText: "Keep it tight."),
        ])
        let back = try roundTrip(step)
        XCTAssertEqual(back.supervisorInquiry, step.supervisorInquiry)
        XCTAssertEqual(back.supervisorInquiryAnswer, step.supervisorInquiryAnswer)
    }

    /// A partly-filled form round-trips as PARTLY filled: what was decided survives, and the
    /// question nobody answered has no entry to survive.
    ///
    /// RED: encode an entry for every asked question → a step reopened after a relaunch
    /// reports a decision on the question the Supervisor skipped.
    func testAPartlyFilledAnswerRoundTripsWithTheAbsenceIntact() throws {
        var step = makeStep()
        step.supervisorInquiry = inquiry()
        step.supervisorInquiryAnswer = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"])
        ]).decided(in: inquiry())
        let back = try roundTrip(step)
        XCTAssertEqual(
            back.supervisorInquiryAnswer?.byQuestionID["scheme"]?.selectedOptionIDs, ["debug"])
        XCTAssertNil(back.supervisorInquiryAnswer?.byQuestionID["notes"])
    }

    /// An answer where NOTHING was decided is still an answer — a Supervisor who replied
    /// entirely in prose. It must round-trip as an empty dictionary rather than as nil, or the
    /// feed loses the fact that the form was answered at all.
    func testAnAnswerWithNoDecisionsRoundTrips() throws {
        var step = makeStep()
        step.supervisorInquiry = inquiry()
        step.supervisorInquiryAnswer = SupervisorInquiryAnswer(note: "Let us talk instead.")
        let back = try roundTrip(step)
        XCTAssertEqual(back.supervisorInquiryAnswer?.byQuestionID, [:])
        XCTAssertEqual(back.supervisorInquiryAnswer?.note, "Let us talk instead.")
    }

    /// Records written before 2026-09-12 carry `wasDefaulted` on entries the app filled in
    /// from `options[0]`. The key is no longer read; the entry decodes as the ordinary
    /// selection it was stored as, and nothing throws.
    ///
    /// RED: make the key required → every archived run fails to decode and its task will not
    /// open.
    func testLegacyAnswerCarryingTheRetiredFlagStillDecodes() throws {
        var step = makeStep()
        step.supervisorInquiry = inquiry()
        step.supervisorInquiryAnswer = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"])
        ])
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(step)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var answer = try XCTUnwrap(object["supervisorInquiryAnswer"] as? [String: Any])
        var byID = try XCTUnwrap(answer["byQuestionID"] as? [String: Any])
        var entry = try XCTUnwrap(byID["scheme"] as? [String: Any])
        entry["wasDefaulted"] = true
        byID["scheme"] = entry
        answer["byQuestionID"] = byID
        object["supervisorInquiryAnswer"] = answer
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let back = try JSONCoderFactory.makeDateDecoder().decode(StepExecution.self, from: legacy)
        XCTAssertEqual(
            back.supervisorInquiryAnswer?.byQuestionID["scheme"]?.selectedOptionIDs, ["debug"])
    }

    /// Every run written before these fields existed. `decodeIfPresent` means they read as
    /// `nil`, which is exactly "this step asked a plain question" — the shape every surface
    /// already handles.
    func testLegacyStepWithoutTheFieldsDecodesAsPlain() throws {
        var step = makeStep()
        step.supervisorQuestion = "Which scheme?"
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(step)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "supervisorInquiry")
        object.removeValue(forKey: "supervisorInquiryAnswer")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let back = try JSONCoderFactory.makeDateDecoder().decode(StepExecution.self, from: legacy)
        XCTAssertEqual(back.supervisorQuestion, "Which scheme?")
        XCTAssertNil(back.supervisorInquiry)
        XCTAssertNil(back.supervisorInquiryAnswer)
    }

    /// A plain step must not grow the keys — otherwise every chat-mode turn, which is a plain
    /// `ask_supervisor`, pays two null fields in `task.json` forever.
    func testPlainStepEncodesNeitherKey() throws {
        var step = makeStep()
        step.supervisorQuestion = "Which scheme?"
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(step)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("supervisorInquiry"), json.prefix(400).description)
    }

    /// `restartRole` runs a step again from scratch. A surviving questionnaire would put the
    /// discarded attempt's card in front of the human on the new one.
    ///
    /// RED: drop either line from `reset()` → the stale form outlives the restart.
    func testResetForgetsBothFields() {
        var step = makeStep()
        step.supervisorInquiry = inquiry()
        step.supervisorInquiryAnswer = SupervisorInquiryAnswer(byQuestionID: ["a": .init()])
        step.reset()
        XCTAssertNil(step.supervisorInquiry)
        XCTAssertNil(step.supervisorInquiryAnswer)
    }
}
