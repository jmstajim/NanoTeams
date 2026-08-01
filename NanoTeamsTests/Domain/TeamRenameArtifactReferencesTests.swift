import XCTest

@testable import NanoTeams

/// Corner cases for `Team.renameArtifactReferences(from:to:)` — the domain-level
/// cascade that keeps role dependencies in sync when an artifact is renamed.
///
/// This helper is the whole reason a rename is safe: an artifact's runtime
/// identity is its NAME (`RoleDependencies.requiredArtifacts` /
/// `producesArtifacts`, `artifact(withName:)`, `rolesProducing` /
/// `rolesRequiring`, `supervisorRequiredArtifacts`,
/// `TeamGraphLayoutCalculator`'s `[artifactName: roleID]`,
/// `TeamValidationService`'s name-keyed maps, and the on-disk
/// `artifact_<slug>.md` path). Nothing else in the codebase rewrites those, so
/// every degenerate input has to be pinned here rather than discovered in the
/// field.
///
/// Semantics of the whole save path live in `ArtifactEditorMutationsTests`;
/// this file pins the pure rewrite in isolation.
final class TeamRenameArtifactReferencesTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRole(
        id: String,
        requires: [String] = [],
        produces: [String] = []
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: id.capitalized,
            icon: "person",
            prompt: "p",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requires,
                producesArtifacts: produces
            )
        )
    }

    private func makeTeam(_ roles: [TeamRoleDefinition]) -> Team {
        var team = Team(name: "Cascade")
        team.roles = roles
        return team
    }

    // MARK: - No-ops

    func testRenameToSameName_isACompleteNoOp() {
        var team = makeTeam([makeRole(id: "r", requires: ["A"], produces: ["B"])])
        let before = team
        let originalUpdatedAt = team.updatedAt

        team.renameArtifactReferences(from: "A", to: "A")

        XCTAssertEqual(team.roles, before.roles)
        XCTAssertEqual(
            team.updatedAt, originalUpdatedAt,
            "A no-op rename must not bump updatedAt — that would churn SwiftUI observers and queue a pointless teams.json write."
        )
    }

    func testRenameOfUnreferencedName_doesNotBumpUpdatedAt() {
        var team = makeTeam([makeRole(id: "r", requires: ["A"], produces: ["B"])])
        let originalUpdatedAt = team.updatedAt

        team.renameArtifactReferences(from: "Nobody Uses This", to: "Still Nobody")

        XCTAssertEqual(team.roles[0].dependencies.requiredArtifacts, ["A"])
        XCTAssertEqual(team.roles[0].dependencies.producesArtifacts, ["B"])
        XCTAssertEqual(team.updatedAt, originalUpdatedAt)
    }

    func testTeamWithNoRoles_doesNotCrashOrBump() {
        var team = makeTeam([])
        let originalUpdatedAt = team.updatedAt

        team.renameArtifactReferences(from: "A", to: "B")

        XCTAssertTrue(team.roles.isEmpty)
        XCTAssertEqual(team.updatedAt, originalUpdatedAt)
    }

    func testRoleWithEmptyDependencies_isUntouched() {
        var team = makeTeam([makeRole(id: "observer")])
        let originalRoleUpdatedAt = team.roles[0].updatedAt

        team.renameArtifactReferences(from: "A", to: "B")

        XCTAssertEqual(team.roles[0].dependencies.requiredArtifacts, [])
        XCTAssertEqual(team.roles[0].dependencies.producesArtifacts, [])
        XCTAssertEqual(team.roles[0].updatedAt, originalRoleUpdatedAt)
    }

    // MARK: - Basic rewrite

    func testRewritesBothRequiredAndProduced_onTheSameRole() {
        var team = makeTeam([makeRole(id: "r", requires: ["A", "X"], produces: ["A", "Y"])])

        team.renameArtifactReferences(from: "A", to: "Z")

        XCTAssertEqual(team.roles[0].dependencies.requiredArtifacts, ["Z", "X"])
        XCTAssertEqual(team.roles[0].dependencies.producesArtifacts, ["Z", "Y"])
    }

    func testRewritesAcrossEveryRole() {
        var team = makeTeam([
            makeRole(id: "a", produces: ["Doc"]),
            makeRole(id: "b", requires: ["Doc"]),
            makeRole(id: "c", requires: ["Other"]),
        ])

        team.renameArtifactReferences(from: "Doc", to: "Document")

        XCTAssertEqual(team.roles[0].dependencies.producesArtifacts, ["Document"])
        XCTAssertEqual(team.roles[1].dependencies.requiredArtifacts, ["Document"])
        XCTAssertEqual(
            team.roles[2].dependencies.requiredArtifacts, ["Other"],
            "Roles that never named the artifact must be left alone.")
    }

    func testOnlyTouchedRolesGetTheirTimestampBumped() {
        var team = makeTeam([
            makeRole(id: "touched", produces: ["Doc"]),
            makeRole(id: "untouched", requires: ["Other"]),
        ])
        let untouchedBefore = team.roles[1].updatedAt
        let touchedBefore = team.roles[0].updatedAt

        team.renameArtifactReferences(from: "Doc", to: "Document")

        XCTAssertGreaterThan(team.roles[0].updatedAt, touchedBefore)
        XCTAssertEqual(
            team.roles[1].updatedAt, untouchedBefore,
            "An untouched role must not look edited.")
    }

    // MARK: - Order-preserving dedupe

    func testDedupe_whenNewNameAlreadyPresentAfterTheOldOne() {
        var team = makeTeam([makeRole(id: "r", requires: ["A", "B", "C"])])

        team.renameArtifactReferences(from: "A", to: "B")

        XCTAssertEqual(
            team.roles[0].dependencies.requiredArtifacts, ["B", "C"],
            "A→B where B follows: the rewritten A takes A's slot and the later B is dropped.")
    }

    func testDedupe_whenNewNameAlreadyPresentBeforeTheOldOne() {
        var team = makeTeam([makeRole(id: "r", requires: ["B", "A", "C"])])

        team.renameArtifactReferences(from: "A", to: "B")

        XCTAssertEqual(
            team.roles[0].dependencies.requiredArtifacts, ["B", "C"],
            "First occurrence wins; the rewritten duplicate is dropped.")
    }

    func testDedupe_collapsesPreExistingDuplicatesOfTheRenamedName() {
        var team = makeTeam([makeRole(id: "r", produces: ["A", "A"])])

        team.renameArtifactReferences(from: "A", to: "B")

        XCTAssertEqual(team.roles[0].dependencies.producesArtifacts, ["B"])
    }

    /// The rewrite pass only dedupes lists it actually touches. A role that
    /// never named the artifact keeps whatever it had, warts and all — this
    /// helper is a rename, not a normalizer.
    func testUnrelatedPreExistingDuplicates_areLeftAlone() {
        var team = makeTeam([makeRole(id: "r", requires: ["X", "X"])])

        team.renameArtifactReferences(from: "A", to: "B")

        XCTAssertEqual(team.roles[0].dependencies.requiredArtifacts, ["X", "X"])
    }

    func testDedupeIsPerList_notAcrossRequiredAndProduced() {
        var team = makeTeam([makeRole(id: "r", requires: ["A"], produces: ["A"])])

        team.renameArtifactReferences(from: "A", to: "B")

        XCTAssertEqual(team.roles[0].dependencies.requiredArtifacts, ["B"])
        XCTAssertEqual(
            team.roles[0].dependencies.producesArtifacts, ["B"],
            "The two lists are independent — a role legitimately requires and produces different things, and cross-list dedupe would delete one."
        )
    }

    func testOrderIsPreservedForLongLists() {
        var team = makeTeam([
            makeRole(id: "r", requires: ["one", "two", "three", "four", "five"])
        ])

        team.renameArtifactReferences(from: "three", to: "THREE")

        XCTAssertEqual(
            team.roles[0].dependencies.requiredArtifacts,
            ["one", "two", "THREE", "four", "five"],
            "Order feeds StepExecution.title and the create_artifact schema enum.")
    }

    // MARK: - Exact matching

    func testMatchingIsCaseSensitive() {
        var team = makeTeam([makeRole(id: "r", requires: ["Draft", "draft", "DRAFT"])])

        team.renameArtifactReferences(from: "Draft", to: "Outline")

        XCTAssertEqual(
            team.roles[0].dependencies.requiredArtifacts, ["Outline", "draft", "DRAFT"],
            "Team.artifact(withName:) is case-sensitive, so the cascade must be too — otherwise it would rewrite references to a DIFFERENT artifact."
        )
    }

    func testMatchingIsExact_notSubstring() {
        var team = makeTeam([
            makeRole(id: "r", requires: ["Report", "Final Report", "Report Draft"])
        ])

        team.renameArtifactReferences(from: "Report", to: "Summary")

        XCTAssertEqual(
            team.roles[0].dependencies.requiredArtifacts,
            ["Summary", "Final Report", "Report Draft"],
            "Only whole-string matches may be rewritten.")
    }

    func testWhitespaceDifferingNamesAreDistinct() {
        var team = makeTeam([makeRole(id: "r", requires: ["Report ", "Report"])])

        team.renameArtifactReferences(from: "Report", to: "Summary")

        XCTAssertEqual(team.roles[0].dependencies.requiredArtifacts, ["Report ", "Summary"])
    }

    // MARK: - Degenerate names

    func testRenamingToEmptyString_isAppliedVerbatim() {
        // The caller (`ArtifactEditorMutations`) rejects empty names before it
        // ever gets here; this pins that the primitive itself has no hidden
        // special case that could mask that guard going missing.
        var team = makeTeam([makeRole(id: "r", requires: ["A"])])

        team.renameArtifactReferences(from: "A", to: "")

        XCTAssertEqual(team.roles[0].dependencies.requiredArtifacts, [""])
    }

    func testRenamingFromEmptyString_onlyMatchesEmptyEntries() {
        var team = makeTeam([makeRole(id: "r", requires: ["", "A"])])

        team.renameArtifactReferences(from: "", to: "Recovered")

        XCTAssertEqual(team.roles[0].dependencies.requiredArtifacts, ["Recovered", "A"])
    }

    func testUnicodeAndEmojiNamesRoundTrip() {
        var team = makeTeam([makeRole(id: "r", produces: ["Отчёт 📄"])])

        team.renameArtifactReferences(from: "Отчёт 📄", to: "Итоговый отчёт ✅")

        XCTAssertEqual(team.roles[0].dependencies.producesArtifacts, ["Итоговый отчёт ✅"])
    }

    func testVeryLongNameIsHandled() {
        let long = String(repeating: "A", count: 5000)
        var team = makeTeam([makeRole(id: "r", produces: [long])])

        team.renameArtifactReferences(from: long, to: "Short")

        XCTAssertEqual(team.roles[0].dependencies.producesArtifacts, ["Short"])
    }

    // MARK: - Supervisor-derived state

    func testSupervisorRequiredArtifactsFollowTheRename() {
        var team = Team(name: "Pipeline")
        team.roles = [
            TeamRoleDefinition(
                id: "supervisor",
                name: "Supervisor",
                icon: "person",
                prompt: "",
                toolIDs: [],
                usePlanningPhase: false,
                dependencies: RoleDependencies(
                    requiredArtifacts: ["Release Notes"],
                    producesArtifacts: [SystemTemplates.supervisorTaskArtifactName]
                ),
                systemRoleID: "supervisor"
            ),
            makeRole(id: "tpm", produces: ["Release Notes"]),
        ]
        XCTAssertFalse(team.isChatMode, "precondition: pipeline team")

        team.renameArtifactReferences(from: "Release Notes", to: "Changelog")

        XCTAssertEqual(Set(team.supervisorRequiredArtifacts), ["Changelog"])
        XCTAssertFalse(
            team.isChatMode,
            "isChatMode is derived from supervisorRequiredArtifacts being EMPTY — a rename must never empty it and silently flip a pipeline team into chat mode."
        )
    }

    // MARK: - Idempotence

    func testRunningTheSameRenameTwice_isStable() {
        var team = makeTeam([makeRole(id: "r", requires: ["A"], produces: ["A"])])

        team.renameArtifactReferences(from: "A", to: "B")
        let afterFirst = team.roles
        let updatedAtAfterFirst = team.updatedAt

        team.renameArtifactReferences(from: "A", to: "B")

        XCTAssertEqual(team.roles, afterFirst)
        XCTAssertEqual(
            team.updatedAt, updatedAtAfterFirst,
            "The second pass matches nothing, so it must not bump updatedAt.")
    }
}
