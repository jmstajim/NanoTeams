import XCTest
@testable import NanoTeams

/// `meetingGuidance` — what a role reads as `{roleGuidance}` inside a MEETING turn.
///
/// A meeting turn's schema is the role's toolset minus `ToolHandlerRegistry.meetingExcluded`,
/// so a step prompt that says "submit via create_artifact" or "route fixes through
/// request_changes" is, in a meeting, an instruction about a tool the model does not
/// hold. Nine bundled roles carried one. The field is authored per role (bundled or in
/// the editor), `nil`/blank falls back to `prompt`, and every reader — runtime, wire
/// preview, fingerprint, reconcile — goes through the ONE resolver.
final class MeetingGuidanceTests: XCTestCase {

    private func role(prompt: String, meetingGuidance: String?) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "r", name: "R", prompt: prompt, meetingGuidance: meetingGuidance,
            toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies())
    }

    // MARK: - The resolver

    /// The fallback is a STANCE derived from the step prompt, never the prompt itself: the
    /// first two sentences of its opening paragraph plus the one sentence that says what a
    /// meeting turn is. Until 2026-09-07 the whole step contract reached the meeting wire.
    func testResolved_nilFallsBackToAStanceDerivedFromTheStepPrompt() {
        let prompt = """
        Implement the change end-to-end using the available tools. If no code change is required, submit Engineering Notes stating why. Third sentence.
        
        ### Workflow
        1. Make the edits; stage and commit.
        """
        let resolved = role(prompt: prompt, meetingGuidance: nil).resolvedMeetingGuidance
        XCTAssertTrue(resolved.hasPrefix("Implement the change end-to-end using the available tools. If no code change is required, submit Engineering Notes stating why."), resolved)
        XCTAssertFalse(resolved.contains("Third sentence"), "at most two sentences: \(resolved)")
        XCTAssertFalse(resolved.contains("Workflow") || resolved.contains("stage and commit"),
                       "the step workflow never reaches a meeting turn: \(resolved)")
        XCTAssertTrue(resolved.hasSuffix("not a deliverable of yours."), resolved)
    }

    func testResolved_blankFallsBackToTheDerivedStance() {
        for blank in ["", " ", "\n\t "] {
            XCTAssertEqual(role(prompt: "step", meetingGuidance: blank).resolvedMeetingGuidance,
                           SystemTemplates.meetingStance(derivedFrom: "step"),
                           "blank \(blank.debugDescription) is not authored")
        }
    }

    func testMeetingStance_emptyPrompt_isTheClosingSentenceAlone() {
        let stance = SystemTemplates.meetingStance(derivedFrom: "   ")
        XCTAssertTrue(stance.hasPrefix("In this meeting"), stance)
    }

    func testMeetingStance_headingFirstPrompt_takesNothingFromTheHeading() {
        let stance = SystemTemplates.meetingStance(derivedFrom: "### Workflow\n1. Do things.")
        XCTAssertFalse(stance.contains("Workflow"), stance)
    }

    func testResolved_authoredBodyWinsVerbatim() {
        XCTAssertEqual(role(prompt: "step", meetingGuidance: " meeting ").resolvedMeetingGuidance, " meeting ",
                       "the bytes the author wrote are the bytes the model reads")
    }

    func testResolved_templateAndDefinitionShareTheRule() {
        let template = SystemRoleTemplate(
            id: "t", name: "T", icon: "person", prompt: "step", meetingGuidance: "  ",
            toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies())
        XCTAssertEqual(template.resolvedMeetingGuidance, SystemTemplates.meetingStance(derivedFrom: "step"))
        XCTAssertEqual(SystemTemplates.resolveMeetingGuidance("m", fallback: "step"), "m")
    }

    // MARK: - The bundled bodies

    func testBundledBodies_keyOnlyExistingRolePrompts() {
        let bodies = SystemTemplates.roleMeetingGuidance
        XCTAssertGreaterThanOrEqual(bodies.count, 9, "anti-vacuum: nine bodies on 2026-09-06")
        for key in bodies.keys {
            XCTAssertNotNil(SystemTemplates.rolePrompts[key], "meeting body for unknown role `\(key)`")
        }
    }

    /// The role's stance in one or two sentences — a meeting turn is a reply, not a brief.
    func testBundledBodies_areShortAndDoNotOpenWithYouAre() {
        for (key, body) in SystemTemplates.roleMeetingGuidance {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(trimmed.isEmpty, "[\(key)] blank body would silently fall back")
            XCTAssertFalse(trimmed.hasPrefix("You are"), "[\(key)] the template owns identity")
            let sentences = trimmed.split(whereSeparator: { ".!?".contains($0) })
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            XCTAssertLessThanOrEqual(sentences.count, 2, "[\(key)] more than two sentences: \(trimmed)")
        }
    }

    /// Every meeting-capable role whose STEP prompt names a meeting-stripped tool has a
    /// meeting body; the pin that no body names one is `SystemTemplatesSectionPinTests`.
    /// Meeting-capable: a system role of a bundled team with a second participant to
    /// invite — the three single-role chat teams never hold a meeting.
    /// Every meeting-capable bundled role has an authored meeting body. Until 2026-09-07
    /// only the roles whose step prompt named a meeting-stripped tool had one, and the
    /// other nine read their whole step contract in a meeting turn (R3.1.1).
    /// Meeting-capable: a system role of a bundled team with a second participant to
    /// invite — the three single-role chat teams never hold a meeting.
    func testEveryMeetingCapableRole_hasAMeetingBody() {
        let meetingCapable = Set(Team.defaultTeams.filter { $0.nonSupervisorRoles.count >= 2 }
            .flatMap { $0.nonSupervisorRoles.compactMap(\.systemRoleID) })
        XCTAssertGreaterThanOrEqual(meetingCapable.count, 17, "anti-vacuum: 18 meeting-capable roles on 2026-09-06")
        let missing = meetingCapable.filter { SystemTemplates.roleMeetingGuidance[$0] == nil }.sorted()
        XCTAssertEqual(missing, [], "meeting-capable roles with no meeting body — they would speak under their step contract: \(missing)")
    }

    func testCreateRole_andTheHandBuiltTeammate_carryTheBundledBody() throws {
        for team in Team.defaultTeams {
            for role in team.nonSupervisorRoles {
                let key = try XCTUnwrap(role.systemRoleID, "\(team.name)/\(role.name) is a system role")
                XCTAssertEqual(role.meetingGuidance, SystemTemplates.roleMeetingGuidance[key],
                               "\(team.name)/\(role.name): the definition copies the template's body")
            }
        }
        let teammate = try XCTUnwrap(TeamTemplateFactory.empty(name: "E").nonSupervisorRoles.first)
        XCTAssertEqual(teammate.meetingGuidance, SystemTemplates.roleMeetingGuidance["teammate"])
        XCTAssertNotNil(teammate.meetingGuidance, "the hand-built Teammate is not built through createRole")
    }

    // MARK: - Persistence

    func testCodable_roundTripsTheBody_andALegacyFileDecodesAsNil() throws {
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let decoder = JSONCoderFactory.makeDateDecoder()
        let authored = role(prompt: "step", meetingGuidance: "meeting")
        let back = try decoder.decode(TeamRoleDefinition.self, from: encoder.encode(authored))
        XCTAssertEqual(back.meetingGuidance, "meeting")

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(authored)) as? [String: Any])
        json.removeValue(forKey: "meetingGuidance")
        let legacy = try decoder.decode(TeamRoleDefinition.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.meetingGuidance, "a pre-1.9.8 teams.json has no key")
        XCTAssertEqual(legacy.resolvedMeetingGuidance, SystemTemplates.meetingStance(derivedFrom: "step"))
    }

    // MARK: - The fingerprint folds it

    func testFingerprint_changesWhenOneMeetingBodyChanges() throws {
        var teams = Team.defaultTeams
        let before = BundledContentFingerprint.compute(bundled: teams)
        let i = try XCTUnwrap(teams.firstIndex { $0.templateID == "faang" })
        let r = try XCTUnwrap(teams[i].roles.firstIndex { $0.systemRoleID == "productManager" })
        teams[i].roles[r].meetingGuidance = (teams[i].roles[r].meetingGuidance ?? "") + " (edited)"
        XCTAssertNotEqual(BundledContentFingerprint.compute(bundled: teams), before,
                          "a meeting body edit that does not move the fingerprint never reaches an installed folder")
    }

    func testFingerprint_currentIsTheBundledRoster() {
        XCTAssertEqual(BundledContentFingerprint.current,
                       BundledContentFingerprint.compute(bundled: Team.defaultTeams + [TeamTemplateFactory.autovisor()]))
    }
}
