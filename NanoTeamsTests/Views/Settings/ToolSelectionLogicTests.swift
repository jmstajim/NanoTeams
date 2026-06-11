import XCTest
@testable import NanoTeams

/// Pins the pure set logic behind `ToolSelectionView`'s editable-tools filtering and
/// Select-All / Clear-All. The highest-risk piece: a regression here could silently
/// strip the Autovisor manager's mandatory (locked) tools from the persisted toolset.
final class ToolSelectionLogicTests: XCTestCase {

    private let all = ["read_file", "write_file", "git_status", "list_tasks", "control_task"]

    // MARK: - editableTools

    func testEditableTools_noLockedNoRestrict_returnsAllInOrder() {
        let result = ToolSelectionLogic.editableTools(allCategoryTools: all, locked: [], restrictTo: nil)
        XCTAssertEqual(result, all, "order preserved, nothing dropped")
    }

    func testEditableTools_excludesLocked() {
        let result = ToolSelectionLogic.editableTools(
            allCategoryTools: all, locked: ["list_tasks", "control_task"], restrictTo: nil
        )
        XCTAssertEqual(result, ["read_file", "write_file", "git_status"])
    }

    func testEditableTools_honorsRestrict_andExcludesLocked() {
        // restrict allows file + git + the locked mgmt tools; locked are still removed.
        let result = ToolSelectionLogic.editableTools(
            allCategoryTools: all,
            locked: ["list_tasks", "control_task"],
            restrictTo: ["read_file", "git_status", "list_tasks", "control_task"]
        )
        XCTAssertEqual(result, ["read_file", "git_status"], "restrict applied, locked removed, write_file hidden")
    }

    // MARK: - isAllEditableSelected

    func testIsAllEditableSelected_trueWhenSupersetEvenWithLockedAlsoSelected() {
        let editable = ["read_file", "git_status"]
        let selected: Set<String> = ["read_file", "git_status", "list_tasks"]  // includes a locked tool
        XCTAssertTrue(ToolSelectionLogic.isAllEditableSelected(selected: selected, editable: editable))
    }

    func testIsAllEditableSelected_falseWhenOneMissing() {
        XCTAssertFalse(ToolSelectionLogic.isAllEditableSelected(
            selected: ["read_file"], editable: ["read_file", "git_status"]
        ))
    }

    // MARK: - toggledSelectAll

    func testToggledSelectAll_selectsAllEditable_preservingExisting() {
        let result = ToolSelectionLogic.toggledSelectAll(
            selected: ["list_tasks"], editable: ["read_file", "git_status"]
        )
        XCTAssertEqual(result, ["list_tasks", "read_file", "git_status"])
    }

    func testToggledSelectAll_clearsEditable_butKeepsLocked() {
        // All editable already selected → Clear must remove ONLY editable, keep locked.
        let result = ToolSelectionLogic.toggledSelectAll(
            selected: ["read_file", "git_status", "list_tasks", "control_task"],
            editable: ["read_file", "git_status"]
        )
        XCTAssertEqual(result, ["list_tasks", "control_task"], "locked/mandatory tools survive Clear-All")
    }
}
