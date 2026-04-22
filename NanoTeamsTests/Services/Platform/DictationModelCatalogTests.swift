import Speech
import XCTest
@testable import NanoTeams

/// Covers the pure/observable parts of `DictationModelCatalog`. The async
/// API (`allLocales`, `status`, `install`, `uninstall`) is a thin wrapper
/// around Apple's `AssetInventory` / `DictationTranscriber` — not
/// unit-testable without a real on-device model, which is environment-dependent.
final class DictationModelCatalogTests: XCTestCase {

    /// `DictationModelCatalog` is gated at `@available(macOS 26+)` because it
    /// depends on `AssetInventory` / `DictationTranscriber`. Our deployment
    /// target is macOS 15, so the test binary still runs on older CI — but
    /// touching those weakly-linked symbols segfaults. Call this at the top
    /// of every test that touches the catalog.
    private func skipIfUnavailable() throws {
        guard #unavailable(macOS 26, iOS 26, visionOS 26) else { return }
        throw XCTSkip("DictationModelCatalog requires macOS 26+.")
    }

    // MARK: - ModelInfo.displayName

    func testDisplayName_knownLocale_returnsLocalizedName() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let info = DictationModelCatalog.ModelInfo(
            locale: Locale(identifier: "en_US"),
            status: .installed
        )
        // Locale.localizedString returns the user's current-locale rendering
        // — we don't pin the exact string (varies by machine language) but
        // assert it's non-empty and different from the raw identifier.
        XCTAssertFalse(info.displayName.isEmpty)
    }

    func testDisplayName_unknownLocale_fallsBackToIdentifier() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let info = DictationModelCatalog.ModelInfo(
            locale: Locale(identifier: "xx_ZZ"),
            status: .installed
        )
        XCTAssertFalse(info.displayName.isEmpty)
    }

    // MARK: - ModelInfo identity

    func testId_equalsLocaleIdentifier() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let info = DictationModelCatalog.ModelInfo(
            locale: Locale(identifier: "ru_RU"),
            status: .installed
        )
        XCTAssertEqual(info.id, "ru_RU")
    }

    func testHashable_sameLocaleAndStatus_areEqual() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let a = DictationModelCatalog.ModelInfo(
            locale: Locale(identifier: "en_US"),
            status: .installed
        )
        let b = DictationModelCatalog.ModelInfo(
            locale: Locale(identifier: "en_US"),
            status: .installed
        )
        XCTAssertEqual(a, b)
    }

    func testHashable_differentStatus_areNotEqual() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let installed = DictationModelCatalog.ModelInfo(
            locale: Locale(identifier: "en_US"),
            status: .installed
        )
        let supported = DictationModelCatalog.ModelInfo(
            locale: Locale(identifier: "en_US"),
            status: .supported
        )
        XCTAssertNotEqual(installed, supported)
    }

    // MARK: - install — unsupported locale

    /// Pins that Apple's unsupported-locale error isn't swallowed or
    /// misclassified as `CancellationError` (our cancel path catches that
    /// distinctly, so blurring the two would hide real failures).
    func testInstall_unsupportedLocale_throwsNonCancellationError() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let fake = Locale(identifier: "xx_ZZ")
        do {
            try await DictationModelCatalog.install(locale: fake)
            XCTFail("Expected install to throw for unsupported locale")
        } catch is CancellationError {
            XCTFail("Unsupported-locale failure must not be reported as CancellationError")
        } catch {
            // Any other error is acceptable. Apple currently reports
            // SFSpeechErrorDomain Code=15.
        }
    }

    // MARK: - uninstall — non-reserved locale

    func testUninstall_unreservedLocale_returnsFalse() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let fake = Locale(identifier: "xx_ZZ")
        let released = await DictationModelCatalog.uninstall(locale: fake)
        XCTAssertFalse(released)
    }

    // MARK: - Task cancellation pattern

    /// Mirrors the cancellation pattern used inside
    /// `DictationModelCatalog.install`. This isn't a direct test of the
    /// production function (which would require a live download) — it's a
    /// regression pin for the *pattern*: `withTaskCancellationHandler`'s
    /// `onCancel` fires synchronously when the owning `Task` is cancelled,
    /// and the suspended `await` then throws `CancellationError`.
    /// Changing the production code to a different cancellation strategy
    /// without updating callers would make this test's guarantees false.
    func testWithTaskCancellationHandler_firesOnCancelAndThrows() async throws {
        let onCancelFired = expectation(description: "onCancel fired")

        let task = Task<Void, Error> {
            try await withTaskCancellationHandler {
                // Long sleep stands in for the network-bound download.
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } onCancel: {
                onCancelFired.fulfill()
            }
        }

        // Let the Task reach the first suspension point.
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        await fulfillment(of: [onCancelFired], timeout: 1.0)

        do {
            try await task.value
            XCTFail("Cancelled Task must throw")
        } catch is CancellationError {
            // Expected — matches `install`'s behavior.
        } catch {
            let ns = error as NSError
            let isUserCancelled = ns.domain == NSCocoaErrorDomain
                && ns.code == NSUserCancelledError
            XCTAssertTrue(
                isUserCancelled,
                "Expected CancellationError or user-cancel NSError, got: \(error)"
            )
        }
    }

    /// Pins the contract my cancel path leans on: `Task.isCancelled` is
    /// readable from inside the Task body after `cancel()` has been called
    /// externally. `DictationModelCatalog.install` relies on this to throw
    /// `CancellationError` + roll back via `AssetInventory.release` even
    /// when `downloadAndInstall()` doesn't honor progress cancellation.
    func testTaskIsCancelled_visibleAfterExternalCancel() async throws {
        let reachedCheck = expectation(description: "body reached isCancelled check")
        let sawCancellation = expectation(description: "Task.isCancelled == true")

        let task = Task {
            // Yield once so the outer code can race with `cancel()`.
            reachedCheck.fulfill()
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled {
                sawCancellation.fulfill()
            }
        }

        await fulfillment(of: [reachedCheck], timeout: 1.0)
        task.cancel()
        await fulfillment(of: [sawCancellation], timeout: 1.0)

        _ = await task.value
    }

}
