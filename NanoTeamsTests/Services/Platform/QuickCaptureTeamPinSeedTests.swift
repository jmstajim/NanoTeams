import XCTest
@testable import NanoTeams

/// `presentPanelSync` must seed `formState.selectedTeamID` — the form's `.onAppear`
/// is NOT sufficient.
///
/// Why this suite exists: `hide()` is `orderOut` with `isReleasedWhenClosed = false`,
/// and `presentPanelSync` rebuilds the hosting view only when the panel is new or the
/// visual mode changed. So dismissing and reopening in the same mode re-orders-in the
/// SAME SwiftUI view graph and `.onAppear` never re-fires.
///
/// That became load-bearing when the team picker's "New Team..." entry started
/// deliberately RELEASING the pin before navigating to Settings (so the picker
/// re-resolves onto the team the user is about to create). Without a seed on the show
/// path the pin stays nil: the header still renders correctly — `selectedTeam` is a
/// computed fallback — but no menu row shows a checkmark, and `createTask` forwards a
/// nil `teamID` while the UI claims a specific team.
@MainActor
final class QuickCaptureTeamPinSeedTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var controller: QuickCaptureController { QuickCaptureController.shared }

    override func setUp() {
        super.setUp()
        controller._testReset()
        controller.isTaskSelected = false
        controller._testForceNewTaskMode = false
        controller._testIsPanelVisible = false
    }

    override func tearDown() {
        controller.store = nil
        controller._testIsPanelVisible = false
        controller._testReset()
        super.tearDown()
    }

    func testPresentPanelSync_seedsPinFromActiveTeam() async {
        await sut.openWorkFolder(tempDir)
        controller.store = sut
        controller.formState.selectedTeamID = nil

        controller._testPresentPanelSync()

        XCTAssertEqual(controller.formState.selectedTeamID,
                       sut.snapshot?.workFolder.activeTeamID,
                       "A fresh show must pin the work folder's active team.")
    }

    func testPresentPanelSync_sameModeReopen_reseedsAReleasedPin() async {
        await sut.openWorkFolder(tempDir)
        controller.store = sut
        controller._testPresentPanelSync()
        XCTAssertNotNil(controller.formState.selectedTeamID)

        // What "New Team..." does before navigating away.
        controller.formState.selectedTeamID = nil
        // Same visual mode on reopen → no content rebuild → no `.onAppear`.
        controller._testIsPanelVisible = false

        controller._testPresentPanelSync()

        XCTAssertNotNil(controller.formState.selectedTeamID,
                        "The reopen path must re-seed; `.onAppear` does not run again.")
        XCTAssertEqual(controller.formState.selectedTeamID,
                       sut.snapshot?.workFolder.activeTeamID)
    }

    func testPresentPanelSync_doesNotOverwriteAnExistingPin() async {
        // The seed is a fallback, not a reset: an explicit pick (including an in-flight
        // "Generate Team..." placeholder, which lives only on the form) must survive.
        await sut.openWorkFolder(tempDir)
        controller.store = sut
        let teams = sut.snapshot?.workFolder.teams ?? []
        guard let other = teams.first(where: { $0.id != sut.snapshot?.workFolder.activeTeamID }) else {
            return XCTFail("Bootstrap must provide more than one team")
        }
        controller.formState.selectedTeamID = other.id

        controller._testPresentPanelSync()

        XCTAssertEqual(controller.formState.selectedTeamID, other.id)
    }

    func testPresentPanelSync_withNoStore_doesNotCrashAndLeavesPinNil() {
        controller.store = nil
        controller.formState.selectedTeamID = nil

        controller._testPresentPanelSync()

        XCTAssertNil(controller.formState.selectedTeamID)
    }
}
