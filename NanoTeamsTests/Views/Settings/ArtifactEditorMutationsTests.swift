import XCTest

@testable import NanoTeams

/// Pins the pure mutation semantics of `ArtifactEditorMutations.applyEdit` /
/// `applyCreate` — the helpers `ArtifactEditorSheet.saveArtifact` delegates to.
///
/// Motivation: the previous in-place `saveArtifact` issued FIVE separate writes
/// to the team `Binding` (name / description / icon / mimeType / updatedAt).
/// Because `TeamEditorView.binding(for:)`'s getter captures a frozen snapshot
/// and its setter replaces the whole team asynchronously, every write after the
/// first re-read the pre-edit snapshot and the LAST one won — and the last one
/// carried only `updatedAt`. Symptom: renaming an artifact appeared to do
/// nothing, and the other three fields were silently dropped with it.
///
/// The fix extracts the mutations into in-out helpers so callers can compose
/// them on a local copy and ship one Binding write. These tests pin that pure
/// shape, plus the artifact-name cascade that has no counterpart on the role
/// side (roles are id-keyed; artifacts are NAME-keyed at runtime).
final class ArtifactEditorMutationsTests: XCTestCase {

    // MARK: - Fixtures

    private func makeArtifact(
        id: String,
        name: String,
        isSystemArtifact: Bool = false,
        systemArtifactName: String? = nil
    ) -> TeamArtifact {
        TeamArtifact(
            id: id,
            name: name,
            icon: "doc.text",
            mimeType: "text/markdown",
            description: "desc for \(name)",
            isSystemArtifact: isSystemArtifact,
            systemArtifactName: systemArtifactName
        )
    }

    private func makeRole(
        id: String,
        name: String,
        requires: [String] = [],
        produces: [String] = [],
        systemRoleID: String? = nil
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: name,
            icon: "person",
            prompt: "Do the thing.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requires,
                producesArtifacts: produces
            ),
            systemRoleID: systemRoleID
        )
    }

    /// Supervisor produces "Supervisor Task", Writer produces "Draft",
    /// Reviewer requires "Draft" and produces "Report", Supervisor requires
    /// "Report" back.
    private func makePipelineTeam() -> Team {
        var team = Team(name: "Pipeline")
        team.artifacts = [
            makeArtifact(id: "supervisor_task", name: SystemTemplates.supervisorTaskArtifactName),
            makeArtifact(id: "draft", name: "Draft"),
            makeArtifact(id: "report", name: "Report"),
        ]
        team.roles = [
            makeRole(
                id: "supervisor",
                name: "Supervisor",
                requires: ["Report"],
                produces: [SystemTemplates.supervisorTaskArtifactName],
                systemRoleID: "supervisor"
            ),
            makeRole(
                id: "writer", name: "Writer",
                requires: [SystemTemplates.supervisorTaskArtifactName], produces: ["Draft"]),
            makeRole(id: "reviewer", name: "Reviewer", requires: ["Draft"], produces: ["Report"]),
        ]
        return team
    }

    private func draft(
        name: String,
        description: String = "updated description",
        icon: String = "sparkles",
        mimeType: String = "text/plain"
    ) -> ArtifactEditorMutations.Draft {
        .init(name: name, description: description, icon: icon, mimeType: mimeType)
    }

    // MARK: - The regression: all four fields land in ONE pass

    func testApplyEdit_appliesEveryEditedFieldInASinglePass() {
        var team = makePipelineTeam()

        let saved = ArtifactEditorMutations.applyEdit(
            to: &team,
            existingArtifactID: "draft",
            draft: draft(name: "Outline", description: "new desc", icon: "pencil", mimeType: "text/plain")
        )

        XCTAssertNotNil(saved)
        let stored = team.artifacts.first { $0.id == "draft" }
        XCTAssertEqual(stored?.name, "Outline")
        XCTAssertEqual(stored?.description, "new desc")
        XCTAssertEqual(stored?.icon, "pencil")
        XCTAssertEqual(stored?.mimeType, "text/plain")
    }

    // MARK: - The cascade

    func testApplyEdit_rename_cascadesToEveryRoleDependency_supervisorIncluded() {
        var team = makePipelineTeam()

        _ = ArtifactEditorMutations.applyEdit(
            to: &team, existingArtifactID: "report", draft: draft(name: "Final Report"))

        let supervisor = team.roles.first { $0.id == "supervisor" }
        let reviewer = team.roles.first { $0.id == "reviewer" }

        XCTAssertEqual(
            supervisor?.dependencies.requiredArtifacts, ["Final Report"],
            "The Supervisor must be cascaded too — supervisorRequiredArtifacts is derived from it and drives isChatMode / requiresSupervisorFinalReview."
        )
        XCTAssertEqual(reviewer?.dependencies.producesArtifacts, ["Final Report"])
        XCTAssertEqual(
            Set(team.supervisorRequiredArtifacts), ["Final Report"],
            "supervisorRequiredArtifacts is name-derived and must follow the rename.")
    }

    func testApplyEdit_rename_leavesUnrelatedDependenciesAlone() {
        var team = makePipelineTeam()

        _ = ArtifactEditorMutations.applyEdit(
            to: &team, existingArtifactID: "report", draft: draft(name: "Final Report"))

        let writer = team.roles.first { $0.id == "writer" }
        XCTAssertEqual(writer?.dependencies.producesArtifacts, ["Draft"])
        XCTAssertEqual(
            writer?.dependencies.requiredArtifacts, [SystemTemplates.supervisorTaskArtifactName])
    }

    /// Renaming `A` → `B` on a role that already lists `B` must not produce a
    /// duplicate entry: `TeamValidationService` reports that as a blocking
    /// `duplicateProducer` error naming the same role twice.
    func testApplyEdit_rename_dedupesSelfCollision_preservingOrder() {
        var team = Team(name: "Dedupe")
        team.artifacts = [
            makeArtifact(id: "a", name: "Alpha"),
            makeArtifact(id: "b", name: "Beta"),
            makeArtifact(id: "c", name: "Gamma"),
        ]
        team.roles = [
            makeRole(id: "r", name: "R", requires: ["Gamma", "Alpha", "Beta"], produces: [])
        ]
        // Delete Beta first so the rename Alpha → Beta is not a live collision.
        team.artifacts.removeAll { $0.id == "b" }

        _ = ArtifactEditorMutations.applyEdit(
            to: &team, existingArtifactID: "a", draft: draft(name: "Beta"))

        XCTAssertEqual(
            team.roles[0].dependencies.requiredArtifacts, ["Gamma", "Beta"],
            "Rewrite must dedupe while preserving first-occurrence order — order feeds StepExecution.title and the create_artifact schema enum."
        )
    }

    func testApplyEdit_nonRenameEdit_doesNotTouchDependencies() {
        var team = makePipelineTeam()
        let before = team.roles.map(\.dependencies)

        _ = ArtifactEditorMutations.applyEdit(
            to: &team, existingArtifactID: "draft",
            draft: draft(name: "Draft", description: "only the description moved"))

        XCTAssertEqual(team.roles.map(\.dependencies), before)
    }

    // MARK: - Identity and timestamps

    func testApplyEdit_keepsArtifactIDStable_acrossRename() {
        var team = makePipelineTeam()

        _ = ArtifactEditorMutations.applyEdit(
            to: &team, existingArtifactID: "draft", draft: draft(name: "Outline"))

        XCTAssertEqual(
            team.artifacts.first { $0.name == "Outline" }?.id, "draft",
            "id is the stable identity used by selection, deletion, tombstones and reconcile's already-present check — a rename is a display change, exactly as it is for roles."
        )
    }

    func testApplyEdit_bumpsTeamUpdatedAt_soObserversReRender() {
        var team = makePipelineTeam()
        let original = team.updatedAt

        _ = ArtifactEditorMutations.applyEdit(
            to: &team, existingArtifactID: "draft", draft: draft(name: "Outline"))

        XCTAssertGreaterThan(
            team.updatedAt, original,
            "team.updatedAt must bump so Team.=='s id+timestamp shortcut treats the team as changed and downstream views re-render. The old code bumped only the ARTIFACT's updatedAt."
        )
    }

    // MARK: - All-or-nothing failure contract

    func testApplyEdit_returnsNilForUnknownArtifactID_andLeavesTeamUntouched() {
        var team = makePipelineTeam()
        let before = team

        let saved = ArtifactEditorMutations.applyEdit(
            to: &team, existingArtifactID: "does_not_exist", draft: draft(name: "Whatever"))

        XCTAssertNil(saved)
        XCTAssertEqual(team.artifacts, before.artifacts)
        XCTAssertEqual(team.updatedAt, before.updatedAt)
    }

    func testApplyEdit_emptyName_isRejected_andLeavesTeamUntouched() {
        var team = makePipelineTeam()
        let before = team

        XCTAssertNil(
            ArtifactEditorMutations.applyEdit(
                to: &team, existingArtifactID: "draft", draft: draft(name: "   ")))
        XCTAssertEqual(team.artifacts, before.artifacts)
        XCTAssertEqual(team.updatedAt, before.updatedAt)
    }

    // MARK: - Trimming

    func testApplyEdit_trimsName_andCascadesTheTrimmedValue() {
        var team = makePipelineTeam()

        _ = ArtifactEditorMutations.applyEdit(
            to: &team, existingArtifactID: "report", draft: draft(name: "  Final Report  "))

        XCTAssertEqual(team.artifacts.first { $0.id == "report" }?.name, "Final Report")
        XCTAssertEqual(
            team.roles.first { $0.id == "supervisor" }?.dependencies.requiredArtifacts,
            ["Final Report"],
            "The cascade must use the canonical (trimmed) name, or the stored name and the dependency string desync."
        )
    }

    // MARK: - Name locks

    func testApplyEdit_systemArtifact_rejectsRename() {
        var team = makePipelineTeam()
        team.artifacts[1] = makeArtifact(
            id: "draft", name: "Draft", isSystemArtifact: true, systemArtifactName: "Draft")
        let before = team

        XCTAssertNil(
            ArtifactEditorMutations.applyEdit(
                to: &team, existingArtifactID: "draft", draft: draft(name: "Outline")),
            "Reconcile owns bundled artifact names — it rewrites system roles' producesArtifacts from the template on EVERY folder open and prunes orphan system artifacts BY NAME."
        )
        XCTAssertEqual(team.artifacts, before.artifacts)
    }

    func testApplyEdit_systemArtifact_stillAllowsNonNameEdits() {
        var team = makePipelineTeam()
        team.artifacts[1] = makeArtifact(
            id: "draft", name: "Draft", isSystemArtifact: true, systemArtifactName: "Draft")

        let saved = ArtifactEditorMutations.applyEdit(
            to: &team, existingArtifactID: "draft",
            draft: draft(name: "Draft", description: "clarified", icon: "pencil"))

        XCTAssertNotNil(saved, "Only the NAME is locked on a system artifact.")
        XCTAssertEqual(team.artifacts.first { $0.id == "draft" }?.description, "clarified")
        XCTAssertEqual(team.artifacts.first { $0.id == "draft" }?.icon, "pencil")
    }

    /// Keyed on the NAME, not `isSystemArtifact`: `Team.duplicate` clears that
    /// flag, so a user-created team's Supervisor Task is "custom" while still
    /// carrying the reserved name the engine injects as a literal.
    func testApplyEdit_supervisorTaskName_rejectsRename_evenWhenCustom() {
        var team = makePipelineTeam()
        XCTAssertFalse(team.artifacts[0].isSystemArtifact, "precondition: custom in this fixture")

        XCTAssertNil(
            ArtifactEditorMutations.applyEdit(
                to: &team, existingArtifactID: "supervisor_task", draft: draft(name: "Brief")))
        XCTAssertEqual(
            team.artifacts[0].name, SystemTemplates.supervisorTaskArtifactName)
    }

    func testNameLock_reportsTheRightReason() {
        XCTAssertNil(ArtifactEditorMutations.nameLock(for: makeArtifact(id: "x", name: "Custom")))
        XCTAssertEqual(
            ArtifactEditorMutations.nameLock(
                for: makeArtifact(id: "x", name: "Custom", isSystemArtifact: true)),
            .systemArtifact)
        XCTAssertEqual(
            ArtifactEditorMutations.nameLock(
                for: makeArtifact(id: "x", name: SystemTemplates.supervisorTaskArtifactName)),
            .reservedSupervisorTask)
    }

    // MARK: - Slug uniqueness

    func testApplyEdit_rejectsRenameCollidingWithAnotherArtifact() {
        var team = makePipelineTeam()
        let before = team

        XCTAssertNil(
            ArtifactEditorMutations.applyEdit(
                to: &team, existingArtifactID: "draft", draft: draft(name: "Report")))
        XCTAssertEqual(team.artifacts, before.artifacts)
    }

    /// `Artifact.slugify` mints the artifact id AND the on-disk step-artifact
    /// filename, so a case- or punctuation-only difference is a real collision
    /// even though `==` says the names differ.
    func testUniqueness_comparesSlugs_notRawNames() {
        let team = makePipelineTeam()

        XCTAssertFalse(
            ArtifactEditorMutations.isNameAvailable("report", in: team, excludingArtifactID: "draft"),
            "Case-only difference collides on slugify.")
        XCTAssertFalse(
            ArtifactEditorMutations.isNameAvailable(
                "Re-port!", in: team, excludingArtifactID: "draft"),
            "Punctuation-only difference collides on slugify.")
        XCTAssertTrue(
            ArtifactEditorMutations.isNameAvailable(
                "Report", in: team, excludingArtifactID: "report"),
            "An artifact must never collide with itself.")
    }

    /// A team can already contain two slug-colliding artifacts (nothing before
    /// this change prevented it). Editing either one's DESCRIPTION must still
    /// work — availability is only consulted on an actual rename, or the user
    /// would be locked out of fixing pre-existing bad data.
    func testApplyEdit_preExistingSlugCollision_stillAllowsNonRenameEdits() {
        var team = makePipelineTeam()
        team.artifacts.append(makeArtifact(id: "report_dupe", name: "report"))

        let saved = ArtifactEditorMutations.applyEdit(
            to: &team, existingArtifactID: "report",
            draft: draft(name: "Report", description: "clarified"))

        XCTAssertNotNil(
            saved,
            "An unchanged name must never be rejected for colliding with a pre-existing duplicate.")
        XCTAssertEqual(team.artifacts.first { $0.id == "report" }?.description, "clarified")
    }

    func testUniqueness_rejectsNameThatSlugifiesToNothing() {
        let team = makePipelineTeam()
        XCTAssertFalse(
            ArtifactEditorMutations.isNameAvailable("!!!", in: team, excludingArtifactID: nil),
            "A name with no slug-able characters would mint an empty id.")
    }

    // MARK: - Create

    func testApplyCreate_addsCustomArtifact_withSlugID() {
        var team = makePipelineTeam()

        let created = ArtifactEditorMutations.applyCreate(
            to: &team, draft: draft(name: "  Release Notes  ", description: "d", icon: "tag"))

        XCTAssertEqual(created?.name, "Release Notes")
        XCTAssertEqual(created?.id, Artifact.slugify("Release Notes"))
        XCTAssertEqual(created?.isSystemArtifact, false)
        XCTAssertNil(created?.systemArtifactName)
        XCTAssertTrue(team.artifacts.contains { $0.id == created?.id })
    }

    func testApplyCreate_rejectsSlugCollision_andLeavesTeamUntouched() {
        var team = makePipelineTeam()
        let before = team

        XCTAssertNil(
            ArtifactEditorMutations.applyCreate(to: &team, draft: draft(name: "report")),
            "Create minted the id straight from the name with no collision check, and Team.addArtifact appends unconditionally — two artifacts could share an id."
        )
        XCTAssertEqual(team.artifacts, before.artifacts)
    }

    func testApplyCreate_rejectsEmptyName() {
        var team = makePipelineTeam()
        let before = team
        XCTAssertNil(ArtifactEditorMutations.applyCreate(to: &team, draft: draft(name: " \n ")))
        XCTAssertEqual(team.artifacts, before.artifacts)
    }

    // MARK: - Property: no dangling references after a rename

    func testRenameOnRealBundledTeam_leavesNoDanglingArtifactReferences() {
        var team = TeamTemplateFactory.faang()
        // Pick a renameable (non-reserved) artifact and adopt it as custom the
        // way Duplicate does, since bundled names are locked.
        guard let index = team.artifacts.firstIndex(where: {
            $0.name != SystemTemplates.supervisorTaskArtifactName
        }) else {
            return XCTFail("FAANG should carry more than the Supervisor Task artifact")
        }
        team.artifacts[index].isSystemArtifact = false
        let target = team.artifacts[index]

        let saved = ArtifactEditorMutations.applyEdit(
            to: &team,
            existingArtifactID: target.id,
            draft: draft(name: "Renamed Deliverable", description: target.description)
        )

        XCTAssertNotNil(saved)
        assertNoDanglingArtifactReferences(team)
        XCTAssertFalse(
            team.roles.contains { role in
                role.dependencies.requiredArtifacts.contains(target.name)
                    || role.dependencies.producesArtifacts.contains(target.name)
            },
            "No role may still reference the pre-rename name."
        )
    }

    /// Shared invariant: every artifact name a role requires or produces must
    /// resolve to an artifact that exists in the team. Mirrors
    /// `EndToEndTeamCustomizationTests.testBootstrapDefaults_ArtifactsMatchRoleDependencies`,
    /// applied here AFTER a mutation rather than to pristine bundled content.
    private func assertNoDanglingArtifactReferences(
        _ team: Team, file: StaticString = #filePath, line: UInt = #line
    ) {
        let names = Set(team.artifacts.map(\.name))
        for role in team.roles {
            for required in role.dependencies.requiredArtifacts {
                XCTAssertTrue(
                    names.contains(required),
                    "Role '\(role.name)' requires missing artifact '\(required)'",
                    file: file, line: line)
            }
            for produced in role.dependencies.producesArtifacts {
                XCTAssertTrue(
                    names.contains(produced),
                    "Role '\(role.name)' produces missing artifact '\(produced)'",
                    file: file, line: line)
            }
        }
    }
}
