import Speech
import XCTest
@testable import NanoTeams

/// Covers the part of `DictationEngine.start(locales:)` that runs **before**
/// any audio hardware is touched — since the `DictationStartPlanner`
/// extraction, that is the engine→planner→`SystemDictationAssetInventory`
/// integration: the sweep DECISIONS are pinned fake-driven in
/// `DictationStartPlannerTests`; this suite proves the engine actually routes
/// through them with the LIVE Speech-backed inventory conformance.
///
/// Safety: every locale used here is a syntactically valid but non-existent
/// language/region pair, so `AssetInventory.status(forModules:)` reports
/// `.unsupported` on any machine and the planner throws BEFORE the
/// `AVAudioEngine()` construction. No microphone is opened, no TCC dialog can
/// appear, and nothing is downloaded or reserved.
///
/// Everything below the planner call (analyzer preparation, the tap, slot
/// teardown) needs a real installed model plus live audio and is deliberately
/// left to manual/integration verification.
///
/// No class-level `@available`: XCTest's Objective-C discovery doesn't reliably
/// honor Swift availability gates, so each test runtime-checks and skips.
@MainActor
final class DictationEngineStartContractTests: XCTestCase {

    private func skipIfUnavailable() throws {
        guard #unavailable(macOS 26, iOS 26, visionOS 26) else { return }
        throw XCTSkip("DictationEngine requires macOS 26+.")
    }

    /// Not a real language/region pair — `AssetInventory` can only ever report
    /// `.unsupported`, so the model sweep is deterministic everywhere.
    private let unusable = Locale(identifier: "xx_ZZ")
    private let alsoUnusable = Locale(identifier: "qq_ZZ")

    @available(macOS 26, iOS 26, visionOS 26, *)
    private func assertNoInstalledModel(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected EngineError.noInstalledModel", file: file, line: line)
        } catch let error as DictationEngine.EngineError {
            XCTAssertEqual(error, .noInstalledModel, file: file, line: line)
        } catch {
            XCTFail("Wrong error type: \(error)", file: file, line: line)
        }
    }

    // MARK: - Model-availability sweep

    /// The non-empty-but-unusable case. `start(locales: [])` already throws
    /// `noSupportedLocales` (pinned elsewhere); this is the branch one step
    /// deeper — locales were supplied, none of them has a model on disk.
    func testStart_localeWithNoInstalledModel_throwsNoInstalledModel() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()
        await assertNoInstalledModel { try await sut.start(locales: [self.unusable]) }
    }

    /// Drives the sweep loop more than once — a single-locale test can't tell
    /// "checked every locale" from "checked the first and bailed".
    func testStart_severalUnusableLocales_stillThrowsNoInstalledModel() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()
        await assertNoInstalledModel {
            try await sut.start(locales: [self.unusable, self.alsoUnusable, self.unusable])
        }
    }

    /// Failure is reported by THROWING, not through `onError`. The distinction
    /// matters: `DictationService` wires `onError` to `surfaceError` + `stop()`,
    /// so an engine that also fired the callback here would surface the same
    /// failure twice and tear down a session that never started.
    func testStart_failure_doesNotFireTheErrorCallback() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()
        var errors: [String] = []
        var updates = 0
        sut.onError = { errors.append($0) }
        sut.onUpdate = { _ in updates += 1 }

        await assertNoInstalledModel { try await sut.start(locales: [self.unusable]) }

        XCTAssertTrue(errors.isEmpty, "a thrown start must not ALSO report through onError")
        XCTAssertEqual(updates, 0)
    }

    // MARK: - State after a failed start

    func testStart_afterFailure_leavesNoRunningState() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()
        await assertNoInstalledModel { try await sut.start(locales: [self.unusable]) }

        XCTAssertFalse(sut.isRunning)
        XCTAssertTrue(sut.activeLocales.isEmpty)
    }

    /// A failed start must leave the engine reusable. The engine's own comment
    /// calls this out: a leaked audio tap makes the NEXT `start` fail with
    /// "tap already installed" on the input node — a failure mode that would
    /// only ever show up on the user's second attempt.
    func testStart_afterFailure_isRetryableWithTheSameOutcome() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()

        await assertNoInstalledModel { try await sut.start(locales: [self.unusable]) }
        await assertNoInstalledModel { try await sut.start(locales: [self.unusable]) }

        XCTAssertFalse(sut.isRunning)
    }

    /// Locales-empty and locales-unusable must stay distinguishable across a
    /// retry: the first drives the user to Settings → Dictation to download a
    /// model, the second says nothing is configured at all.
    func testStart_emptyAfterUnusable_reportsTheEmptyCaseNotTheStaleOne() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()

        await assertNoInstalledModel { try await sut.start(locales: [self.unusable]) }

        do {
            try await sut.start(locales: [])
            XCTFail("Expected noSupportedLocales")
        } catch let error as DictationEngine.EngineError {
            XCTAssertEqual(error, .noSupportedLocales)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Teardown after a failed start

    func testStop_afterFailedStart_isNoOpAndIdempotent() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()
        await assertNoInstalledModel { try await sut.start(locales: [self.unusable]) }

        sut.stop()
        XCTAssertFalse(sut.isRunning)
        sut.stop()
        XCTAssertFalse(sut.isRunning)
        XCTAssertTrue(sut.activeLocales.isEmpty)
    }

    /// The submit path calls `stopAndFlush()`; it must survive being invoked on
    /// an engine that never acquired slots (user hit send right after a failed
    /// start) without hanging on the flush budget or tripping the drain loop.
    func testStopAndFlush_afterFailedStart_isNoOpAndIdempotent() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()
        await assertNoInstalledModel { try await sut.start(locales: [self.unusable]) }

        await sut.stopAndFlush()
        XCTAssertFalse(sut.isRunning)
        await sut.stopAndFlush()
        XCTAssertFalse(sut.isRunning)
    }

    /// Cancel-then-submit ordering: `stop()` (cancel) followed by
    /// `stopAndFlush()` (submit) is reachable from the UI and must not double
    /// tear down.
    func testStop_thenStopAndFlush_bothSucceed() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()
        sut.stop()
        await sut.stopAndFlush()
        sut.stop()
        XCTAssertFalse(sut.isRunning)
    }
}
