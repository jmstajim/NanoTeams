import XCTest
@testable import NanoTeams

/// Scaffold for `DictationEngine`. The audio pipeline (AVAudioEngine +
/// SpeechAnalyzer) isn't tractable in-process without real mic + installed
/// models — those paths live under the handleSubmit / toggle integration
/// checks. What we CAN pin here: error strings, initial state, the "no
/// locales" guard, and `stop()` idempotency on a fresh engine.
///
/// NOTE: no class-level `@available` annotation — XCTest's Objective-C
/// discovery doesn't always honor Swift availability gates, so each test
/// runtime-checks and throws `XCTSkip` on macOS < 26. Class-level `@MainActor`
/// stays because `DictationEngine` itself is main-actor-isolated.
@MainActor
final class DictationEngineTests: XCTestCase {

    private func skipIfUnavailable() throws {
        guard #unavailable(macOS 26, iOS 26, visionOS 26) else { return }
        throw XCTSkip("DictationEngine requires macOS 26+.")
    }

    // MARK: - Initial state

    func testInit_defaults() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()
        XCTAssertFalse(sut.isRunning)
        XCTAssertTrue(sut.activeLocales.isEmpty)
    }

    // MARK: - stop() idempotency

    func testStop_freshEngine_isNoOp() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()
        sut.stop()
        XCTAssertFalse(sut.isRunning)
        sut.stop()
        XCTAssertFalse(sut.isRunning)
    }

    func testStopAndFlush_freshEngine_isNoOp() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()
        await sut.stopAndFlush()
        XCTAssertFalse(sut.isRunning)
    }

    // MARK: - start() guard

    func testStart_emptyLocales_throwsNoSupportedLocales() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let sut = DictationEngine()
        do {
            try await sut.start(locales: [])
            XCTFail("Expected noSupportedLocales")
        } catch let error as DictationEngine.EngineError {
            XCTAssertEqual(error, .noSupportedLocales)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - EngineError.errorDescription (regression pin — user-visible copy)

    func testErrorDescription_noSupportedLocales() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        XCTAssertEqual(
            DictationEngine.EngineError.noSupportedLocales.errorDescription,
            "No speech-recognition locales are configured."
        )
    }

    func testErrorDescription_noInstalledModel_pointsToSettings() throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }
        let message = DictationEngine.EngineError.noInstalledModel.errorDescription ?? ""
        XCTAssertTrue(message.contains("Settings"), "Must direct user to settings to download a model")
        XCTAssertTrue(message.contains("Dictation"), "Must name the settings tab")
    }
}
