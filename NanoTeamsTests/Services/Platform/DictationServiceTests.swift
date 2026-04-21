import AVFoundation
import XCTest
@testable import NanoTeams

/// Exercises `DictationService`'s engine-consumer flow (onUpdate, onError,
/// stop, stopAndFlush) without any real audio / `SpeechAnalyzer`.
@available(macOS 26, iOS 26, visionOS 26, *)
@MainActor
final class FakeDictationEngine: DictationEngineProtocol {
    var onUpdate: ((DictationTranscriptUpdate) -> Void)?
    var onError: ((String) -> Void)?
    var activeLocales: [Locale]

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var stopAndFlushCallCount = 0
    var startError: Error?

    init(locales: [Locale]) {
        self.activeLocales = locales
    }

    func start(locales: [Locale]) async throws {
        startCallCount += 1
        activeLocales = locales
        if let error = startError { throw error }
    }
    func stop() { stopCallCount += 1 }
    func stopAndFlush() async { stopAndFlushCallCount += 1 }

    // Test helpers
    func fireUpdate(text: String, isFinal: Bool, slotIndex: Int) {
        onUpdate?(DictationTranscriptUpdate(slotIndex: slotIndex, text: text, isFinal: isFinal))
    }
    func fireError(_ message: String) {
        onError?(message)
    }
}

/// Drives `.authorized` / `.denied` / `.restricted` / `.notDetermined`
/// branches without touching real mic permissions.
final class FakeAuthProvider: MicrophoneAuthorizationProvider, @unchecked Sendable {
    var status: AVAuthorizationStatus
    var requestGrants: Bool
    private(set) var requestAccessCallCount = 0

    init(status: AVAuthorizationStatus, requestGrants: Bool = false) {
        self.status = status
        self.requestGrants = requestGrants
    }

    func currentStatus() -> AVAuthorizationStatus { status }
    func requestAccess() async -> Bool {
        requestAccessCallCount += 1
        return requestGrants
    }
}

/// Covers `DictationService` lifecycle and the `handleUpdate` state machine.
/// The audio engine itself is exercised via DEBUG seams (`_testInstallSyntheticSlots`,
/// `_testHandleUpdate`) — hitting a real mic + downloading models isn't CI-safe.
@MainActor
final class DictationServiceTests: XCTestCase {

    var sut: DictationService!

    override func setUp() {
        super.setUp()
        sut = DictationService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Lazy init

    func testInit_doesNotStartListening() async {
        XCTAssertFalse(sut.isListening)
        XCTAssertNil(sut.activeOwnerID)
        XCTAssertEqual(sut.transcript, "")
        XCTAssertTrue(sut.activeLocales.isEmpty)
        XCTAssertFalse(sut.isAuthorized)
        XCTAssertNil(sut.lastErrorMessage)
    }

    // MARK: - stop() idempotency

    func testStop_whenNotListening_isNoOp() async {
        sut.stop()
        XCTAssertFalse(sut.isListening)
        XCTAssertNil(sut.activeOwnerID)

        sut.stop()
        XCTAssertFalse(sut.isListening)
    }

    // MARK: - handleUpdate — leader selection

    func testHandleUpdate_longerTranscriptWins() async throws {
        guard #available(macOS 26, iOS 26, visionOS 26, *) else {
            throw XCTSkip("Dictation requires macOS 26+")
        }
        sut._testInstallSyntheticSlots(count: 2)
        sut._testHandleUpdate(text: "hi", isFinal: false, slotIndex: 0)
        sut._testHandleUpdate(text: "hello world", isFinal: false, slotIndex: 1)
        XCTAssertEqual(sut.transcript, "hello world")
    }

    func testHandleUpdate_equalLength_stableByInsertionOrder() async throws {
        guard #available(macOS 26, iOS 26, visionOS 26, *) else {
            throw XCTSkip("Dictation requires macOS 26+")
        }
        // Regression pin against the leader-flicker bug: with dict-based
        // iteration, two slots tied on length would flip winners between ticks.
        sut._testInstallSyntheticSlots(count: 2)
        sut._testHandleUpdate(text: "abc", isFinal: false, slotIndex: 0)
        sut._testHandleUpdate(text: "xyz", isFinal: false, slotIndex: 1)
        let firstPick = sut.transcript
        for _ in 0..<10 {
            sut._testHandleUpdate(text: "abc", isFinal: false, slotIndex: 0)
            sut._testHandleUpdate(text: "xyz", isFinal: false, slotIndex: 1)
            XCTAssertEqual(sut.transcript, firstPick, "Leader flicker: winner changed between identical inputs")
        }
    }

    // MARK: - handleUpdate — isFinal pinning

    func testHandleUpdate_isFinal_pinsWinnerAndIgnoresLaterPartials() async throws {
        guard #available(macOS 26, iOS 26, visionOS 26, *) else {
            throw XCTSkip("Dictation requires macOS 26+")
        }
        sut._testInstallSyntheticSlots(count: 2)
        sut._testHandleUpdate(text: "final answer", isFinal: true, slotIndex: 0)
        XCTAssertEqual(sut.transcript, "final answer")
        XCTAssertEqual(sut._testPinnedSlotIndex, 0)

        // A laggy recognizer now delivers a longer partial.
        // Pre-fix this would overwrite the finalized text. Now it's ignored.
        sut._testHandleUpdate(text: "a much longer overwriting partial", isFinal: false, slotIndex: 1)
        XCTAssertEqual(sut.transcript, "final answer", "isFinal winner must not be overwritten by later partials")
    }

    func testHandleUpdate_firstIsFinalWins_secondIsFinalIgnored() async throws {
        guard #available(macOS 26, iOS 26, visionOS 26, *) else {
            throw XCTSkip("Dictation requires macOS 26+")
        }
        sut._testInstallSyntheticSlots(count: 2)
        sut._testHandleUpdate(text: "first", isFinal: true, slotIndex: 0)
        sut._testHandleUpdate(text: "second much longer", isFinal: true, slotIndex: 1)
        XCTAssertEqual(sut.transcript, "first")
    }

    // MARK: - Edge cases

    func testHandleUpdate_outOfRangeSlotIndex_isIgnored() async throws {
        guard #available(macOS 26, iOS 26, visionOS 26, *) else {
            throw XCTSkip("Dictation requires macOS 26+")
        }
        sut._testInstallSyntheticSlots(count: 1)
        sut._testHandleUpdate(text: "bogus", isFinal: false, slotIndex: 99)
        XCTAssertEqual(sut.transcript, "")
    }

    // MARK: - Concurrency cap (regression pin)

    func testMaxConcurrentRecognizers_isThree() async {
        XCTAssertEqual(DictationService.maxConcurrentRecognizers, 3)
    }

    // MARK: - resolveLocales — user selection vs fallback

    private let en = Locale(identifier: "en_US")
    private let ru = Locale(identifier: "ru_RU")
    private let de = Locale(identifier: "de_DE")
    private let fr = Locale(identifier: "fr_FR")

    func testResolveLocales_userSelection_takesPrecedenceOverFallback() async {
        let resolved = DictationService.resolveLocales(
            userSelection: [ru],
            fallback: [en, de, fr]
        )
        XCTAssertEqual(resolved.map(\.identifier), ["ru_RU"])
    }

    func testResolveLocales_emptyUserSelection_fallsBackToPreferredLanguages() async {
        let resolved = DictationService.resolveLocales(
            userSelection: [],
            fallback: [en, ru]
        )
        XCTAssertEqual(resolved.map(\.identifier), ["en_US", "ru_RU"])
    }

    func testResolveLocales_capsToMaxConcurrentRecognizers() async {
        let many = [en, ru, de, fr, Locale(identifier: "es_ES"), Locale(identifier: "it_IT")]
        let resolved = DictationService.resolveLocales(userSelection: many, fallback: [])
        XCTAssertEqual(resolved.count, DictationService.maxConcurrentRecognizers)
        XCTAssertEqual(resolved.map(\.identifier), ["en_US", "ru_RU", "de_DE"])
    }

    func testResolveLocales_preservesInputOrder() async {
        // Selection order matters — it's the stable tie-breaker for the leader.
        let resolved = DictationService.resolveLocales(
            userSelection: [ru, en],
            fallback: []
        )
        XCTAssertEqual(resolved.map(\.identifier), ["ru_RU", "en_US"])
    }

    func testResolveLocales_bothEmpty_returnsEmpty() async {
        let resolved = DictationService.resolveLocales(userSelection: [], fallback: [])
        XCTAssertTrue(resolved.isEmpty)
    }

    // MARK: - pickLeaderTranscript — core behavior

    func testPickLeader_emptyInput_returnsEmpty() async {
        XCTAssertEqual(DictationService.pickLeaderTranscript(transcripts: []), "")
    }

    func testPickLeader_longestWins() async {
        let winner = DictationService.pickLeaderTranscript(
            transcripts: ["short", "much longer text"]
        )
        XCTAssertEqual(winner, "much longer text")
    }

    func testPickLeader_emptySlotsDoNotCompete() async {
        // Regression pin: empty slots previously could "win" the leader
        // selection via a bogus optimistic-language fallback, leaving the
        // user's text field blank.
        let winner = DictationService.pickLeaderTranscript(
            transcripts: ["", "Привет как дела", ""]
        )
        XCTAssertEqual(winner, "Привет как дела")
    }

    func testPickLeader_allEmpty_returnsEmpty() async {
        let winner = DictationService.pickLeaderTranscript(transcripts: ["", "", ""])
        XCTAssertEqual(winner, "")
    }

    func testPickLeader_stableTieBreakByInsertionOrder() async {
        // Equal length — slot 0 wins (no flicker between equally-confident
        // recognizers).
        let winner = DictationService.pickLeaderTranscript(transcripts: ["abc", "xyz"])
        XCTAssertEqual(winner, "abc")
    }

    func testPickLeader_onTheFlyLanguageSwitch_reevaluatesPerCall() async {
        // Mid-session the user switches from Russian to English. At t1 the
        // Russian slot has more text; at t2 the English slot has caught up.
        // No lock-in — each call re-evaluates, so the leader flips.
        let t1 = DictationService.pickLeaderTranscript(
            transcripts: ["Привет как дела сегодня", "now"]
        )
        XCTAssertEqual(t1, "Привет как дела сегодня")

        let t2 = DictationService.pickLeaderTranscript(
            transcripts: ["Привет как дела сегодня", "now I am switching and speaking English"]
        )
        XCTAssertEqual(t2, "now I am switching and speaking English")
    }

    // MARK: - userSelectedLocalesProvider integration

    func testProvider_isOptional_defaultsToNil() async {
        XCTAssertNil(sut.userSelectedLocalesProvider)
    }

    func testProvider_whenSet_isInvocable() async {
        var invocationCount = 0
        sut.userSelectedLocalesProvider = {
            invocationCount += 1
            return [Locale(identifier: "ru_RU")]
        }
        let result = sut.userSelectedLocalesProvider?() ?? []
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(result.map(\.identifier), ["ru_RU"])
    }

    // MARK: - Authorization matrix

    func testRequestAuthorization_whenAuthorized_returnsTrueNoError() async {
        let fake = FakeAuthProvider(status: .authorized)
        let service = DictationService(authProvider: fake)
        let granted = await service.requestAuthorization()
        XCTAssertTrue(granted)
        XCTAssertEqual(service.authorization, .granted)
        XCTAssertTrue(service.isAuthorized)
        XCTAssertNil(service.lastErrorMessage)
        XCTAssertEqual(fake.requestAccessCallCount, 0, "Already-authorized path must not re-prompt")
    }

    func testRequestAuthorization_whenDenied_surfacesGenericMessage() async {
        let fake = FakeAuthProvider(status: .denied)
        var received: [String] = []
        let service = DictationService(
            onErrorSurfaced: { received.append($0) },
            authProvider: fake
        )
        let granted = await service.requestAuthorization()
        XCTAssertFalse(granted)
        XCTAssertEqual(service.authorization, .denied)
        XCTAssertFalse(service.isAuthorized)
        XCTAssertEqual(
            service.lastErrorMessage,
            "Microphone access is required. Enable it in System Settings → Privacy & Security → Microphone."
        )
        XCTAssertEqual(received.count, 1, "Callback must fire so the global banner shows")
    }

    func testRequestAuthorization_whenRestricted_surfacesDevicePolicyMessage() async {
        let fake = FakeAuthProvider(status: .restricted)
        let service = DictationService(authProvider: fake)
        let granted = await service.requestAuthorization()
        XCTAssertFalse(granted)
        XCTAssertEqual(service.authorization, .restricted)
        XCTAssertEqual(
            service.lastErrorMessage,
            "Microphone access is restricted by your device policy."
        )
    }

    func testRequestAuthorization_whenNotDetermined_prompts() async {
        let fake = FakeAuthProvider(status: .notDetermined, requestGrants: true)
        let service = DictationService(authProvider: fake)
        let granted = await service.requestAuthorization()
        XCTAssertTrue(granted)
        XCTAssertEqual(service.authorization, .granted)
        XCTAssertEqual(fake.requestAccessCallCount, 1)
    }

    func testRequestAuthorization_whenNotDeterminedThenDenied_surfaces() async {
        let fake = FakeAuthProvider(status: .notDetermined, requestGrants: false)
        let service = DictationService(authProvider: fake)
        let granted = await service.requestAuthorization()
        XCTAssertFalse(granted)
        // Post-prompt denial lands as `.denied`, NOT `.notDetermined` — the
        // user has made a choice and subsequent taps should show the same
        // "enable in System Settings" message as a cold-start `.denied`.
        XCTAssertEqual(service.authorization, .denied)
        XCTAssertEqual(
            service.lastErrorMessage,
            "Microphone access is required. Enable it in System Settings → Privacy & Security → Microphone."
        )
    }

    func testMicrophoneAuthorization_mapsFromAVStatus() {
        XCTAssertEqual(MicrophoneAuthorization(.authorized), .granted)
        XCTAssertEqual(MicrophoneAuthorization(.denied), .denied)
        XCTAssertEqual(MicrophoneAuthorization(.restricted), .restricted)
        XCTAssertEqual(MicrophoneAuthorization(.notDetermined), .notDetermined)
    }

    // MARK: - Engine integration (via fake)

    @available(macOS 26, iOS 26, visionOS 26, *)
    func testEngineError_callsSurfaceErrorAndStops() async {
        var received: [String] = []
        let service = DictationService(onErrorSurfaced: { received.append($0) })
        let fake = FakeDictationEngine(locales: [Locale(identifier: "en_US")])
        let owner = UUID()
        service._testInstallEngine(fake, ownerID: owner)
        XCTAssertTrue(service.isListening)

        fake.fireError("converter blew up")

        XCTAssertFalse(service.isListening, "engine error must stop the service")
        XCTAssertNil(service.activeOwnerID)
        XCTAssertEqual(service.lastErrorMessage, "converter blew up")
        XCTAssertEqual(received, ["converter blew up"])
    }

    @available(macOS 26, iOS 26, visionOS 26, *)
    func testEngineUpdates_flowIntoTranscript() async {
        let service = DictationService()
        let fake = FakeDictationEngine(locales: [Locale(identifier: "en_US"), Locale(identifier: "ru_RU")])
        service._testInstallEngine(fake, ownerID: UUID())

        fake.fireUpdate(text: "hello", isFinal: false, slotIndex: 0)
        XCTAssertEqual(service.transcript, "hello")

        fake.fireUpdate(text: "привет как дела сегодня", isFinal: false, slotIndex: 1)
        XCTAssertEqual(service.transcript, "привет как дела сегодня", "leader selection picks the longer transcript")
    }

    @available(macOS 26, iOS 26, visionOS 26, *)
    func testStop_invokesEngineStop() async {
        let service = DictationService()
        let fake = FakeDictationEngine(locales: [Locale(identifier: "en_US")])
        service._testInstallEngine(fake, ownerID: UUID())

        service.stop()

        XCTAssertEqual(fake.stopCallCount, 1, "service.stop() must call through to engine.stop()")
        XCTAssertFalse(service.isListening)
    }

    // MARK: - Error surfacing

    func testSurfaceError_setsLastErrorAndFiresCallback() async {
        // Pins the `onErrorSurfaced` wiring: anything that reaches
        // `surfaceError` must also forward to the injected callback so
        // the global `ErrorBannerView` fires.
        var received: [String] = []
        let service = DictationService(onErrorSurfaced: { received.append($0) })
        service._testSurfaceError("boom")
        XCTAssertEqual(service.lastErrorMessage, "boom")
        XCTAssertEqual(received, ["boom"])
    }

    // MARK: - Start without permissions (CI-safe)

    func testStart_withoutPermissions_doesNotLeakListeningState() async {
        let owner = UUID()
        await sut.start(ownerID: owner)

        if sut.isListening {
            // If permissions + model happen to be available on this host,
            // validate invariants then stop.
            XCTAssertEqual(sut.activeOwnerID, owner)
            XCTAssertFalse(sut.activeLocales.isEmpty)
            sut.stop()
            XCTAssertFalse(sut.isListening)
            XCTAssertNil(sut.activeOwnerID)
        } else {
            XCTAssertNil(sut.activeOwnerID)
            XCTAssertTrue(sut.activeLocales.isEmpty)
        }
    }

    // MARK: - Toggle

    func testToggle_whenSameOwnerListening_stops() async throws {
        let owner = UUID()
        await sut.start(ownerID: owner)
        guard sut.isListening else {
            throw XCTSkip("Dictation not available in this environment.")
        }
        await sut.toggle(ownerID: owner)
        XCTAssertFalse(sut.isListening)
        XCTAssertNil(sut.activeOwnerID)
    }

    // MARK: - Preview helper

    func testTestHelper_setsAndClearsErrorMessage() async {
        sut._testSetErrorForPreview("boom")
        XCTAssertEqual(sut.lastErrorMessage, "boom")
        sut._testSetErrorForPreview(nil)
        XCTAssertNil(sut.lastErrorMessage)
    }
}
