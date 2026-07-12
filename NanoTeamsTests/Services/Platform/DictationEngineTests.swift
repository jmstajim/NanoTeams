import XCTest
// `@preconcurrency` mirrors DictationEngine.swift: the tap-isolation test
// captures non-`Sendable` `AVAudioFormat`/`AVAudioPCMBuffer` into a `@Sendable`
// `Task.detached` closure, which `@preconcurrency` allows.
@preconcurrency import AVFoundation
import Speech
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

    // MARK: - Tap-path isolation (regression: mic-button crash)

    /// Pins that `TapBridge.feed` is `nonisolated`. AVAudioEngine invokes the
    /// installTap block — which calls `feed` — on its realtime audio thread; if
    /// `feed` were main-actor-isolated (the app target's default), the executor
    /// check aborts the process (`dispatch_assert_queue`). This is the crash the
    /// mic button hit before the fix.
    ///
    /// The test is BOTH a compile-time and a runtime proof:
    /// - COMPILE-TIME: `bridge.feed(buffer)` is called SYNCHRONOUSLY from a
    ///   `Task.detached` (nonisolated) context. If `feed` ever regresses to
    ///   `@MainActor`, this line fails to build. It MUST stay synchronous — do
    ///   NOT add `await` (that would compile from an async nonisolated context
    ///   and silently destroy the proof).
    /// - RUNTIME: the fed buffer is yielded into the stream without crashing.
    ///   `continuation.finish()` makes a silent drop FAIL (nil) instead of
    ///   hanging on `next()`.
    ///
    /// Scope: this covers the `TapBridge`/`feed` half of the fix. The tap
    /// closure's own `@Sendable` marker can't be unit-tested (it only crashes
    /// with a live AVAudioEngine tap on real hardware, unavailable on CI) — a
    /// load-bearing comment guards it at the installTap call site instead.
    func testTapBridge_feed_isNonisolated_yieldsWithoutCrashingOffMainActor() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        // `converter: nil` takes `feed`'s deterministic early-return yield branch.
        let bridge = TapBridge(
            continuation: continuation,
            converter: nil,
            outputFormat: format,
            slotIndex: 0,
            onDropsExceeded: { _ in }
        )

        let feeder = Task.detached {
            // MUST stay a synchronous call — do NOT add `await`. This is the
            // nonisolation assertion: it only compiles because `feed` (and
            // `TapBridge`) are `nonisolated`.
            bridge.feed(buffer)
            continuation.finish()
        }
        await feeder.value

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertNotNil(first, "feed() on the realtime path must yield the buffer into the analyzer stream")
    }
}
