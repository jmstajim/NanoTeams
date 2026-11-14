import XCTest
@testable import NanoTeams

/// `ControlActor` — who did something to a task on purpose — and the records that carry it: the
/// run's requester, the timeline event, both read back across a save.
final class ControlActorTests: XCTestCase {

    private let identity = AgentIdentity(
        id: UUID(uuidString: "dddddddd-1111-2222-3333-444444444441")!,
        label: "  Claude Code  "
    )

    func testCoding_roundTripsEveryActor_andRefusesAnUnknownKind() throws {
        for actor in [ControlActor.person, .builtInAutovisor, .externalAgent(identity)] {
            let data = try JSONEncoder().encode(actor)
            XCTAssertEqual(try JSONDecoder().decode(ControlActor.self, from: data), actor)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ControlActor.self, from: Data(#"{"kind":"robot"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ControlActor.self, from: Data(#"{"kind":"externalAgent"}"#.utf8)))
    }

    func testEcho_isOnlyTheSameExternalAgent() {
        XCTAssertTrue(ControlActor.externalAgent(identity).isExternalAgent(identity.id))
        XCTAssertFalse(ControlActor.externalAgent(identity).isExternalAgent(UUID()))
        XCTAssertFalse(ControlActor.person.isExternalAgent(identity.id))
        XCTAssertFalse(ControlActor.builtInAutovisor.isExternalAgent(identity.id))
    }

    func testAutomated_andLabels() {
        XCTAssertFalse(ControlActor.person.isAutomated)
        XCTAssertTrue(ControlActor.builtInAutovisor.isAutomated)
        XCTAssertTrue(ControlActor.externalAgent(identity).isAutomated)

        XCTAssertEqual(ControlActor.person.label, "Supervisor")
        XCTAssertEqual(ControlActor.builtInAutovisor.label, LLMMessage.automatedSupervisorLabel)
        XCTAssertEqual(ControlActor.externalAgent(identity).label, "Claude Code", "trimmed")
        XCTAssertEqual(
            ControlActor.externalAgent(AgentIdentity(label: " ")).label, ControlActor.unnamedAgentLabel,
            "a blank label still names somebody")
    }

    func testAutovisorActor_mapsToTheActorItRecords() {
        XCTAssertEqual(AutovisorActor.builtInManager.controlActor, .builtInAutovisor)
        XCTAssertEqual(AutovisorActor.externalAgent(identity, session: "s-1").controlActor, .externalAgent(identity))
    }

    /// The requester survives a save; a requester a later build names differently reads as none
    /// rather than failing the whole run, and a run written before the field has none.
    func testRunRequester_roundTrips_andDecodesLossily() throws {
        var run = Run(id: 0, steps: [], roleStatuses: [:])
        run.pauseCause = .requested
        run.pauseRequestedBy = .externalAgent(identity)
        let decoded = try JSONDecoder().decode(Run.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(decoded.pauseRequestedBy, .externalAgent(identity))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        object["pauseRequestedBy"] = ["kind": "somebodyNew"]
        let future = try JSONDecoder().decode(Run.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(future.pauseRequestedBy)
        XCTAssertEqual(future.pauseCause, .requested, "the rest of the run still reads")

        object.removeValue(forKey: "pauseRequestedBy")
        let legacy = try JSONDecoder().decode(Run.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.pauseRequestedBy)
    }

    func testTimelineEvent_signsWithItsActor_andOnlyTheAgentsAreDrawn() throws {
        let byAgent = SupervisorTimelineEvent(kind: .runPaused, by: .externalAgent(identity))
        XCTAssertEqual(byAgent.authorLabel, "Claude Code")
        XCTAssertEqual(byAgent.summaryText(), "Claude Code paused task")
        XCTAssertTrue(byAgent.isDrawnInTheFeed)
        XCTAssertEqual(SupervisorTimelineEvent(kind: .runResumed, by: .person).summaryText(), "Supervisor resumed task")
        XCTAssertFalse(SupervisorTimelineEvent(kind: .runResumed, by: .person).isDrawnInTheFeed)
        XCTAssertFalse(SupervisorTimelineEvent(kind: .runPaused, by: .builtInAutovisor).isDrawnInTheFeed)
        XCTAssertTrue(
            SupervisorTimelineEvent(kind: .taskClosed, authorLabel: "Codex").isDrawnInTheFeed,
            "an event recorded before the actor was an agent's, and stays drawn")

        let decoded = try JSONDecoder().decode(
            SupervisorTimelineEvent.self, from: JSONEncoder().encode(byAgent))
        XCTAssertEqual(decoded, byAgent)
    }
}
