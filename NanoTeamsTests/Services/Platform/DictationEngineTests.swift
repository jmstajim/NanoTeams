import XCTest
@testable import NanoTeams

/// Scaffold for `DictationEngine`. The audio pipeline (AVAudioEngine +
/// SpeechAnalyzer) isn't tractable in-process without real mic + installed
/// models — those paths live under the handleSubmit / toggle integration
/// checks. What we CAN pin here: error strings, initial state, the "no
/// locales" guard, and `stop()` idempotency on a fresh engine.
@available(macOS 26, iOS 26, visionOS 26, *)
@MainActor
final class DictationEngineTests: XCTestCase {

    var sut: DictationEngine!

    override func setUp() {
        super.setUp()
        sut = DictationEngine()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Initial state

    func testInit_defaults() {
        XCTAssertFalse(sut.isRunning)
        XCTAssertTrue(sut.activeLocales.isEmpty)
    }

    // MARK: - stop() idempotency

    func testStop_freshEngine_isNoOp() {
        sut.stop()
        XCTAssertFalse(sut.isRunning)
        sut.stop()
        XCTAssertFalse(sut.isRunning)
    }

    func testStopAndFlush_freshEngine_isNoOp() async {
        await sut.stopAndFlush()
        XCTAssertFalse(sut.isRunning)
    }

    // MARK: - start() guard

    func testStart_emptyLocales_throwsNoSupportedLocales() async {
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

    func testErrorDescription_noSupportedLocales() {
        XCTAssertEqual(
            DictationEngine.EngineError.noSupportedLocales.errorDescription,
            "No speech-recognition locales are configured."
        )
    }

    func testErrorDescription_noInstalledModel_pointsToSettings() {
        let message = DictationEngine.EngineError.noInstalledModel.errorDescription ?? ""
        XCTAssertTrue(message.contains("Settings"), "Must direct user to settings to download a model")
        XCTAssertTrue(message.contains("Dictation"), "Must name the settings tab")
    }
}
