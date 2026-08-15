import XCTest

@testable import NanoTeams

// MARK: - ErrorBannerModifier Logic Tests

/// Tests the ErrorBannerModifier's consume-and-display logic by directly testing
/// the orchestrator's lastErrorMessage lifecycle and the modifier's state transitions.
@MainActor
final class ErrorBannerModifierTests: XCTestCase {

    var store: NTMSOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        store = TestOrchestrator.make()
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
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
    //
    // Deliberately empty. Three tests lived here that built the failure string
    // inside the test and compared it against a literal, without calling any
    // production symbol — so they passed no matter what `ClipboardStagingPolicy`
    // did, and the compiler eventually said so out loud ("will never be
    // executed": `staged < total` over two `let` constants folds to `false`, so
    // the one branch that touched `store` was unreachable and the test degraded
    // into a duplicate of `testLastErrorMessage_initiallyNil`).
    //
    // The real coverage is in `ClipboardStagingPolicyTests`, which drives
    // `ClipboardStagingPolicy.plan` itself:
    // `testStagingFailure_reportsTheCount` pins the exact wording,
    // `testAllFilesStage_noFailureMessage` pins the silent path, and
    // `testMixedDuplicateAndFailure_countsOnlyTheFailure` pins the count.
    // A banner-level test would have to go through
    // `QuickCaptureController.stageCapturedContent`, the one site that writes
    // `store.lastErrorMessage`.
}

// MARK: - ErrorBannerView Tests

@MainActor
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
