import AVFoundation
import Foundation
import Observation

/// Canonical 4-state microphone permission. `init(_:)` maps from
/// `AVAuthorizationStatus` so a single source of truth flows through the
/// service instead of an ambiguous `Bool`.
enum MicrophoneAuthorization: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
    case restricted

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }
}

/// Abstraction over `AVCaptureDevice` microphone-permission queries so tests
/// can drive `.denied` / `.restricted` / `.notDetermined` branches.
protocol MicrophoneAuthorizationProvider: Sendable {
    func currentStatus() -> AVAuthorizationStatus
    func requestAccess() async -> Bool
}

struct SystemMicrophoneAuthorizationProvider: MicrophoneAuthorizationProvider {
    func currentStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
    }
}

/// App-wide singleton for on-device voice dictation.
///
/// Design notes:
/// - **macOS 26+ only**. Built on Apple's `SpeechAnalyzer` + `DictationTranscriber`,
///   which run entirely on-device and do NOT require the legacy Speech Recognition
///   permission. Only microphone access is requested.
/// - **One active session** across the whole app. `AVAudioEngine` owns the single
///   hardware input node. Two simultaneous dictation surfaces can't share it, so
///   taps are funneled through `activeOwnerID`.
/// - **Languages follow keyboard layouts**: every `start()` re-reads
///   `InputSourceLanguages.currentSpeechLocales()` and spawns one
///   `DictationTranscriber` per supported locale (capped to
///   `maxConcurrentRecognizers`).
/// - **Lazy**: no AVFoundation / Speech APIs are touched in `init()` — the mic
///   permission prompt appears only on the first `toggle()`/`start()` call.
/// - Older macOS (< 26): `start()` surfaces a friendly error. The service
///   itself remains constructable everywhere so the UI can inject it via
///   `.environment(...)` without availability guards.
@Observable
final class DictationService {

    /// Collapses the previous bag-of-flags (`isListening`, `activeOwnerID`,
    /// `activeLocales`) into one observed state so illegal combinations
    /// like `isListening == true && activeOwnerID == nil` are unrepresentable.
    enum SessionState: Equatable {
        case idle
        case listening(ownerID: UUID, locales: [Locale])
    }

    // MARK: - Observed state

    private(set) var sessionState: SessionState = .idle
    private(set) var transcript: String = ""
    private(set) var lastErrorMessage: String?
    private(set) var authorization: MicrophoneAuthorization = .notDetermined

    /// Back-compat shortcut — `true` iff `authorization == .granted`.
    var isAuthorized: Bool { authorization == .granted }

    /// Back-compat projections. Views can keep reading these; tests already do.
    var isListening: Bool {
        if case .listening = sessionState { return true }
        return false
    }
    var activeOwnerID: UUID? {
        if case .listening(let id, _) = sessionState { return id }
        return nil
    }
    var activeLocales: [Locale] {
        if case .listening(_, let locales) = sessionState { return locales }
        return []
    }

    // MARK: - Private state

    /// Index of the slot whose transcriber returned a terminal `isFinal`.
    /// Once pinned, further partials from other recognizers don't overwrite
    /// the winning text.
    private var pinnedSlotIndex: Int?
    /// Per-locale transcript snapshots used for leader selection.
    private var slotTranscripts: [String] = []

    /// Held as `Any?` because `DictationEngine` requires macOS 26 — a strongly
    /// typed stored property would force the whole class into `@available`,
    /// which then forces every `@Environment(DictationService.self)` consumer
    /// to guard availability. The `as?` cast below is cheap and keeps the
    /// service injectable on the deployment target (macOS 15).
    private var engineStorage: Any?
    /// True while `start()` is in flight — guards against double-tap reentry.
    /// Without this, a second `toggle()` during engine init (e.g. while a
    /// model is downloading) would kick off a parallel engine and duplicate
    /// every subsequent update.
    private var isStartingUp: Bool = false
    /// Resolves the user-chosen locale list. Set once at app startup; lets
    /// the service honor "Dictation Languages" selection from settings
    /// without introducing a direct `StoreConfiguration` dependency.
    /// When `nil` or returns an empty array, falls back to
    /// `InputSourceLanguages.currentSpeechLocales()` (system preferred languages).
    var userSelectedLocalesProvider: (() -> [Locale])?

    /// Wired at construction to a global error presenter so dictation
    /// failures don't only reach the mic button's tooltip.
    private let onErrorSurfaced: (String) -> Void

    private let authProvider: any MicrophoneAuthorizationProvider

    static let maxConcurrentRecognizers = 3

    // MARK: - Init

    init(
        onErrorSurfaced: @escaping (String) -> Void = { _ in },
        authProvider: any MicrophoneAuthorizationProvider = SystemMicrophoneAuthorizationProvider()
    ) {
        self.onErrorSurfaced = onErrorSurfaced
        self.authProvider = authProvider
    }

    // MARK: - Public API

    /// Requests microphone permission. Safe to call repeatedly.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let initial = MicrophoneAuthorization(authProvider.currentStatus())
        let granted: Bool
        switch initial {
        case .granted:
            granted = true
        case .denied, .restricted:
            granted = false
        case .notDetermined:
            granted = await authProvider.requestAccess()
        }
        // After a `.notDetermined → request → deny`, keep the denial semantics
        // (same message + same status) as a fresh `.denied`.
        let resolved: MicrophoneAuthorization = granted
            ? .granted
            : (initial == .restricted ? .restricted : .denied)
        authorization = resolved
        if !granted {
            surfaceError(resolved == .restricted
                ? "Microphone access is restricted by your device policy."
                : "Microphone access is required. Enable it in System Settings → Privacy & Security → Microphone.")
        }
        return granted
    }

    /// Toggles a dictation session scoped to `ownerID`.
    /// - If another owner holds the session, or no session is active, starts a new one for `ownerID`.
    /// - If this owner is already listening, stops the session.
    func toggle(ownerID: UUID) async {
        if isListening && activeOwnerID == ownerID {
            stop()
            return
        }
        await start(ownerID: ownerID)
    }

    /// Starts listening. On macOS < 26, surfaces a friendly error and returns.
    /// Otherwise requests mic access, spawns an engine for the user's keyboard
    /// locales, and publishes live transcript.
    func start(ownerID: UUID) async {
        // Double-tap guard — the button's `toggle()` can fire twice while the
        // first `start()` is still awaiting mic auth or background work.
        // Without this flag we'd spin up two parallel engines.
        guard !isStartingUp else { return }
        isStartingUp = true
        defer { isStartingUp = false }

        if isListening {
            stop()
        }

        lastErrorMessage = nil

        guard #available(macOS 26, iOS 26, visionOS 26, *) else {
            surfaceError("Dictation requires macOS 26 or later.")
            return
        }

        await startEngine(ownerID: ownerID)
    }

    /// Immediate teardown — drops any in-flight final transcript. Use for
    /// cancel/toggle paths. Submit paths should use `flushAndThen(_:)` so
    /// the last spoken words reach the binding.
    func stop() {
        if #available(macOS 26, iOS 26, visionOS 26, *),
           let engine = engineStorage as? any DictationEngineProtocol {
            engine.stop()
        }
        resetObservedState()
    }

    /// Awaits any pending final transcript, then invokes `action` on the
    /// main actor. The final update races with `stop()` in naive submit
    /// paths — call this from `send` to avoid sending a partial when the
    /// analyzer was about to finalize.
    func flushAndThen(_ action: @MainActor @escaping () -> Void) {
        Task { @MainActor in
            if #available(macOS 26, iOS 26, visionOS 26, *),
               let engine = engineStorage as? any DictationEngineProtocol {
                await engine.stopAndFlush()
            }
            resetObservedState()
            action()
        }
    }

    private func resetObservedState() {
        engineStorage = nil
        slotTranscripts = []
        pinnedSlotIndex = nil
        sessionState = .idle
    }

    // MARK: - Engine lifecycle

    @available(macOS 26, iOS 26, visionOS 26, *)
    private func startEngine(ownerID: UUID) async {
        guard await requestAuthorization() else { return }

        let capped = Self.resolveLocales(
            userSelection: userSelectedLocalesProvider?() ?? [],
            fallback: InputSourceLanguages.currentSpeechLocales()
        )

        let engine = DictationEngine()
        engine.onUpdate = { [weak self] update in
            self?.handleUpdate(update)
        }
        engine.onError = { [weak self] message in
            self?.surfaceError(message)
            self?.stop()
        }

        do {
            try await engine.start(locales: capped)
        } catch {
            surfaceError(error.localizedDescription)
            return
        }

        engineStorage = engine
        slotTranscripts = Array(repeating: "", count: engine.activeLocales.count)
        pinnedSlotIndex = nil
        sessionState = .listening(ownerID: ownerID, locales: engine.activeLocales)
        transcript = ""
    }

    // MARK: - Result handling

    @available(macOS 26, iOS 26, visionOS 26, *)
    private func handleUpdate(_ update: DictationEngine.TranscriptUpdate) {
        guard update.slotIndex < slotTranscripts.count else { return }

        // Honor `isFinal`: once any recognizer declares the utterance
        // complete, pin its transcript. Further partials from slower
        // recognizers will no longer overwrite the winning text.
        if update.isFinal, pinnedSlotIndex == nil {
            if !update.text.isEmpty {
                slotTranscripts[update.slotIndex] = update.text
            }
            pinnedSlotIndex = update.slotIndex
            transcript = slotTranscripts[update.slotIndex]
            return
        }

        if pinnedSlotIndex != nil { return }

        // Per-partial leader selection: Apple's per-locale recognizers
        // don't share an utterance, so whichever has produced the most
        // text right now wins — best approximation of language switching.
        slotTranscripts[update.slotIndex] = update.text
        transcript = Self.pickLeaderTranscript(transcripts: slotTranscripts)
    }

    /// Pure helper: picks the locale list to drive the engine. User selection
    /// from settings takes precedence; if unset, the system's preferred
    /// languages serve as fallback. Capped to `maxConcurrentRecognizers`.
    static func resolveLocales(userSelection: [Locale], fallback: [Locale]) -> [Locale] {
        let base = userSelection.isEmpty ? fallback : userSelection
        return Array(base.prefix(maxConcurrentRecognizers))
    }

    /// Returns the longest non-empty transcript across active slots. On
    /// ties, insertion order (slot index) is the stable tie-breaker —
    /// prevents flicker between equally-long recognizers.
    static func pickLeaderTranscript(transcripts: [String]) -> String {
        var bestIndex: Int?
        var bestLength = 0

        for index in transcripts.indices {
            let length = transcripts[index].count
            // Empty slots never win — a recognizer that hasn't emitted
            // yet would otherwise "beat" a slot with real content in the
            // first few ticks of a session.
            guard length > 0 else { continue }

            if bestIndex == nil || length > bestLength {
                bestIndex = index
                bestLength = length
            }
        }

        return bestIndex.map { transcripts[$0] } ?? ""
    }

    // MARK: - Error surfacing

    private func surfaceError(_ message: String) {
        lastErrorMessage = message
        onErrorSurfaced(message)
    }

    // MARK: - Test helpers

    #if DEBUG
    func _testSetErrorForPreview(_ message: String?) {
        lastErrorMessage = message
    }

    /// Exposes the private `surfaceError` for regression-pinning the
    /// callback wiring. Not intended for preview UI.
    func _testSurfaceError(_ message: String) {
        surfaceError(message)
    }

    /// Installs a pre-built engine and wires the onUpdate/onError callbacks
    /// so integration tests can drive `handleUpdate` + error-recovery paths
    /// end-to-end without real audio. Mirrors the wiring in `startEngine`.
    @available(macOS 26, iOS 26, visionOS 26, *)
    func _testInstallEngine(_ engine: any DictationEngineProtocol, ownerID: UUID) {
        engine.onUpdate = { [weak self] update in self?.handleUpdate(update) }
        engine.onError = { [weak self] message in
            self?.surfaceError(message)
            self?.stop()
        }
        engineStorage = engine
        slotTranscripts = Array(repeating: "", count: engine.activeLocales.count)
        pinnedSlotIndex = nil
        sessionState = .listening(ownerID: ownerID, locales: engine.activeLocales)
    }

    /// Installs N empty slots for exercising `handleUpdate` without a real
    /// audio engine. Does NOT mark `isListening = true`.
    func _testInstallSyntheticSlots(count: Int) {
        slotTranscripts = Array(repeating: "", count: count)
        pinnedSlotIndex = nil
    }

    /// Feeds a synthetic update into the handler to exercise the
    /// pinning/leader logic. Requires macOS 26+ at runtime.
    @available(macOS 26, iOS 26, visionOS 26, *)
    func _testHandleUpdate(text: String, isFinal: Bool, slotIndex: Int) {
        handleUpdate(DictationEngine.TranscriptUpdate(
            slotIndex: slotIndex,
            text: text,
            isFinal: isFinal
        ))
    }

    var _testPinnedSlotIndex: Int? { pinnedSlotIndex }
    var _testSlotTranscripts: [String] { slotTranscripts }
    #endif
}
