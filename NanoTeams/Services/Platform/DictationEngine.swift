import AVFoundation
import Foundation
import Speech

/// On-device dictation engine built on Apple's `SpeechAnalyzer` +
/// `DictationTranscriber` (macOS 26+).
///
/// Privacy contract:
/// - **No Speech Recognition permission dialog** — the new framework does
///   not use `SFSpeechRecognizer.requestAuthorization`; models are managed
///   by `AssetInventory` and run entirely on-device.
/// - Only the microphone permission dialog remains (unavoidable for any
///   audio capture on macOS).
///
/// Audio-format note: the mic's native output format usually differs from
/// what `SpeechAnalyzer` expects. Each analyzer's `bestAvailableAudioFormat`
/// is queried, and an `AVAudioConverter` is inserted on the audio-tap path.
/// The converter state is preserved between buffers by reporting `.noDataNow`
/// (never `.endOfStream`) after providing each input.
@available(macOS 26, iOS 26, visionOS 26, *)
struct DictationTranscriptUpdate: Sendable {
    let slotIndex: Int
    let text: String
    let isFinal: Bool
}

/// Surface the `DictationService` depends on. Exists so tests can install a
/// fake engine via the DEBUG seam `DictationService._testInstallEngine` and
/// drive the consumer flow (onUpdate/onError) without real audio.
@available(macOS 26, iOS 26, visionOS 26, *)
@MainActor
protocol DictationEngineProtocol: AnyObject {
    var onUpdate: ((DictationTranscriptUpdate) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var activeLocales: [Locale] { get }
    func stop()
    func stopAndFlush() async
}

@available(macOS 26, iOS 26, visionOS 26, *)
@MainActor
final class DictationEngine: DictationEngineProtocol {

    typealias TranscriptUpdate = DictationTranscriptUpdate

    var onUpdate: ((DictationTranscriptUpdate) -> Void)?
    var onError: ((String) -> Void)?

    private struct Slot {
        let locale: Locale
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let consumerTask: Task<Void, Never>
        let analyzerTask: Task<Void, Never>
    }

    private var audioEngine: AVAudioEngine?
    private var slots: [Slot] = []
    private var tapInstalled = false

    var activeLocales: [Locale] { slots.map(\.locale) }
    var isRunning: Bool { !slots.isEmpty }

    // MARK: - Lifecycle

    /// Starts dictation for the given locales. Uses only already-installed
    /// on-device models; downloads happen exclusively from the Dictation
    /// settings UI. Throws if no usable model is present.
    func start(locales: [Locale]) async throws {
        guard !locales.isEmpty else {
            throw EngineError.noSupportedLocales
        }

        var viable: [(Locale, DictationTranscriber)] = []
        for locale in locales {
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            let status = await AssetInventory.status(forModules: [transcriber])
            if status == .installed {
                viable.append((locale, transcriber))
            }
        }

        guard !viable.isEmpty else {
            throw EngineError.noInstalledModel
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        var builtSlots: [Slot] = []
        var tapBridges: [TapBridge] = []

        for (index, pair) in viable.enumerated() {
            let slotIndex = index
            let transcriber = pair.1

            let preferred = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: nativeFormat
            ) ?? nativeFormat

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
            // Apple's WWDC25 pattern: init WITHOUT inputSequence, then call
            // `start(inputSequence:)` explicitly. The convenience init that
            // takes `inputSequence` does NOT auto-start — results would never
            // emit without an explicit start call.
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            do {
                try await analyzer.prepareToAnalyze(in: preferred)
            } catch {
                continuation.finish()
                onError?(error.localizedDescription)
                continue
            }

            let consumer = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        await MainActor.run { [weak self] in
                            self?.onUpdate?(
                                TranscriptUpdate(slotIndex: slotIndex, text: text, isFinal: false)
                            )
                        }
                    }
                    await MainActor.run { [weak self] in
                        self?.onUpdate?(
                            TranscriptUpdate(slotIndex: slotIndex, text: "", isFinal: true)
                        )
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.onError?(error.localizedDescription)
                    }
                }
            }

            // Explicit `start(inputSequence:)` — without this call,
            // `transcriber.results` never emits.
            let analyzerTask: Task<Void, Never> = Task {
                do {
                    try await analyzer.start(inputSequence: stream)
                } catch is CancellationError {
                    // Expected on stop() — no signal needed.
                } catch {
                    await MainActor.run { [weak self] in
                        self?.onError?(error.localizedDescription)
                        self?.stop()
                    }
                }
            }

            let converter: AVAudioConverter?
            if preferred != nativeFormat {
                converter = AVAudioConverter(from: nativeFormat, to: preferred)
            } else {
                converter = nil
            }

            builtSlots.append(
                Slot(
                    locale: pair.0,
                    analyzer: analyzer,
                    continuation: continuation,
                    consumerTask: consumer,
                    analyzerTask: analyzerTask
                )
            )
            tapBridges.append(
                TapBridge(
                    continuation: continuation,
                    converter: converter,
                    outputFormat: preferred,
                    slotIndex: slotIndex,
                    onDropsExceeded: { [weak self] slot in
                        Task { @MainActor [weak self] in
                            self?.onError?("Audio capture is failing for slot \(slot). Try restarting dictation or checking your microphone.")
                        }
                    }
                )
            )
        }

        guard !builtSlots.isEmpty else {
            throw EngineError.noInstalledModel
        }

        let box = BridgesBox(bridges: tapBridges)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { buffer, _ in
            for bridge in box.bridges {
                bridge.feed(buffer)
            }
        }
        tapInstalled = true

        // Adopt state before starting the engine so cleanup on throw
        // tears down the tap + tasks instead of leaking them. A second
        // `start(locales:)` after a leaked failure would hit "tap already
        // installed" on the input node.
        self.audioEngine = engine
        self.slots = builtSlots

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    /// Immediate teardown — cancels in-flight consumers so any pending
    /// final result is lost. Use for cancel / toggle paths where the
    /// transcript is being discarded anyway. Submit paths should call
    /// `stopAndFlush()` instead.
    func stop() {
        for slot in slots {
            slot.continuation.finish()
            slot.consumerTask.cancel()
            slot.analyzerTask.cancel()
            Task { try? await slot.analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        teardownAudio()
    }

    /// Waits for the analyzer to flush any buffered audio and for the
    /// consumer to forward the final result before tearing down.
    /// Without this, submit paths that call `stop()` synchronously drop
    /// the last spoken words — `consumerTask.cancel()` kills the
    /// `for try await result in transcriber.results` loop before the
    /// final `isFinal:true` update reaches the binding.
    ///
    /// Bounded so a hung analyzer can't freeze the send button.
    func stopAndFlush() async {
        for slot in slots { slot.continuation.finish() }

        let drain: () async -> Void = { [slots] in
            for slot in slots {
                _ = try? await slot.analyzer.finalizeAndFinishThroughEndOfInput()
                _ = await slot.consumerTask.value
            }
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await drain() }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.flushTimeoutNanos)
            }
            _ = await group.next()
            group.cancelAll()
        }

        for slot in slots {
            slot.consumerTask.cancel()
            slot.analyzerTask.cancel()
        }
        teardownAudio()
    }

    private static let flushTimeoutNanos: UInt64 = 500 * 1_000_000

    private func teardownAudio() {
        if let engine = audioEngine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            if engine.isRunning { engine.stop() }
        }
        audioEngine = nil
        slots = []
    }

    // MARK: - Errors

    enum EngineError: Error, LocalizedError {
        case noSupportedLocales
        case noInstalledModel

        var errorDescription: String? {
            switch self {
            case .noSupportedLocales:
                return "No speech-recognition locales are configured."
            case .noInstalledModel:
                return "No dictation model is installed. Open Settings → Dictation to download one."
            }
        }
    }
}

// MARK: - Audio Tap Bridge

/// Per-slot conversion state for the audio tap. Feeds converted buffers
/// into the analyzer's `AsyncStream`. Reference type so `AVAudioConverter`
/// internal state persists across tap-block invocations.
@available(macOS 26, iOS 26, visionOS 26, *)
private final class TapBridge: @unchecked Sendable {
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let converter: AVAudioConverter?
    let outputFormat: AVAudioFormat
    let slotIndex: Int
    /// Fired once when consecutive drops exceed `dropThreshold`. Tap runs
    /// ~100×/sec; threshold = ~200ms of unusable audio.
    let onDropsExceeded: @Sendable (Int) -> Void

    private var consecutiveDrops = 0
    private var didReportDrops = false
    private static let dropThreshold = 20

    init(
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        converter: AVAudioConverter?,
        outputFormat: AVAudioFormat,
        slotIndex: Int,
        onDropsExceeded: @escaping @Sendable (Int) -> Void
    ) {
        self.continuation = continuation
        self.converter = converter
        self.outputFormat = outputFormat
        self.slotIndex = slotIndex
        self.onDropsExceeded = onDropsExceeded
    }

    func feed(_ input: AVAudioPCMBuffer) {
        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: input))
            consecutiveDrops = 0
            return
        }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            recordDrop()
            return
        }

        var error: NSError?
        var provided = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if provided {
                // `.noDataNow` keeps the converter's sample-rate filter alive
                // across buffers. `.endOfStream` would close it permanently.
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error {
            recordDrop()
            return
        }
        continuation.yield(AnalyzerInput(buffer: output))
        consecutiveDrops = 0
    }

    private func recordDrop() {
        consecutiveDrops += 1
        guard !didReportDrops, consecutiveDrops >= Self.dropThreshold else { return }
        didReportDrops = true
        onDropsExceeded(slotIndex)
    }
}

@available(macOS 26, iOS 26, visionOS 26, *)
private final class BridgesBox: @unchecked Sendable {
    let bridges: [TapBridge]
    init(bridges: [TapBridge]) {
        self.bridges = bridges
    }
}
