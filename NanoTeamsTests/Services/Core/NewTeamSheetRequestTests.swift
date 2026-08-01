import XCTest
@testable import NanoTeams

/// The one-shot latch that carries "open the New Team sheet" from the QuickCapture
/// NSPanel to `TeamEditorView` in the Settings window.
///
/// It is a flag on the orchestrator rather than a `NotificationCenter` post because
/// `TeamEditorView` is constructed lazily inside `SettingsView`'s tab switch — it does
/// not exist in the frame that would post, and `NotificationCenter` has no replay.
/// These tests pin the read-and-clear contract the two consume triggers depend on.
@MainActor
final class NewTeamSheetRequestTests: XCTestCase {

    var sut: NTMSOrchestrator!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        sut = TestOrchestrator.make()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func testInitially_isNotArmed() {
        XCTAssertFalse(sut.pendingNewTeamSheet)
    }

    func testRequest_armsTheLatch() {
        sut.requestNewTeamSheet()
        XCTAssertTrue(sut.pendingNewTeamSheet)
    }

    func testConsume_returnsTrueOnceThenFalse() {
        sut.requestNewTeamSheet()

        XCTAssertTrue(sut.consumeNewTeamSheetRequest())
        XCTAssertFalse(sut.consumeNewTeamSheetRequest(),
                       "One arm must yield exactly one presentation.")
    }

    func testConsume_clearsTheFlag() {
        sut.requestNewTeamSheet()
        _ = sut.consumeNewTeamSheetRequest()
        XCTAssertFalse(sut.pendingNewTeamSheet,
                       "A latch left armed re-presents the sheet on every later Teams visit.")
    }

    func testConsume_withoutArming_returnsFalse() {
        XCTAssertFalse(sut.consumeNewTeamSheetRequest())
        XCTAssertFalse(sut.pendingNewTeamSheet)
    }

    func testRequestTwice_stillConsumesOnce() {
        // Two clicks before the window mounts must not queue two sheets.
        sut.requestNewTeamSheet()
        sut.requestNewTeamSheet()

        XCTAssertTrue(sut.consumeNewTeamSheetRequest())
        XCTAssertFalse(sut.consumeNewTeamSheetRequest())
    }

    func testPeek_doesNotConsume() {
        // The consume sites PEEK first and bail while another sheet/alert is up —
        // macOS presents one per window, so consuming into a dropped presentation
        // would lose the intent with no retry path. Peeking must be side-effect free.
        sut.requestNewTeamSheet()

        XCTAssertTrue(sut.pendingNewTeamSheet)
        XCTAssertTrue(sut.pendingNewTeamSheet)
        XCTAssertTrue(sut.consumeNewTeamSheetRequest(),
                      "Reading the flag must leave it armed for the eventual consume.")
    }

    func testReArm_afterConsume_worksAgain() {
        sut.requestNewTeamSheet()
        _ = sut.consumeNewTeamSheetRequest()

        sut.requestNewTeamSheet()
        XCTAssertTrue(sut.consumeNewTeamSheetRequest())
    }
}
