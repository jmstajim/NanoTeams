import XCTest
@testable import NanoTeams

/// The Ask Supervisor card offers `Off` only where a role can still answer without
/// `ask_supervisor` — never on a chat-mode team, whose Final reminder makes that tool the
/// reply channel.
final class SupervisorModePickerLogicTests: XCTestCase {

    func testOptions_nonChatModeTeam_offersEveryMode() {
        XCTAssertEqual(SupervisorModePickerLogic.options(isChatMode: false), SupervisorMode.allCases)
    }

    func testOptions_chatModeTeam_omitsOff() {
        XCTAssertEqual(SupervisorModePickerLogic.options(isChatMode: true), [.manual, .autonomous])
        XCTAssertFalse(SupervisorModePickerLogic.isSelectable(.off, isChatMode: true))
        XCTAssertTrue(SupervisorModePickerLogic.isSelectable(.manual, isChatMode: true))
        XCTAssertTrue(SupervisorModePickerLogic.isSelectable(.off, isChatMode: false))
    }

    /// The bundled chat-mode teams are exactly the ones the picker must guard.
    func testBundledChatModeTeams_areTheOnesWithoutOff() {
        let chat = Team.defaultTeams.filter(\.isChatMode).map(\.name).sorted()
        XCTAssertFalse(chat.isEmpty, "anti-vacuum: Coding Assistant / Coding Agent / Personal Assistant are chat-mode")
        for team in Team.defaultTeams {
            XCTAssertEqual(
                SupervisorModePickerLogic.options(isChatMode: team.isChatMode).contains(.off),
                !team.isChatMode, team.name)
        }
    }
}
