import XCTest
@testable import NanoTeams

/// Pins `TeamActivityTimelineItem.artifact` ID composition: the id MUST include
/// `stepID` so that two roles in the SAME task producing artifacts with the SAME
/// name (e.g. a generated team where Quality Controller mistakenly recreates the
/// Frontend Developer's `index.html` artifact) get distinct timeline IDs.
///
/// Regression: tasks/8/subtasks/9 — Both roles (`Frontend Developer` and
/// `Quality Controller`) emitted `create_artifact("index.html", …)`. Pre-fix
/// `id = "art-{taskID}-{slug(name)}"` collided across roles → SwiftUI's
/// `ForEach` diff engine deduplicated the second occurrence → second role's
/// artifact cards never rendered, leaving the visible "large empty gaps" the
/// user reported. Post-fix `id = "art-{taskID}-{stepID}-{slug(name)}"`
/// disambiguates by producing role.
final class TimelineArtifactIDCollisionTests: XCTestCase {

    /// Builds an artifact with a realistic `relativePath` matching the shape the
    /// persistence layer emits: `tasks/{taskID}/runs/{runID}/roles/{roleID}/artifact_<slug>.md`
    /// (or the nested-subtask variant for delegated children). The timeline `id`
    /// is derived from this path, so the test fixtures must mirror production
    /// shape — pre-fix the tests passed `relativePath: "art_<name>.md"` which would
    /// produce SAME-path collisions across different roles in the same task.
    private func makeArtifact(
        name: String, taskID: Int, runID: Int = 0, roleID: String,
        ancestors: [Int] = []
    ) -> Artifact {
        let slug = Artifact.slugify(name)
        var path = "tasks/\(taskID)"
        for childID in ancestors {
            path += "/subtasks/\(childID)"
        }
        path += "/runs/\(runID)/roles/\(roleID)/artifact_\(slug).md"
        return Artifact(name: name, mimeType: "text/markdown", relativePath: path)
    }

    func testTwoRolesSameNamedArtifact_distinctTimelineIDs() {
        let frontendArtifact = makeArtifact(name: "index.html", taskID: 9, roleID: "frontend_developer_step")
        let qcArtifact = makeArtifact(name: "index.html", taskID: 9, roleID: "quality_controller_step")
        let frontendItem = TeamActivityTimelineItem.artifact(
            artifact: frontendArtifact,
            role: .softwareEngineer,
            stepID: "frontend_developer_step",
            originTaskID: 9
        )
        let qcItem = TeamActivityTimelineItem.artifact(
            artifact: qcArtifact,
            role: .codeReviewer,
            stepID: "quality_controller_step",
            originTaskID: 9
        )
        XCTAssertNotEqual(
            frontendItem.id, qcItem.id,
            "Same artifact name in same task but different roles MUST produce distinct timeline IDs (relativePath includes the role directory so paths differ)"
        )
    }

    func testSameRoleSameArtifactName_sameID_idempotent() {
        // Idempotency: persistence layer can re-emit the same artifact (re-run /
        // restart) and the timeline must still produce a stable id so SwiftUI
        // animations don't churn unnecessarily.
        let artifact = makeArtifact(name: "Code Review", taskID: 5, roleID: "code_reviewer_step")
        let a = TeamActivityTimelineItem.artifact(
            artifact: artifact, role: .codeReviewer,
            stepID: "code_reviewer_step", originTaskID: 5
        )
        let b = TeamActivityTimelineItem.artifact(
            artifact: artifact, role: .codeReviewer,
            stepID: "code_reviewer_step", originTaskID: 5
        )
        XCTAssertEqual(a.id, b.id)
    }

    func testCrossTaskSameRoleSameName_distinctIDs() {
        // Pre-existing guarantee: parent + child task each producing "Engineering Notes"
        // get different ids — the relativePath contains taskID, so cross-task paths differ.
        let parentArtifact = makeArtifact(name: "Engineering Notes", taskID: 1, roleID: "engineer_step")
        let childArtifact = makeArtifact(name: "Engineering Notes", taskID: 2, roleID: "engineer_step")
        let parent = TeamActivityTimelineItem.artifact(
            artifact: parentArtifact, role: .softwareEngineer,
            stepID: "engineer_step", originTaskID: 1
        )
        let child = TeamActivityTimelineItem.artifact(
            artifact: childArtifact, role: .softwareEngineer,
            stepID: "engineer_step", originTaskID: 2
        )
        XCTAssertNotEqual(parent.id, child.id)
    }

    /// Fallback path: when an artifact has not yet been persisted (transient — between
    /// in-memory creation and disk write), `relativePath` is nil. The fallback id
    /// must remain collision-free across stepIDs in the same task.
    func testTransientArtifactsWithoutRelativePath_distinctIDsByStepID() {
        let artifact = Artifact(name: "Notes", mimeType: "text/markdown", relativePath: nil)
        let a = TeamActivityTimelineItem.artifact(
            artifact: artifact, role: .softwareEngineer,
            stepID: "step_a", originTaskID: 1
        )
        let b = TeamActivityTimelineItem.artifact(
            artifact: artifact, role: .codeReviewer,
            stepID: "step_b", originTaskID: 1
        )
        XCTAssertNotEqual(
            a.id, b.id,
            "Transient artifacts (nil relativePath) must still collision-resolve via taskID + stepID fallback"
        )
    }

    // MARK: - pathWithinTask helper

    func testPathWithinTask_rootTask_stripsTasksPrefix() {
        let p = TeamActivityTimelineItem.pathWithinTask(
            relativePath: "tasks/9/runs/0/roles/frontend_step/artifact_index_html.md",
            taskID: 9
        )
        XCTAssertEqual(p, "runs/0/roles/frontend_step/artifact_index_html.md")
    }

    func testPathWithinTask_nestedChildTask_stripsSubtasksPrefix() {
        // For child task 6 nested under parent 5, calling with taskID=6 returns
        // the path beneath the child's own root.
        let p = TeamActivityTimelineItem.pathWithinTask(
            relativePath: "tasks/5/subtasks/6/runs/0/roles/X/artifact_Y.md",
            taskID: 6
        )
        XCTAssertEqual(p, "runs/0/roles/X/artifact_Y.md")
    }

    func testPathWithinTask_parentInNestedPath_includesSubtaskNavigation() {
        // For parent task 5 in a nested chain, calling with taskID=5 returns the
        // path beneath the parent — which includes the `subtasks/6/...` navigation.
        let p = TeamActivityTimelineItem.pathWithinTask(
            relativePath: "tasks/5/subtasks/6/runs/0/roles/X/artifact_Y.md",
            taskID: 5
        )
        XCTAssertEqual(p, "subtasks/6/runs/0/roles/X/artifact_Y.md")
    }

    func testPathWithinTask_nilRelativePath_returnsNil() {
        XCTAssertNil(TeamActivityTimelineItem.pathWithinTask(relativePath: nil, taskID: 1))
    }

    func testPathWithinTask_taskIDNotInPath_returnsNil() {
        XCTAssertNil(TeamActivityTimelineItem.pathWithinTask(
            relativePath: "tasks/9/runs/0/roles/X/artifact_Y.md",
            taskID: 99
        ))
    }
}
