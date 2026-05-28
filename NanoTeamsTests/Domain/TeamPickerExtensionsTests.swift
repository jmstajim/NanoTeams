import XCTest
@testable import NanoTeams

/// Pins the `[Team].selectableInPicker` filter — generic list-level helper
/// that any team-consumer can reuse (currently QuickCapture; future surfaces
/// will inherit the rule without re-implementing).
@MainActor
final class TeamPickerExtensionsTests: XCTestCase {

    private func makeTeam(name: String, templateID: String? = nil) -> Team {
        var team = Team(name: name)
        team.templateID = templateID
        return team
    }

    func testSelectableInPicker_excludesGeneratedPlaceholder() {
        let teams = [
            makeTeam(name: "Coding Agent"),
            makeTeam(name: "Generated", templateID: "generated"),
            makeTeam(name: "FAANG"),
        ]
        XCTAssertEqual(teams.selectableInPicker.map(\.name), ["Coding Agent", "FAANG"])
    }

    func testSelectableInPicker_emptyList_returnsEmpty() {
        let teams: [Team] = []
        XCTAssertTrue(teams.selectableInPicker.isEmpty)
    }

    func testSelectableInPicker_onlyGenerated_returnsEmpty() {
        let teams = [makeTeam(name: "Gen", templateID: "generated")]
        XCTAssertTrue(teams.selectableInPicker.isEmpty)
    }

    /// Pins the contract that the filter excludes ONLY the canonical generated
    /// sentinel. A future "defensive tightening" like
    /// `templateID == nil || templateID == ""` would silently drop legitimate
    /// teams; this test catches that regression.
    func testSelectableInPicker_emptyStringTemplateID_isIncluded() {
        let teams = [
            makeTeam(name: "Empty", templateID: ""),
            makeTeam(name: "Generated", templateID: "generated"),
            makeTeam(name: "Nil"),
        ]
        XCTAssertEqual(teams.selectableInPicker.map(\.name), ["Empty", "Nil"])
    }

    func testSelectableInPicker_preservesOrder() {
        let teams = [
            makeTeam(name: "A"),
            makeTeam(name: "B"),
            makeTeam(name: "Skip", templateID: "generated"),
            makeTeam(name: "C"),
        ]
        XCTAssertEqual(teams.selectableInPicker.map(\.name), ["A", "B", "C"])
    }
}
