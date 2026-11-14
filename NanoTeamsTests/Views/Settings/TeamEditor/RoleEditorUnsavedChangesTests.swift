import XCTest
@testable import NanoTeams

/// Pins `RoleEditorState.hasUnsavedChanges(mode:)` — what the Role Editor asks before Cancel or
/// Escape closes it.
///
/// Field report (2026-11-08): Cancel was bound to Escape and dismissed with no question, so a
/// ticked tool could be thrown away by one key — while Save, the other way out, did not wait
/// for its write either. The question must fire on every field Save stores and on nothing else:
/// a no-op edit that asks trains the person to click through the dialog.
final class RoleEditorUnsavedChangesTests: XCTestCase {

    // MARK: - The field report

    /// The exact edit that was lost: one tool ticked on the Tools tab.
    func testTickingATool_isAnUnsavedChange() {
        let role = Self.storedRole()
        var draft = RoleEditorState.loaded(from: role)

        draft.selectedTools.insert(ToolNames.gitStatus)

        XCTAssertTrue(draft.hasUnsavedChanges(mode: .edit(role)))
    }

    /// Ticked and unticked again: nothing would be saved, so nothing is asked.
    func testTickingAndUntickingATool_isNoChange() {
        let role = Self.storedRole()
        var draft = RoleEditorState.loaded(from: role)

        draft.selectedTools.insert(ToolNames.gitStatus)
        draft.selectedTools.remove(ToolNames.gitStatus)

        XCTAssertFalse(draft.hasUnsavedChanges(mode: .edit(role)))
    }

    // MARK: - Clean states close without a question

    func testAnUntouchedEdit_hasNoUnsavedChanges() {
        let role = Self.storedRole()
        XCTAssertFalse(RoleEditorState.loaded(from: role).hasUnsavedChanges(mode: .edit(role)))
    }

    func testAnUntouchedNewRole_hasNoUnsavedChanges() {
        XCTAssertFalse(RoleEditorState().hasUnsavedChanges(mode: .create))
    }

    /// Switching tabs and opening the prompt preview are not edits.
    func testMovingAroundTheEditor_isNoChange() {
        let role = Self.storedRole()
        var draft = RoleEditorState.loaded(from: role)

        draft.activeSection = .tools
        draft.showingPromptPreview = true

        XCTAssertFalse(draft.hasUnsavedChanges(mode: .edit(role)))
    }

    /// A stored role whose tool list carries duplicates and an arbitrary order loads into a set;
    /// comparing the draft with the role's raw array would ask on every open.
    func testAStoredToolListInAnyOrder_isNoChange() {
        var role = Self.storedRole()
        role.toolIDs = [ToolNames.readFile, ToolNames.writeFile, ToolNames.readFile]
        role.allowedDelegationTeamIDs = ["team-b", "team-a", "team-b"]

        XCTAssertFalse(RoleEditorState.loaded(from: role).hasUnsavedChanges(mode: .edit(role)))
    }

    /// Blank meeting guidance is stored as "not authored" — the same as none — so typing only
    /// spaces into the field saves nothing (`normalizedMeetingGuidance`).
    func testWhitespaceOnlyMeetingGuidance_isNoChange() {
        let role = Self.storedRole()
        var draft = RoleEditorState.loaded(from: role)

        draft.meetingGuidance = "   \n"

        XCTAssertFalse(draft.hasUnsavedChanges(mode: .edit(role)))
    }

    // MARK: - Create mode

    func testTypingANameIntoANewRole_isAnUnsavedChange() {
        var draft = RoleEditorState()
        draft.roleName = "Reviewer"
        XCTAssertTrue(draft.hasUnsavedChanges(mode: .create))
    }

    // MARK: - Every stored field is seen

    /// Each field Save stores, changed alone, is an unsaved change.
    ///
    /// RED: drop any one field from the comparison → its row fails here.
    func testEveryStoredField_changedAlone_isAnUnsavedChange() {
        let role = Self.storedRole()
        for (field, change) in Self.storedFieldChanges {
            var draft = RoleEditorState.loaded(from: role)
            change(&draft)
            XCTAssertTrue(draft.hasUnsavedChanges(mode: .edit(role)), "a change to `\(field)` went unnoticed")
        }
    }

    /// The table above must cover every stored property of `RoleEditorState` except the two
    /// that only move the view. A new field fails here until it is either compared by
    /// `hasUnsavedChanges` (and given a row above) or declared view-only — the decision the
    /// comparison would otherwise miss in silence.
    func testEveryPropertyOfTheDraft_isClassified() {
        let labels = Set(Mirror(reflecting: RoleEditorState()).children.compactMap(\.label))
        let classified = Set(Self.storedFieldChanges.map(\.field)).union(Self.viewOnlyFields)
        XCTAssertEqual(labels, classified,
                       "unclassified: \(labels.subtracting(classified).sorted()); stale: \(classified.subtracting(labels).sorted())")
    }

    // MARK: - Fixtures

    private static let viewOnlyFields: Set<String> = ["activeSection", "showingPromptPreview"]

    private static var storedFieldChanges: [(field: String, change: (inout RoleEditorState) -> Void)] { [
        ("roleName", { $0.roleName += " II" }),
        ("roleIcon", { $0.roleIcon = "star" }),
        ("rolePrompt", { $0.rolePrompt += " More." }),
        ("meetingGuidance", { $0.meetingGuidance = "Speak briefly." }),
        ("selectedTools", { $0.selectedTools.insert(ToolNames.gitStatus) }),
        ("usePlanningPhase", { $0.usePlanningPhase.toggle() }),
        ("requiredArtifacts", { $0.requiredArtifacts.append("Design Spec") }),
        ("producedArtifacts", { $0.producedArtifacts.append("Engineering Notes") }),
        ("llmBaseURL", { $0.llmBaseURL = "http://127.0.0.1:1234" }),
        ("llmModelName", { $0.llmModelName = "qwen" }),
        ("llmProviderOverride", { $0.llmProviderOverride = .ollama }),
        ("roleIconColor", { $0.roleIconColor = "#000000" }),
        ("roleIconBackground", { $0.roleIconBackground = "#FF0000" }),
        ("selectedDelegationTeamIDs", { $0.selectedDelegationTeamIDs.insert("team-c") }),
        ("allowDelegationToGeneratedTeams", { $0.allowDelegationToGeneratedTeams.toggle() }),
        ("attachedSkillIDs", { $0.attachedSkillIDs.append("skill-x") }),
    ] }

    private static func storedRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "engineer",
            name: "Software Engineer",
            icon: "hammer",
            prompt: "Build it.",
            meetingGuidance: nil,
            toolIDs: [ToolNames.readFile, ToolNames.writeFile],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Plan"], producesArtifacts: ["Notes"]),
            llmOverride: nil,
            allowedDelegationTeamIDs: ["team-a", "team-b"],
            allowDelegationToGeneratedTeams: false,
            attachedSkillIDs: ["skill-a"],
            isSystemRole: false,
            systemRoleID: nil,
            iconColor: "#FFFFFF",
            iconBackground: "#007AFF"
        )
    }
}
