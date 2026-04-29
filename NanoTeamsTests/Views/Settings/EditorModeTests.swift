import XCTest
@testable import NanoTeams

/// Pins `EditorMode<T>` `Identifiable` conformance + `isCreate` predicate. Both
/// powers `RoleEditorSheet` / `ArtifactEditorSheet` "Create" vs "Edit" titles
/// and any future `.sheet(item:)` binding.
final class EditorModeTests: XCTestCase {

    private struct Fixture: Identifiable {
        let id: String
    }

    // MARK: - id

    func testID_create_returnsCreateLiteral() {
        let mode = EditorMode<Fixture>.create
        XCTAssertEqual(mode.id, "create")
    }

    func testID_edit_returnsItemID() {
        let mode = EditorMode.edit(Fixture(id: "abc-123"))
        XCTAssertEqual(mode.id, "abc-123")
    }

    /// Documents the current contract: `.create.id` and `.edit(item).id` collide
    /// when `item.id == "create"`. Not currently a bug because no view binds
    /// `EditorMode` to `.sheet(item:)`. If that changes, namespace the edit id
    /// (e.g. `"edit:\(item.id)"`) and update this test to assert non-collision.
    func testID_create_collidesWithEditOfLiteralCreate_currentContract() {
        let create = EditorMode<Fixture>.create.id
        let editOfCreate = EditorMode.edit(Fixture(id: "create")).id
        XCTAssertEqual(create, editOfCreate,
                       "current EditorMode contract returns 'create' for both — see test docstring before changing")
    }

    // MARK: - isCreate

    func testIsCreate_create_returnsTrue() {
        XCTAssertTrue(EditorMode<Fixture>.create.isCreate)
    }

    func testIsCreate_edit_returnsFalse() {
        XCTAssertFalse(EditorMode.edit(Fixture(id: "x")).isCreate)
    }
}
