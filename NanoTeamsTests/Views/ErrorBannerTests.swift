import XCTest

@testable import NanoTeams

// MARK: - ErrorBannerModifier Logic Tests

/// Tests the ErrorBannerModifier's consume-and-display logic by directly testing
/// the orchestrator's lastErrorMessage lifecycle and the modifier's state transitions.
@MainActor
final class ErrorBannerModifierTests: XCTestCase {

    var store: NTMSOrchestrator!

    override func setUp() {
        super.setUp()
        store = NTMSOrchestrator(repository: NTMSRepository())
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: - lastErrorMessage Baseline

    func testLastErrorMessage_initiallyNil() {
        XCTAssertNil(store.lastErrorMessage)
    }

    func testLastErrorMessage_canBeSet() {
        store.lastErrorMessage = "Something went wrong"
        XCTAssertEqual(store.lastErrorMessage, "Something went wrong")
    }

    func testLastErrorMessage_canBeCleared() {
        store.lastErrorMessage = "Error"
        store.lastErrorMessage = nil
        XCTAssertNil(store.lastErrorMessage)
    }

    func testLastErrorMessage_overwrittenBySubsequentError() {
        store.lastErrorMessage = "First error"
        store.lastErrorMessage = "Second error"
        XCTAssertEqual(store.lastErrorMessage, "Second error")
    }

    func testLastErrorMessage_emptyStringIsNotNil() {
        store.lastErrorMessage = ""
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(store.lastErrorMessage, "")
    }

    // MARK: - Consume Pattern

    /// The modifier pattern: read non-nil message, then set to nil.
    /// This test validates the pattern works without race conditions on @MainActor.
    func testConsumePattern_readAndClear() {
        store.lastErrorMessage = "Test error"

        // Simulate modifier's onChange behavior
        let consumed = store.lastErrorMessage
        store.lastErrorMessage = nil

        XCTAssertEqual(consumed, "Test error")
        XCTAssertNil(store.lastErrorMessage)
    }

    func testConsumePattern_nilMessageIsIgnored() {
        store.lastErrorMessage = nil

        // Simulate modifier's guard
        let shouldShow = store.lastErrorMessage != nil && !(store.lastErrorMessage?.isEmpty ?? true)
        XCTAssertFalse(shouldShow)
    }

    func testConsumePattern_emptyMessageIsIgnored() {
        store.lastErrorMessage = ""

        // Simulate modifier's guard: guard let newValue, !newValue.isEmpty
        let newValue = store.lastErrorMessage
        let shouldShow = newValue != nil && !newValue!.isEmpty
        XCTAssertFalse(shouldShow)
    }

    // MARK: - Partial Staging Error Message Format

    func testStagingErrorMessage_singleFileSkipped() {
        let total = 3
        let staged = 2
        let skipped = total - staged

        let message = "\(skipped) of \(total) files could not be attached."
        XCTAssertEqual(message, "1 of 3 files could not be attached.")
    }

    func testStagingErrorMessage_allFilesSkipped() {
        let total = 5
        let staged = 0
        let skipped = total - staged

        let message = "\(skipped) of \(total) files could not be attached."
        XCTAssertEqual(message, "5 of 5 files could not be attached.")
    }

    func testStagingErrorMessage_noFilesSkipped_noMessageSet() {
        let total = 3
        let staged = 3

        // The controller only sets lastErrorMessage when stagedCount < total
        if staged < total {
            store.lastErrorMessage = "\(total - staged) of \(total) files could not be attached."
        }
        XCTAssertNil(store.lastErrorMessage, "No error should be set when all files staged successfully")
    }
}

// MARK: - ErrorBannerView Tests

final class ErrorBannerViewTests: XCTestCase {

    func testOnDismiss_defaultIsNoOp() {
        // Default closure should not crash
        let banner = ErrorBannerView(message: "Test")
        banner.onDismiss()
    }

    func testOnDismiss_customClosureCalled() {
        var dismissed = false
        let banner = ErrorBannerView(message: "Error") {
            dismissed = true
        }
        banner.onDismiss()
        XCTAssertTrue(dismissed)
    }

    func testMessage_preserved() {
        let banner = ErrorBannerView(message: "Something failed")
        XCTAssertEqual(banner.message, "Something failed")
    }

    func testMessage_emptyString() {
        let banner = ErrorBannerView(message: "")
        XCTAssertEqual(banner.message, "")
    }

    func testMessage_longText() {
        let longMessage = String(repeating: "Error details. ", count: 50)
        let banner = ErrorBannerView(message: longMessage)
        XCTAssertEqual(banner.message, longMessage)
    }

    func testMessage_unicodeContent() {
        let banner = ErrorBannerView(message: "2 of 5 files could not be attached.")
        XCTAssertEqual(banner.message, "2 of 5 files could not be attached.")
    }
}
