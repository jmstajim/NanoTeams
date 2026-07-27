import XCTest

@testable import NanoTeams

/// A meeting used to be the most cache-hostile thing the app did, and it got worse as the meeting
/// went on: every turn folded the whole discussion into ONE consolidated user message and re-sent
/// it, so the server re-prefilled the entire transcript on each turn. Nothing detected it either —
/// meeting turns were not registered with the prompt-prefix ledger at all.
///
/// The wire is now ordered fixed-then-growing-then-volatile, which makes a speaker's next turn an
/// APPEND onto its previous request. These measure that, rather than trusting the shape.
@MainActor
final class MeetingWireAppendOnlyTests: XCTestCase {

    // MARK: - Fixtures

    private func context(
        team: Team, participants: [Role] = [.productManager, .softwareEngineer]
    ) -> TeamMeetingService.MeetingContext {
        TeamMeetingService.MeetingContext(
            topic: "API design",
            initiatedBy: .productManager,
            participants: participants,
            additionalContext: nil,
            task: NTMSTask(id: 1, title: "T", supervisorTask: "S", runs: [Run(id: 0)]),
            availableArtifacts: [],
            artifactReader: { _ in nil },
            team: team,
            coordinatorRole: .productManager,
            limits: TeamLimits()
        )
    }

    private func meeting(turns: [(Role, String)]) -> TeamMeeting {
        var meeting = TeamMeetingService.createMeeting(
            topic: "API design", initiatedBy: .productManager,
            participants: [.productManager, .softwareEngineer], context: nil)
        for (role, text) in turns {
            meeting.addMessage(TeamMessage(
                id: UUID(), createdAt: MonotonicClock.shared.now(),
                role: role, content: text, messageType: .proposal))
        }
        return meeting
    }

    private func wire(
        speaker: Role, _ meeting: TeamMeeting, _ ctx: TeamMeetingService.MeetingContext
    ) -> [ChatMessage] {
        MeetingStreamingService.buildMeetingMessages(
            speaker: speaker, meeting: meeting, context: ctx)
    }

    // MARK: - The property

    /// The load-bearing measurement. Between two turns of the SAME speaker, everything up to the
    /// previous request's directive must be byte-identical — that is the discussion staying cached.
    func testSameSpeakerAcrossTurns_reusesEverythingBeforeTheDirective() {
        let team = TeamTemplateFactory.faang()
        let ctx = context(team: team)

        let first = wire(
            speaker: .softwareEngineer,
            meeting(turns: [(.productManager, "I propose REST.")]), ctx)
        let second = wire(
            speaker: .softwareEngineer,
            meeting(turns: [
                (.productManager, "I propose REST."),
                (.softwareEngineer, "REST is fine, but versioning matters."),
                (.productManager, "Agreed, let's version from day one."),
            ]), ctx)

        // Everything except the previous request's trailing directive survives verbatim.
        let reusable = Array(first.dropLast())
        XCTAssertEqual(
            Array(second.prefix(reusable.count)), reusable,
            "the fixed head and the already-spoken transcript must be reused byte-for-byte")
        XCTAssertGreaterThan(second.count, first.count)
    }

    /// Stated as the prefix-cache verdict it produces, since that is the thing that actually
    /// costs seconds. Divergence must be at the previous chain's LAST segment — the directive —
    /// never earlier.
    func testTheOnlyDivergenceIsTheTrailingDirective() {
        let team = TeamTemplateFactory.faang()
        let ctx = context(team: team)

        let first = wire(
            speaker: .softwareEngineer,
            meeting(turns: [(.productManager, "I propose REST.")]), ctx)
        let second = wire(
            speaker: .softwareEngineer,
            meeting(turns: [
                (.productManager, "I propose REST."),
                (.softwareEngineer, "REST is fine."),
            ]), ctx)

        let before = PromptPrefixFingerprint.chain(messages: first, toolSchemaText: "")
        let after = PromptPrefixFingerprint.chain(messages: second, toolSchemaText: "")
        let common = PromptPrefixFingerprint.commonPrefixLength(before, after)

        XCTAssertEqual(
            common, before.count - 1,
            "only the directive's slot may differ; anything earlier means the discussion is being "
                + "re-prefilled, which is the defect this shape exists to remove")
    }

    /// The pre-fix shape, for contrast — one consolidated message re-rendered per turn diverges at
    /// the FIRST user segment, i.e. the whole discussion. Keeps the test above non-vacuous by
    /// showing the measurement can distinguish the two designs.
    func testTheOldConsolidatedShapeWouldDivergeAtTheFirstUserSegment() {
        let team = TeamTemplateFactory.faang()
        let ctx = context(team: team)

        func consolidated(_ m: TeamMeeting) -> [ChatMessage] {
            var text = MeetingCoordinator.buildMeetingHeader(meeting: m, context: ctx)
            for line in m.messages {
                text += "\n" + MeetingCoordinator.buildTranscriptLine(line, context: ctx)
            }
            text += "\n" + MeetingCoordinator.buildTurnDirective(
                speaker: .softwareEngineer, meeting: m, context: ctx)
            return [
                ChatMessage(role: .system, content: "sys"),
                ChatMessage(role: .user, content: text),
            ]
        }

        let before = PromptPrefixFingerprint.chain(
            messages: consolidated(meeting(turns: [(.productManager, "I propose REST.")])),
            toolSchemaText: "")
        let after = PromptPrefixFingerprint.chain(
            messages: consolidated(meeting(turns: [
                (.productManager, "I propose REST."),
                (.softwareEngineer, "REST is fine."),
            ])),
            toolSchemaText: "")

        XCTAssertEqual(
            PromptPrefixFingerprint.commonPrefixLength(before, after), 1,
            "only the system segment survives — the entire discussion re-prefills every turn")
    }

    // MARK: - Segment 0 stability (the actual root cause)

    /// The real defect was not the consolidated user turn — it was that the speaker's SYSTEM
    /// PROMPT carried `Turn {turnNumber}` and a turn-derived `{coordinatorHint}`. Segment 0 is
    /// where the tool catalog lives, so it changed on every turn and the server re-prefilled
    /// everything. Same shape as the retired `{stepInfo}`.
    func testTheSystemPromptIsIdenticalAcrossTurns() {
        let team = TeamTemplateFactory.faang()
        let ctx = context(team: team)

        let early = wire(speaker: .softwareEngineer, meeting(turns: []), ctx).first?.content
        let mid = wire(
            speaker: .softwareEngineer,
            meeting(turns: [(.productManager, "a"), (.softwareEngineer, "b")]), ctx).first?.content
        let late = wire(
            speaker: .softwareEngineer,
            meeting(turns: (0..<8).map { (Role.productManager, "turn \($0)") }), ctx).first?.content

        XCTAssertNotNil(early)
        XCTAssertEqual(early, mid, "a turn counter in segment 0 invalidates the whole conversation")
        XCTAssertEqual(early, late)
    }

    /// Including for the COORDINATOR, whose steering hint used to escalate inside segment 0 as the
    /// meeting progressed — the worst case, since it changed at two different thresholds.
    func testTheCoordinatorsSystemPromptIsAlsoIdenticalAcrossTurns() {
        let team = TeamTemplateFactory.faang()
        let ctx = context(team: team)

        let early = wire(speaker: .productManager, meeting(turns: []), ctx).first?.content
        let late = wire(
            speaker: .productManager,
            meeting(turns: (0..<9).map { (Role.softwareEngineer, "turn \($0)") }), ctx).first?.content

        XCTAssertEqual(early, late)
    }

    /// …and the information is not lost: the counter and the steering both ride the directive now.
    func testTheDirectiveCarriesTheTurnCounterAndCoordinatorSteering() {
        let team = TeamTemplateFactory.faang()
        let ctx = context(team: team)

        let firstTurn = wire(speaker: .productManager, meeting(turns: []), ctx).last?.content ?? ""
        XCTAssertTrue(firstTurn.contains("Turn 1 of"), "the counter moved here, it did not vanish")
        XCTAssertTrue(
            firstTurn.contains("coordinator"),
            "the coordinator's early guidance moved here too")

        let lateTurn = wire(
            speaker: .productManager,
            meeting(turns: (0..<9).map { (Role.softwareEngineer, "t\($0)") }), ctx).last?.content ?? ""
        XCTAssertTrue(
            lateTurn.contains("summarize") || lateTurn.contains("steering"),
            "and so did the escalating wrap-up steering")
    }

    // MARK: - Ordering invariants that make the above true

    func testTheDirectiveIsAlwaysLast() {
        let team = TeamTemplateFactory.faang()
        let ctx = context(team: team)
        for turnCount in 0..<4 {
            let turns = (0..<turnCount).map { (Role.productManager, "turn \($0)") }
            let messages = wire(speaker: .softwareEngineer, meeting(turns: turns), ctx)
            XCTAssertTrue(
                messages.last?.content?.contains("Provide your input") ?? false,
                "turnCount \(turnCount): the volatile element must hold the recency slot")
        }
    }

    func testTheHeaderIsIdenticalAcrossTurnsAndSpeakers() {
        let team = TeamTemplateFactory.faang()
        let ctx = context(team: team)
        let early = meeting(turns: [])
        let late = meeting(turns: [(.productManager, "a"), (.softwareEngineer, "b")])

        XCTAssertEqual(
            MeetingCoordinator.buildMeetingHeader(meeting: early, context: ctx),
            MeetingCoordinator.buildMeetingHeader(meeting: late, context: ctx),
            "the header must not carry anything that changes as the meeting proceeds")
    }

    /// A speaker rotation legitimately changes segment 0 (each speaker has its own system prompt),
    /// which is why the chain key includes the speaker — comparing across speakers would
    /// manufacture a `systemPromptChanged` on every rotation.
    func testDifferentSpeakers_haveDifferentSystemPrompts() {
        let team = TeamTemplateFactory.faang()
        let ctx = context(team: team)
        let m = meeting(turns: [(.productManager, "a")])

        let pm = wire(speaker: .productManager, m, ctx).first?.content
        let swe = wire(speaker: .softwareEngineer, m, ctx).first?.content
        XCTAssertNotNil(pm)
        XCTAssertNotEqual(pm, swe)
    }

    func testTranscriptLinesAreOneMessageEach() {
        let team = TeamTemplateFactory.faang()
        let ctx = context(team: team)
        let messages = wire(
            speaker: .softwareEngineer,
            meeting(turns: [
                (.productManager, "first"), (.softwareEngineer, "second"),
                (.productManager, "third"),
            ]), ctx)

        let lines = messages.filter { $0.content?.hasPrefix("[") ?? false }
        XCTAssertEqual(lines.count, 3, "folding them back together re-arms the whole defect")
    }
}
