import XCTest
@testable import NanoTeams

/// Pins the pure filtering + orphan-strip rules behind the Delegation tab's
/// "Allowed Teams" list (`RoleEditorDelegationPolicy`).
///
/// Motivation: chat-mode teams are never valid delegation targets (they never
/// auto-complete), so the picker must hide them — and a chat-mode id that
/// reached a role's whitelist before it was hidden (a team converted to
/// chat-mode after being selected, or imported JSON) must be strippable, or it
/// becomes an invisible stuck entry that still flips `hasDelegationConfigured`.
final class RoleEditorDelegationPolicyTests: XCTestCase {

    // MARK: - Fixtures

    /// A team is chat-mode iff it has no Supervisor-required artifacts. A team
    /// with no Supervisor role (empty `roles`) trivially qualifies.
    private func makeChatTeam(name: String) -> Team {
        Team(name: name)  // convenience init → no roles → supervisorRequiredArtifacts empty
    }

    /// A non-chat team needs a Supervisor role requiring at least one artifact.
    private func makeProducingTeam(name: String) -> Team {
        let supervisor = TeamRoleDefinition(
            id: "\(name)-supervisor",
            name: "Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Final Deliverable"],
                producesArtifacts: [SystemTemplates.supervisorTaskArtifactName]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
        return Team(
            name: name,
            roles: [supervisor],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
    }

    // MARK: - delegatableTeams

    func testDelegatableTeams_excludesOwnTeam() {
        let own = makeProducingTeam(name: "Owner")
        let other = makeProducingTeam(name: "Other")

        let result = RoleEditorDelegationPolicy.delegatableTeams(
            allTeams: [own, other], excludingTeamID: own.id
        )

        XCTAssertEqual(result.map(\.id), [other.id], "The role's own team must never be a delegation target.")
    }

    func testDelegatableTeams_excludesChatModeTeams() {
        let chat = makeChatTeam(name: "Chat Companion")
        let producing = makeProducingTeam(name: "Engineering")
        let owner = makeProducingTeam(name: "Owner")

        let result = RoleEditorDelegationPolicy.delegatableTeams(
            allTeams: [chat, producing, owner], excludingTeamID: owner.id
        )

        XCTAssertEqual(
            result.map(\.id), [producing.id],
            "Chat-mode teams must be hidden from the picker; only non-chat, non-own teams remain."
        )
    }

    func testDelegatableTeams_sortsByNameCaseInsensitive() {
        let owner = makeProducingTeam(name: "Owner")
        let zulu = makeProducingTeam(name: "zulu")
        let alpha = makeProducingTeam(name: "Alpha")
        let mike = makeProducingTeam(name: "mike")

        let result = RoleEditorDelegationPolicy.delegatableTeams(
            allTeams: [zulu, alpha, mike, owner], excludingTeamID: owner.id
        )

        XCTAssertEqual(
            result.map(\.name), ["Alpha", "mike", "zulu"],
            "Teams must sort by name, case-insensitively, for stable rendering."
        )
    }

    func testDelegatableTeams_emptyWhenOnlyChatAndOwnRemain() {
        let owner = makeProducingTeam(name: "Owner")
        let chatA = makeChatTeam(name: "Chat A")
        let chatB = makeChatTeam(name: "Chat B")

        let result = RoleEditorDelegationPolicy.delegatableTeams(
            allTeams: [owner, chatA, chatB], excludingTeamID: owner.id
        )

        XCTAssertTrue(result.isEmpty, "With only chat-mode teams besides the owner, the list is empty.")
    }

    // MARK: - pruneNonDelegatableTeams

    func testPruneNonDelegatableTeams_removesChatModeID() {
        let chat = makeChatTeam(name: "Chat Companion")
        let producing = makeProducingTeam(name: "Engineering")

        let pruned = RoleEditorDelegationPolicy.pruneNonDelegatableTeams(
            from: [chat.id, producing.id], allTeams: [chat, producing]
        )

        XCTAssertEqual(
            pruned, [producing.id],
            "A chat-mode id in the selection must be stripped; the delegatable id is retained."
        )
    }

    func testPruneNonDelegatableTeams_removesAllChatModeIDs() {
        // Guards against a first-match-only regression: ALL non-delegatable ids
        // must be removed, not just the first one encountered.
        let chatA = makeChatTeam(name: "Chat A")
        let chatB = makeChatTeam(name: "Chat B")
        let producing = makeProducingTeam(name: "Engineering")

        let pruned = RoleEditorDelegationPolicy.pruneNonDelegatableTeams(
            from: [chatA.id, chatB.id, producing.id], allTeams: [chatA, chatB, producing]
        )

        XCTAssertEqual(
            pruned, [producing.id],
            "Every chat-mode id must be stripped, leaving only the delegatable id."
        )
    }

    func testPruneNonDelegatableTeams_noOpOnAlreadyCleanSelection() {
        let producing = makeProducingTeam(name: "Engineering")
        let other = makeProducingTeam(name: "Research")
        let selection: Set<NTMSID> = [producing.id, other.id]

        let pruned = RoleEditorDelegationPolicy.pruneNonDelegatableTeams(
            from: selection, allTeams: [producing, other]
        )

        XCTAssertEqual(pruned, selection, "A selection with no chat-mode ids is returned unchanged.")
    }

    func testPruneNonDelegatableTeams_emptyAllTeams_leavesSelectionIntact() {
        // Documents the `.task`-on-appear timing: if team data hasn't loaded
        // (`allTeams == []`), an id can't be classified, so nothing is stripped.
        // Prune must never drop what it can't prove is non-delegatable.
        let selection: Set<NTMSID> = ["some-id", "another-id"]

        let pruned = RoleEditorDelegationPolicy.pruneNonDelegatableTeams(
            from: selection, allTeams: []
        )

        XCTAssertEqual(pruned, selection, "With no team data, an unresolved selection survives unchanged.")
    }

    func testPruneNonDelegatableTeams_leavesUnknownIDsAlone() {
        // An id not present in `allTeams` is an unknown-team concern handled by
        // a separate validation surface — the delegatability prune must not touch it.
        let producing = makeProducingTeam(name: "Engineering")
        let unknown: NTMSID = "ghost-team-id"

        let pruned = RoleEditorDelegationPolicy.pruneNonDelegatableTeams(
            from: [producing.id, unknown], allTeams: [producing]
        )

        XCTAssertEqual(
            pruned, [producing.id, unknown],
            "Unknown ids are out of scope for the delegatability prune and must survive."
        )
    }
}
