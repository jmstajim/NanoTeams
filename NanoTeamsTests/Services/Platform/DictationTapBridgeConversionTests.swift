import XCTest
// `@preconcurrency` mirrors DictationEngine.swift + DictationEngineTests.swift:
// these tests capture non-`Sendable` `AVAudioFormat` / `AVAudioPCMBuffer` values
// into `@Sendable` closures and a `Task.detached` body.
@preconcurrency import AVFoundation
import Speech
@testable import NanoTeams

/// Covers `TapBridge`'s **converting** branch — the half of the realtime audio
/// path `DictationEngineTests` deliberately leaves alone (it pins only the
/// `converter == nil` passthrough).
///
/// The converting branch is the one production actually takes: the mic's native
/// format almost never matches `SpeechAnalyzer.bestAvailableAudioFormat`, so
/// `DictationEngine.start(locales:)` installs an `AVAudioConverter` for every
/// slot. Everything below runs entirely on synthesized buffers — no audio
/// engine is created, no microphone is opened, no TCC dialog can appear.
final class DictationTapBridgeConversionTests: XCTestCase {

    /// `TapBridge` lives behind `@available(macOS 26, …)`; touching it on an
    /// older runtime resolves weakly-linked Speech symbols and segfaults.
    private func skipIfUnavailable() throws {
        guard #unavailable(macOS 26, iOS 26, visionOS 26) else { return }
        throw XCTSkip("TapBridge requires macOS 26+.")
    }

    /// `onDropsExceeded` is `@Sendable` and fires from whatever thread called
    /// `feed` (AVAudioEngine's realtime thread in production), so the recorder
    /// has to be lock-guarded rather than a captured `var`.
    private final class DropRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [Int] = []
        func record(_ slot: Int) { lock.withLock { slots.append(slot) } }
        var recorded: [Int] { lock.withLock { slots } }
    }

    private let nativeRate: Double = 48_000
    private let analyzerRate: Double = 16_000
    private let foreignRate: Double = 8_000

    private func format(_ rate: Double) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    }

    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount = 4096) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return buffer
    }

    @available(macOS 26, iOS 26, visionOS 26, *)
    private struct Rig {
        let bridge: TapBridge
        let stream: AsyncStream<AnalyzerInput>
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let recorder: DropRecorder
    }

    @available(macOS 26, iOS 26, visionOS 26, *)
    private func makeRig(
        from input: AVAudioFormat,
        to output: AVAudioFormat,
        slotIndex: Int = 0
    ) throws -> Rig {
        let converter = try XCTUnwrap(
            AVAudioConverter(from: input, to: output),
            "AVAudioConverter must exist for two standard PCM formats"
        )
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let recorder = DropRecorder()
        let bridge = TapBridge(
            continuation: continuation,
            converter: converter,
            outputFormat: output,
            slotIndex: slotIndex,
            onDropsExceeded: { slot in recorder.record(slot) }
        )
        return Rig(bridge: bridge, stream: stream, continuation: continuation, recorder: recorder)
    }

    @available(macOS 26, iOS 26, visionOS 26, *)
    private func drain(_ rig: Rig) async -> [AnalyzerInput] {
        rig.continuation.finish()
        var collected: [AnalyzerInput] = []
        for await input in rig.stream { collected.append(input) }
        return collected
    }

    // MARK: - Conversion succeeds

    /// The analyzer must receive its own preferred format, never the mic's.
    /// A regression here is silent: `SpeechAnalyzer` would be fed 48 kHz audio
    /// it was prepared to read at 16 kHz and simply transcribe nothing.
    func testFeed_withConverter_yieldsBufferInTheAnalyzerFormat() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let native = try format(nativeRate)
        let preferred = try format(analyzerRate)
        let rig = try makeRig(from: native, to: preferred)

        rig.bridge.feed(try buffer(native))
        let yielded = await drain(rig)

        XCTAssertEqual(yielded.count, 1, "one tap buffer must produce exactly one analyzer input")
        XCTAssertEqual(
            yielded[0].buffer.format.sampleRate,
            analyzerRate,
            "the converted buffer, not the native one, must reach the analyzer"
        )
        XCTAssertTrue(rig.recorder.recorded.isEmpty, "a healthy conversion must not report drops")
    }

    /// Pins the load-bearing `.noDataNow` contract in `feed`. The converter's
    /// sample-rate filter has to survive between tap invocations; reporting
    /// `.endOfStream` after the first buffer would close it permanently and
    /// every later buffer would come back empty — dictation that transcribes
    /// only the first ~85 ms of speech.
    func testFeed_consecutiveBuffers_keepTheResamplerAlive() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let native = try format(nativeRate)
        let preferred = try format(analyzerRate)
        let rig = try makeRig(from: native, to: preferred)

        for _ in 0..<3 { rig.bridge.feed(try buffer(native)) }
        let yielded = await drain(rig)

        XCTAssertEqual(yielded.count, 3)
        for (index, input) in yielded.enumerated() {
            XCTAssertGreaterThan(
                input.buffer.frameLength,
                0,
                "buffer \(index) converted to zero frames — the resampler was closed after the first input"
            )
        }
    }

    // MARK: - Conversion fails → drop

    /// A buffer whose format doesn't match the converter's input (a mic swapped
    /// mid-session) makes `AVAudioConverter.convert` return `.error`. The bridge
    /// must swallow that buffer rather than yield a half-filled one.
    func testFeed_inputFormatMismatch_dropsInsteadOfYielding() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let native = try format(nativeRate)
        let preferred = try format(analyzerRate)
        let rig = try makeRig(from: native, to: preferred)

        rig.bridge.feed(try buffer(try format(foreignRate)))
        let yielded = await drain(rig)

        XCTAssertTrue(yielded.isEmpty, "a failed conversion must not push a bogus buffer into the analyzer")
    }

    func testFeed_dropsBelowTheThreshold_stayQuiet() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let rig = try makeRig(from: try format(nativeRate), to: try format(analyzerRate))
        let foreign = try format(foreignRate)

        for _ in 0..<19 { rig.bridge.feed(try buffer(foreign)) }

        XCTAssertTrue(
            rig.recorder.recorded.isEmpty,
            "19 consecutive drops is under the 20-drop threshold — warning here would fire on ordinary glitches"
        )
        _ = await drain(rig)
    }

    /// The 20th consecutive drop reports once, names its slot, and then latches:
    /// the tap runs ~100×/s, so a per-drop banner would flood the error surface.
    func testFeed_twentiethConsecutiveDrop_reportsOnceForItsSlot() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let rig = try makeRig(from: try format(nativeRate), to: try format(analyzerRate), slotIndex: 7)
        let foreign = try format(foreignRate)

        for _ in 0..<19 { rig.bridge.feed(try buffer(foreign)) }
        XCTAssertTrue(rig.recorder.recorded.isEmpty)

        rig.bridge.feed(try buffer(foreign))
        XCTAssertEqual(rig.recorder.recorded, [7], "threshold drop must report exactly once, tagged with its slot")

        for _ in 0..<40 { rig.bridge.feed(try buffer(foreign)) }
        XCTAssertEqual(rig.recorder.recorded, [7], "the report must latch — the tap fires ~100×/s")

        _ = await drain(rig)
    }

    /// Drops are *consecutive*: one good buffer clears the streak, so a mic that
    /// glitches intermittently never trips the warning.
    func testFeed_successfulConversionResetsTheDropStreak() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let native = try format(nativeRate)
        let rig = try makeRig(from: native, to: try format(analyzerRate))
        let foreign = try format(foreignRate)

        for _ in 0..<19 { rig.bridge.feed(try buffer(foreign)) }
        rig.bridge.feed(try buffer(native))
        for _ in 0..<19 { rig.bridge.feed(try buffer(foreign)) }

        XCTAssertTrue(
            rig.recorder.recorded.isEmpty,
            "38 drops split by one good buffer must not report — the counter is consecutive, not cumulative"
        )
        _ = await drain(rig)
    }

    // MARK: - Realtime-thread isolation (drop path)

    /// Companion to `DictationEngineTests`' yield-path isolation proof, for the
    /// branch that proof can't reach. `recordDrop` and the `onDropsExceeded`
    /// callback also run on AVAudioEngine's realtime thread; if either became
    /// main-actor-isolated the executor check aborts the process.
    ///
    /// COMPILE-TIME: `feed` is called SYNCHRONOUSLY from a nonisolated
    /// `Task.detached` body — do NOT add `await`, that would compile even if
    /// `feed` regressed to `@MainActor` and destroy the proof.
    func testFeed_dropReporting_runsOffTheMainActorWithoutCrashing() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let rig = try makeRig(from: try format(nativeRate), to: try format(analyzerRate), slotIndex: 2)
        let foreign = try format(foreignRate)
        var bad: [AVAudioPCMBuffer] = []
        for _ in 0..<20 { bad.append(try buffer(foreign)) }
        let bridge = rig.bridge
        let payload = bad

        let feeder = Task.detached {
            for buffer in payload {
                // MUST stay synchronous — see the doc comment.
                bridge.feed(buffer)
            }
        }
        await feeder.value

        XCTAssertEqual(rig.recorder.recorded, [2], "drop reporting must survive being driven off the main actor")
        _ = await drain(rig)
    }
}
