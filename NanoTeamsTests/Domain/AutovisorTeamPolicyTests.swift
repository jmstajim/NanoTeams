import XCTest
@testable import NanoTeams

/// `AutovisorTeamPolicy` — the single authority behind which teams the Autovisor may create
/// tasks on.
///
/// Plain (nonisolated) `XCTestCase` on purpose: the `XCTAssertEqual`s on
/// `ManagedTeamResolution` below fail to COMPILE if the nested enum or its extension loses
/// its explicit `nonisolated`, because the synthesized `Hashable` would become
/// main-actor-isolated. That build failure IS the pin for the isolation markers.
final class AutovisorTeamPolicyTests: XCTestCase {

    // MARK: - Fixtures

    private func team(_ name: String, chat: Bool = false) -> Team {
        var t = TeamTemplateFactory.empty(name: name)
        if chat {
            // Chat mode ⇔ the Supervisor requires nothing back.
            for i in t.roles.indices where t.roles[i].isSupervisor {
                t.roles[i].dependencies = RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Supervisor Task"])
            }
        }
        return t
    }

    // MARK: - Block list semantics

    /// The default must be behaviourally identical to having no policy at all — this is the
    /// whole no-migration promise.
    func testEmptyBlockList_allowsEveryTeam() {
        let a = team("Alpha"), b = team("Beta")
        let policy = AutovisorTeamPolicy()
        XCTAssertEqual(policy.selectableTeams(from: [a, b]).map(\.id), [a.id, b.id])
        XCTAssertFalse(policy.hasNoSelectableTeam(in: [a, b]))
        XCTAssertTrue(policy.hasAnyUsableTarget(in: [a, b]))
        XCTAssertFalse(policy.blockingNarrowedCatalog(in: [a, b]))
    }

    func testBlockedTeam_isExcludedFromTheCatalogButOthersSurvive() {
        let a = team("Alpha"), b = team("Beta")
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [a.id])
        XCTAssertEqual(policy.selectableTeams(from: [a, b]).map(\.id), [b.id])
        XCTAssertTrue(policy.blocks(id: a.id))
        XCTAssertTrue(policy.blockingNarrowedCatalog(in: [a, b]))
    }

    func testEveryTeamBlocked_generationOff_leavesNoUsableTarget() {
        let a = team("Alpha")
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [a.id], allowGeneration: false)
        XCTAssertTrue(policy.hasNoSelectableTeam(in: [a]))
        XCTAssertFalse(policy.hasAnyUsableTarget(in: [a]))
    }

    func testEveryTeamBlocked_generationOn_stillHasATarget() {
        let a = team("Alpha")
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [a.id], allowGeneration: true)
        XCTAssertTrue(policy.hasNoSelectableTeam(in: [a]))
        XCTAssertTrue(policy.hasAnyUsableTarget(in: [a]))
    }

    /// A folder with nothing to block must NOT read as "blocking narrowed the catalog" — that
    /// predicate gates the empty-catalog note, and firing it here would change prompt bytes
    /// for a user who never touched the setting.
    func testEmptyFolder_doesNotCountAsBlockingNarrowing() {
        XCTAssertFalse(AutovisorTeamPolicy().blockingNarrowedCatalog(in: []))
        XCTAssertFalse(AutovisorTeamPolicy(blockedTeamIDs: ["ghost"]).blockingNarrowedCatalog(in: []))
    }

    // MARK: - Normalization

    func testNormalization_sortsDedupesAndDropsBlanks() {
        let policy = AutovisorTeamPolicy(blockedTeamIDs: ["beta", " alpha ", "beta", "", "   "])
        XCTAssertEqual(policy.blockedTeamIDs, ["alpha", "beta"])
    }

    /// Two orderings of the same block set must be `==`, or `mutateWorkFolder`'s structural
    /// settings diff rewrites `settings.json` on a no-op.
    func testTwoOrderingsOfTheSameBlockSet_areEqual() {
        XCTAssertEqual(AutovisorTeamPolicy(blockedTeamIDs: ["a", "b"]),
                       AutovisorTeamPolicy(blockedTeamIDs: ["b", "a"]))
    }

    // MARK: - blocks vs allows

    /// `blocks` is USER POLICY only. If it folded in `isHiddenFromPickers`, the manager naming
    /// its own team id would be told the team is "blocked" — announcing a decision the user
    /// never made.
    func testBlocksIgnoresStructuralHiding_whileAllowsHonoursIt() {
        let hidden = TeamTemplateFactory.autovisor()
        let policy = AutovisorTeamPolicy()
        XCTAssertFalse(policy.blocks(id: hidden.id), "not blocked — the user never blocked it")
        XCTAssertFalse(policy.allows(hidden), "still not selectable — it is infrastructure")
    }

    // MARK: - classify

    func testClassify_knownUnblockedTeam_resolves() {
        let a = team("Alpha")
        XCTAssertEqual(AutovisorTeamPolicy().classify(teamID: a.id, allTeams: [a], activeTeam: a),
                       .team(a.id))
    }

    func testClassify_blockedTeam_reportsBlockedByName() {
        let a = team("Alpha")
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [a.id])
        XCTAssertEqual(policy.classify(teamID: a.id, allTeams: [a], activeTeam: nil),
                       .teamBlocked("Alpha"))
    }

    /// Existence is tested BEFORE the block list, so a stale block entry for a deleted team
    /// reports `.unknown` rather than claiming the (absent) team is blocked.
    func testClassify_staleBlockedIDForADeletedTeam_isUnknownNotBlocked() {
        let policy = AutovisorTeamPolicy(blockedTeamIDs: ["ghost"])
        XCTAssertEqual(policy.classify(teamID: "ghost", allTeams: [], activeTeam: nil),
                       .unknown("ghost"))
    }

    func testClassify_sentinel_honoursTheGenerationFlagAndTolerantPadding() {
        XCTAssertEqual(AutovisorTeamPolicy().classify(teamID: "  generated  ", allTeams: [], activeTeam: nil),
                       .generated)
        XCTAssertEqual(AutovisorTeamPolicy(allowGeneration: false)
            .classify(teamID: "generated", allTeams: [], activeTeam: nil),
            .generationDisabled)
    }

    // MARK: - The omit-team_id path (the bypass this feature had to close)

    func testClassify_omitted_withAnOrdinaryActiveTeam_usesIt() {
        let a = team("Alpha")
        XCTAssertEqual(AutovisorTeamPolicy().classify(teamID: nil, allTeams: [a], activeTeam: a),
                       .useActiveTeam)
    }

    /// The bypass: before this policy existed, an omitted `team_id` skipped every eligibility
    /// check, so blocking the active team could be sidestepped by simply not naming it.
    func testClassify_omitted_withABlockedActiveTeam_refuses() {
        let a = team("Alpha")
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [a.id])
        XCTAssertEqual(policy.classify(teamID: nil, allTeams: [a], activeTeam: a),
                       .activeTeamBlocked("Alpha"))
    }

    /// Blocked beats chat: a block is explicit policy and its remedy differs — telling the
    /// manager to "pass a pipeline team_id" for a blocked chat team invites a retry that also
    /// fails.
    func testClassify_omitted_blockedChatActiveTeam_reportsBlockedNotChat() {
        let chat = team("Chatty", chat: true)
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [chat.id])
        XCTAssertEqual(policy.classify(teamID: nil, allTeams: [chat], activeTeam: chat),
                       .activeTeamBlocked("Chatty"))
    }

    func testClassify_omitted_withAHiddenActiveTeam_refuses() {
        let hidden = TeamTemplateFactory.autovisor()
        XCTAssertEqual(AutovisorTeamPolicy().classify(teamID: nil, allTeams: [hidden], activeTeam: hidden),
                       .activeTeamNotUsable,
                       "the manager must never create a managed task on infrastructure")
    }

    /// Hidden beats blocked. A blocked-AND-hidden active team must report structural
    /// unusability, not a "block": the UI cannot express a block on a hidden team (it gets no
    /// checkbox), so calling it blocked announces a decision the user never made — and puts the
    /// hidden team's NAME into a message the model reads. Same rule as `blocks` vs `allows` on
    /// the explicit-id arm.
    func testClassify_omitted_hiddenAndBlockedActiveTeam_doesNotLeakTheHiddenName() {
        let hidden = TeamTemplateFactory.autovisor()
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [hidden.id])
        let resolution = policy.classify(teamID: nil, allTeams: [hidden], activeTeam: hidden)
        XCTAssertEqual(resolution, .activeTeamNotUsable)
        let message = policy.failureMessage(for: resolution, allTeams: [hidden], omitPathIsViable: false) ?? ""
        XCTAssertFalse(message.contains(hidden.name),
                       "an infrastructure team's name must not reach the model: \(message)")
    }

    // MARK: - failureMessage

    func testFailureMessage_isNilForEverySuccessfulResolution() {
        let policy = AutovisorTeamPolicy()
        for resolution in [AutovisorTeamPolicy.ManagedTeamResolution.useActiveTeam,
                           .team("x"), .generated] {
            XCTAssertNil(policy.failureMessage(for: resolution, allTeams: [], omitPathIsViable: true))
        }
    }

    /// The remedy is DERIVED: with generation off it must not advertise `'generated'`, and
    /// with the omit path closed it must not tell the model to omit `team_id` — the two
    /// pre-existing message bugs the block list would have made worse.
    func testFailureMessage_neverAdvertisesAClosedPath() {
        let a = team("Alpha")
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [a.id], allowGeneration: false)
        let message = try! XCTUnwrap(
            policy.failureMessage(for: .teamBlocked("Alpha"), allTeams: [a], omitPathIsViable: false))
        XCTAssertFalse(message.contains("generated"), "generation is off: \(message)")
        XCTAssertFalse(message.contains("omit"), "the omit path is closed: \(message)")
        XCTAssertTrue(message.contains("Supervisor"), "nothing is open, so escalate: \(message)")
    }

    func testFailureMessage_offersEveryOpenPathWhenAllAreOpen() {
        let a = team("Alpha")
        let message = try! XCTUnwrap(AutovisorTeamPolicy()
            .failureMessage(for: .unknown("nope"), allTeams: [a], omitPathIsViable: true))
        XCTAssertTrue(message.contains("nope"), "must echo the offending id: \(message)")
        XCTAssertTrue(message.contains("catalog"))
        XCTAssertTrue(message.contains("omit team_id"))
        XCTAssertTrue(message.contains("generated"))
    }

    /// Pins the two words the existing orchestrator tests key on: the sentinel refusal says
    /// "disabled", and the unknown-id refusal must NOT (that word is the sentinel case's
    /// signature, and conflating them breaks `testUnknownNotDisabled`).
    func testFailureMessage_disabledIsTheSentinelCasesSignatureAlone() {
        let policy = AutovisorTeamPolicy(allowGeneration: false)
        let sentinel = try! XCTUnwrap(
            policy.failureMessage(for: .generationDisabled, allTeams: [], omitPathIsViable: false))
        XCTAssertTrue(sentinel.contains("disabled"))
        let unknown = try! XCTUnwrap(
            policy.failureMessage(for: .unknown("zzz"), allTeams: [], omitPathIsViable: false))
        XCTAssertFalse(unknown.contains("disabled"))
    }

    /// No Settings paths in these strings — they are model-read.
    func testFailureMessages_nameNoSettingsPane() {
        let a = team("Alpha")
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [a.id], allowGeneration: false)
        let resolutions: [AutovisorTeamPolicy.ManagedTeamResolution] = [
            .generationDisabled, .teamBlocked("Alpha"), .activeTeamBlocked("Alpha"),
            .activeTeamIsChat("Alpha"), .activeTeamNotUsable, .unknown("zzz"),
        ]
        for resolution in resolutions {
            let message = policy.failureMessage(for: resolution, allTeams: [a], omitPathIsViable: false) ?? ""
            XCTAssertFalse(message.contains("Settings"), "\(resolution): \(message)")
        }
    }

    // MARK: - Orphans

    func testOrphanBlockedIDs_areReportedNotPruned() {
        let a = team("Alpha")
        let policy = AutovisorTeamPolicy(blockedTeamIDs: [a.id, "deleted_team"])
        XCTAssertEqual(policy.orphanBlockedTeamIDs(in: [a]), ["deleted_team"])
        XCTAssertEqual(policy.blockedTeamIDs, ["alpha", "deleted_team"].sorted(),
                       "the stale id must survive — pruning a BLOCK list is fail-open")
    }
}
