import AVFoundation
import XCTest
@testable import NanoTeams

/// Session-lifecycle coverage for `DictationService`: the `flushAndThen`
/// non-idle branch, the `toggle` matrix, the reentrancy guard on `start`, the
/// engine-failure path through `startEngine`, and the terminal-update corners
/// of `handleUpdate`.
///
/// Reuses `FakeDictationEngine` / `FakeAuthProvider` from `DictationServiceTests`
/// (both are `internal`, same test module) so the fake engine's behaviour stays
/// defined in one place.
///
/// Safety: the only locale ever handed to a real `DictationEngine` here is
/// `xx_ZZ`, which `AssetInventory` reports `.unsupported` on every machine —
/// `start` throws before an `AVAudioEngine` is constructed, so no microphone is
/// opened and no model is downloaded.
@MainActor
final class DictationServiceSessionLifecycleTests: XCTestCase {

    private let en = Locale(identifier: "en_US")
    private let ru = Locale(identifier: "ru_RU")
    /// Syntactically valid but non-existent — always `.unsupported`.
    private let unusable = Locale(identifier: "xx_ZZ")

    private func skipIfUnavailable() throws {
        guard #unavailable(macOS 26, iOS 26, visionOS 26) else { return }
        throw XCTSkip("Dictation requires macOS 26+.")
    }

    // MARK: - flushAndThen (non-idle branch)

    /// Captures what the submit action observed at the moment it ran. The
    /// closure is `@Sendable`, so the recorder has to be a Sendable reference
    /// rather than a captured `var`.
    private final class FlushProbe: @unchecked Sendable {
        let ran = XCTestExpectation(description: "flushAndThen action ran")
        private let lock = NSLock()
        private var listening: Bool?
        private var text: String?

        func record(listening: Bool, text: String) {
            lock.withLock {
                self.listening = listening
                self.text = text
            }
            ran.fulfill()
        }

        var listeningAtRun: Bool? { lock.withLock { listening } }
        var textAtRun: String? { lock.withLock { text } }
    }

    /// The submit path must FLUSH (wait for the analyzer's last words) rather
    /// than hard-stop, and the action must see a session that is already reset —
    /// otherwise a send handler that re-reads `isListening` would think dictation
    /// is still running.
    func testFlushAndThen_whileListening_flushesTheEngineThenRunsTheAction() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let service = DictationService()
        let fake = FakeDictationEngine(locales: [en, ru])
        service._testInstallEngine(fake, ownerID: UUID())
        fake.fireUpdate(text: "hello world", isFinal: false, slotIndex: 0)

        let probe = FlushProbe()
        service.flushAndThen {
            probe.record(listening: service.isListening, text: service.transcript)
        }
        await fulfillment(of: [probe.ran], timeout: 5.0)

        XCTAssertEqual(fake.stopAndFlushCallCount, 1, "submit must go through the flushing teardown")
        XCTAssertEqual(fake.stopCallCount, 0, "submit must not use the transcript-dropping stop()")
        XCTAssertEqual(probe.listeningAtRun, false, "the session must be reset before the action runs")
        XCTAssertEqual(
            probe.textAtRun,
            "hello world",
            "the transcript must outlive the reset — it is the whole payload the submit is carrying"
        )
        XCTAssertFalse(service.isListening)
        XCTAssertNil(service.activeOwnerID)
    }

    /// Second submit after the session is already gone takes the synchronous
    /// idle fast path and must not touch the (now detached) engine again.
    func testFlushAndThen_calledAgainAfterFlushing_takesTheIdleFastPath() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let service = DictationService()
        let fake = FakeDictationEngine(locales: [en])
        service._testInstallEngine(fake, ownerID: UUID())

        let probe = FlushProbe()
        service.flushAndThen { probe.record(listening: service.isListening, text: service.transcript) }
        await fulfillment(of: [probe.ran], timeout: 5.0)

        var ranSynchronously = false
        service.flushAndThen { ranSynchronously = true }

        XCTAssertTrue(ranSynchronously, "an already-flushed service is idle and must not hop through a Task")
        XCTAssertEqual(fake.stopAndFlushCallCount, 1, "the detached engine must not be flushed twice")
    }

    // MARK: - toggle

    func testToggle_sameOwnerWhileListening_stopsTheSession() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let service = DictationService()
        let fake = FakeDictationEngine(locales: [en])
        let owner = UUID()
        service._testInstallEngine(fake, ownerID: owner)

        await service.toggle(ownerID: owner)

        XCTAssertEqual(fake.stopCallCount, 1)
        XCTAssertEqual(fake.stopAndFlushCallCount, 0, "toggle-off discards the transcript by design")
        XCTAssertFalse(service.isListening)
        XCTAssertNil(service.activeOwnerID)
    }

    /// A second surface grabbing the mic must tear the incumbent session down
    /// first — `AVAudioEngine` owns a single hardware input node, so two live
    /// sessions cannot coexist.
    func testToggle_differentOwnerWhileListening_stopsTheIncumbentFirst() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        var received: [String] = []
        let service = DictationService(
            onErrorSurfaced: { received.append($0) },
            authProvider: FakeAuthProvider(status: .authorized)
        )
        // Empty selection makes the follow-on start bail deterministically,
        // right after the incumbent teardown we are pinning.
        service.userSelectedLocalesProvider = { [] }
        let fake = FakeDictationEngine(locales: [en])
        service._testInstallEngine(fake, ownerID: UUID())

        await service.toggle(ownerID: UUID())

        XCTAssertEqual(fake.stopCallCount, 1, "the incumbent owner's engine must be stopped before a new owner starts")
        XCTAssertFalse(service.isListening)
        XCTAssertEqual(received.count, 1, "the new owner's start still reports why it could not run")
    }

    func testToggle_whenIdle_routesToStart() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        var received: [String] = []
        let service = DictationService(
            onErrorSurfaced: { received.append($0) },
            authProvider: FakeAuthProvider(status: .authorized)
        )
        service.userSelectedLocalesProvider = { [] }

        await service.toggle(ownerID: UUID())

        XCTAssertEqual(received.count, 1, "toggle from idle must attempt a start, not silently no-op")
        XCTAssertFalse(service.isListening)
    }

    // MARK: - startEngine failure path

    /// The engine's own `noInstalledModel` failure has to reach the user
    /// verbatim (it names Settings → Dictation), and must leave no half-open
    /// session behind.
    func testStart_whenNoModelIsInstalled_surfacesTheEngineErrorAndStaysIdle() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        var received: [String] = []
        let service = DictationService(
            onErrorSurfaced: { received.append($0) },
            authProvider: FakeAuthProvider(status: .authorized)
        )
        service.userSelectedLocalesProvider = { [self.unusable] }

        await service.start(ownerID: UUID())

        XCTAssertFalse(service.isListening)
        XCTAssertNil(service.activeOwnerID)
        XCTAssertTrue(service.activeLocales.isEmpty)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(
            service.lastErrorMessage,
            DictationEngine.EngineError.noInstalledModel.errorDescription
        )
    }

    /// Permission is requested only AFTER the locale selection is known to be
    /// usable — prompting for the mic and then failing on a different error is
    /// the worse of the two orderings.
    func testStart_withNoLocalesSelected_neverReachesTheAuthProvider() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let auth = FakeAuthProvider(status: .notDetermined, requestGrants: true)
        let service = DictationService(authProvider: auth)
        service.userSelectedLocalesProvider = { [] }

        await service.start(ownerID: UUID())

        XCTAssertEqual(auth.requestAccessCallCount, 0, "no mic prompt before the language is even chosen")
        XCTAssertFalse(service.isListening)
    }

    // MARK: - Reentrancy guard

    private actor StartGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Parks `start` inside the permission request so a second call lands while
    /// the first is still in flight.
    private final class GatedAuthProvider: MicrophoneAuthorizationProvider, @unchecked Sendable {
        let gate = StartGate()
        let entered = XCTestExpectation(description: "requestAccess entered")
        private let lock = NSLock()
        private var count = 0
        var callCount: Int { lock.withLock { count } }

        func currentStatus() -> AVAuthorizationStatus { .notDetermined }

        func requestAccess() async -> Bool {
            lock.withLock { count += 1 }
            // Over-fulfilment (a second entry) fails the test — which is
            // exactly the regression this guards.
            entered.fulfill()
            await gate.wait()
            return true
        }
    }

    /// The mic button's `toggle()` can fire twice while the first `start` is
    /// still awaiting mic authorization. Without `isStartingUp`, the second call
    /// spins up a parallel engine and every subsequent transcript update is
    /// delivered twice.
    func testStart_whileAnotherStartIsInFlight_isIgnored() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let auth = GatedAuthProvider()
        var received: [String] = []
        let service = DictationService(onErrorSurfaced: { received.append($0) }, authProvider: auth)
        service.userSelectedLocalesProvider = { [self.unusable] }

        let first = Task { await service.start(ownerID: UUID()) }
        await fulfillment(of: [auth.entered], timeout: 5.0)

        await service.start(ownerID: UUID())

        XCTAssertEqual(auth.callCount, 1, "the reentrant start must not reach the auth provider a second time")
        XCTAssertTrue(received.isEmpty, "the ignored start stays silent — it is a double tap, not a failure")

        await auth.gate.open()
        await first.value

        XCTAssertEqual(received.count, 1, "only the in-flight start reports its outcome")
        XCTAssertFalse(service.isListening)
    }

    // MARK: - handleUpdate: terminal (isFinal) updates

    /// `DictationEngine`'s consumer task emits `(text: "", isFinal: true)` when
    /// a transcriber's result stream ends — including for a recognizer that
    /// heard nothing at all.
    ///
    /// Scenario: the user selected [en_US, ru_RU] and spoke Russian. On submit,
    /// `stopAndFlush` finishes every continuation; the English stream — with
    /// nothing to flush — ends first and delivers its terminal empty update.
    /// Pinning that slot would publish "" and lock out the Russian recognizer
    /// that holds the user's actual words, silently erasing the dictation at the
    /// exact moment it is being sent.
    func testHandleUpdate_terminalEmptyFromASilentSlot_doesNotWipeASiblingsTranscript() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let service = DictationService()
        service._testInstallSyntheticSlots(count: 2)
        service._testHandleUpdate(text: "Привет как дела", isFinal: false, slotIndex: 1)
        XCTAssertEqual(service.transcript, "Привет как дела")

        service._testHandleUpdate(text: "", isFinal: true, slotIndex: 0)

        XCTAssertEqual(
            service.transcript,
            "Привет как дела",
            "a recognizer that heard nothing must not erase the one that did"
        )
    }

    /// The other half of the same rule: an empty terminal must not PIN either,
    /// or the slot that actually has the words can never finalize.
    func testHandleUpdate_terminalEmptyFromASilentSlot_leavesTheRealFinalAbleToWin() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let service = DictationService()
        service._testInstallSyntheticSlots(count: 2)
        service._testHandleUpdate(text: "Привет как дела", isFinal: false, slotIndex: 1)
        service._testHandleUpdate(text: "", isFinal: true, slotIndex: 0)

        XCTAssertNil(service._testPinnedSlotIndex, "an empty terminal must not claim the session")

        service._testHandleUpdate(text: "Привет как дела сегодня", isFinal: true, slotIndex: 1)

        XCTAssertEqual(service._testPinnedSlotIndex, 1)
        XCTAssertEqual(service.transcript, "Привет как дела сегодня")
    }

    /// The ordinary single-locale path: partials accumulate, then the stream
    /// ends with an empty terminal. The accumulated text is the final answer and
    /// must be pinned — this is what makes the empty terminal meaningful at all.
    func testHandleUpdate_terminalEmptyOnASlotWithPartials_pinsThosePartials() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let service = DictationService()
        service._testInstallSyntheticSlots(count: 1)
        service._testHandleUpdate(text: "send this message", isFinal: false, slotIndex: 0)
        service._testHandleUpdate(text: "", isFinal: true, slotIndex: 0)

        XCTAssertEqual(service.transcript, "send this message")
        XCTAssertEqual(service._testPinnedSlotIndex, 0)

        service._testHandleUpdate(text: "a later straggling partial", isFinal: false, slotIndex: 0)
        XCTAssertEqual(service.transcript, "send this message", "the pinned final must survive stragglers")
    }

    func testHandleUpdate_terminalEmptyWithEverySlotSilent_leavesTranscriptEmpty() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let service = DictationService()
        service._testInstallSyntheticSlots(count: 2)
        service._testHandleUpdate(text: "", isFinal: true, slotIndex: 0)
        service._testHandleUpdate(text: "", isFinal: true, slotIndex: 1)

        XCTAssertEqual(service.transcript, "", "nobody spoke — there is nothing to publish")
    }

    /// Whitespace is not emptiness: a recognizer that emits only a space has
    /// produced content as far as the leader rule is concerned, and pinning it
    /// is the honest outcome rather than a special case.
    func testHandleUpdate_terminalWhitespaceOnly_isTreatedAsContent() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let service = DictationService()
        service._testInstallSyntheticSlots(count: 1)
        service._testHandleUpdate(text: " ", isFinal: true, slotIndex: 0)

        XCTAssertEqual(service.transcript, " ")
        XCTAssertEqual(service._testPinnedSlotIndex, 0)
    }

    func testHandleUpdate_negativeSlotIndex_isIgnored() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let service = DictationService()
        service._testInstallSyntheticSlots(count: 1)
        service._testHandleUpdate(text: "seed", isFinal: false, slotIndex: 0)
        service._testHandleUpdate(text: "bogus", isFinal: true, slotIndex: -1)

        XCTAssertEqual(service.transcript, "seed")
        XCTAssertNil(service._testPinnedSlotIndex)
    }

    /// With no slots installed at all every update is out of range — the guard
    /// has to hold before `_testInstallEngine`/`startEngine` has sized the array.
    func testHandleUpdate_withNoSlots_isIgnored() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let service = DictationService()
        service._testInstallSyntheticSlots(count: 0)
        service._testHandleUpdate(text: "anything", isFinal: true, slotIndex: 0)

        XCTAssertEqual(service.transcript, "")
        XCTAssertNil(service._testPinnedSlotIndex)
    }

    // MARK: - Session state

    func testSessionState_distinguishesOwnersAndLocales() async {
        let owner = UUID()
        XCTAssertEqual(
            DictationService.SessionState.listening(ownerID: owner, locales: [en]),
            .listening(ownerID: owner, locales: [en])
        )
        XCTAssertNotEqual(
            DictationService.SessionState.listening(ownerID: owner, locales: [en]),
            .listening(ownerID: UUID(), locales: [en])
        )
        XCTAssertNotEqual(
            DictationService.SessionState.listening(ownerID: owner, locales: [en]),
            .listening(ownerID: owner, locales: [ru])
        )
        XCTAssertNotEqual(DictationService.SessionState.idle, .listening(ownerID: owner, locales: [en]))
    }

    func testStop_whileListening_clearsOwnerAndLocales() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let service = DictationService()
        let fake = FakeDictationEngine(locales: [en, ru])
        service._testInstallEngine(fake, ownerID: UUID())
        XCTAssertEqual(service.activeLocales, [en, ru])

        service.stop()

        XCTAssertEqual(service.sessionState, .idle)
        XCTAssertNil(service.activeOwnerID)
        XCTAssertTrue(service.activeLocales.isEmpty)
    }

    // MARK: - System authorization provider

    /// `AVCaptureDevice.authorizationStatus(for:)` is a pure query — it never
    /// prompts — so the real provider's read path is safe to exercise. Only
    /// `requestAccess()` can raise the TCC dialog, and it is never called here.
    func testSystemAuthorizationProvider_currentStatus_isReadableWithoutPrompting() async {
        let provider = SystemMicrophoneAuthorizationProvider()
        let status = provider.currentStatus()

        XCTAssertEqual(status, AVCaptureDevice.authorizationStatus(for: .audio))
        XCTAssertEqual(
            MicrophoneAuthorization(status),
            MicrophoneAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
        )
    }
}
