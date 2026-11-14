import XCTest

@testable import NanoTeams

/// A `HotkeyManager` double, so `wire` does not claim ⌃⌥⌘0 system-wide for the duration
/// of the test run — `setup` registers real Carbon hotkeys, and a claimed combo is taken
/// from the developer's machine until the process exits.
@MainActor
private final class NoOpHotkeyManager: HotkeyManager {
    private(set) var registeredKeyCodes: [UInt32] = []
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        registeredKeyCodes.append(keyCode)
        return true
    }
}

/// Covers `AppDependencyWiring`, extracted from `NanoTeamsApp.body`'s `.onAppear`.
///
/// That closure is dead under XCTest by construction: `body` short-circuits to
/// `Color.clear` when `isRunningTests`, so the entire `else` branch never ran and every
/// hand-off inside it shipped unverified. Two of them are load-bearing in ways that fail
/// silently:
///
/// - `store.quickCaptureFormState` is the bridge `consumeQueuedSupervisorMessage` drains.
///   Left nil, every message the user queues is dropped on the role's next iteration with
///   no error — the message simply never arrives.
/// - both providers are CLOSURES on purpose, so a Settings change mid-session is picked
///   up. Installed as resolved snapshots they would freeze at launch, and the LLM status
///   pill would poll the previous server forever after a provider flip.
@MainActor
final class AppDependencyWiringTests: XCTestCase {

    private var store: NTMSOrchestrator!
    private var dictation: DictationService!
    private var monitor: LLMStatusMonitor!
    private var quickCapture: QuickCaptureController!

    override func tearDown() async throws {
        monitor?.stopMonitoring()
        monitor = nil
        dictation = nil
        quickCapture = nil
        store = nil
        try await super.tearDown()
    }

    private func makeSubjects() async {
        store = TestOrchestrator.make()
        dictation = DictationService()
        monitor = LLMStatusMonitor()
        quickCapture = QuickCaptureController(
            hotkeyManager: NoOpHotkeyManager(),
            formState: QuickCaptureFormState(),
            selectionCapturer: InertSelectionCapturer()
        )
    }

    // MARK: - The providers

    /// RED: return a resolved `[Locale]` instead of a closure (or capture the identifiers
    /// eagerly) → the second assertion fails, and a language the user adds in Settings
    /// never reaches dictation until a relaunch.
    func testDictationLocaleProvider_readsTheStoreOnEveryCall() async {
        await makeSubjects()
        store.configuration.dictationLocaleIdentifiers = ["en-US"]

        let provider = AppDependencyWiring.dictationLocaleProvider(store: store)
        XCTAssertEqual(provider().map(\.identifier), ["en-US"])

        store.configuration.dictationLocaleIdentifiers = ["en-US", "ru-RU"]
        XCTAssertEqual(provider().map(\.identifier), ["en-US", "ru-RU"],
                       "the provider must re-read — a snapshot freezes at launch-time "
                           + "locales and a language added in Settings never arrives")
    }

    /// An empty selection is a real state, and the one the mic button branches on
    /// (`hasUserSelectedLocales` decides between "start dictation" and "send the user to
    /// Settings"). It must map to an empty array, not to a default locale.
    ///
    /// RED: fall back to `[Locale.current]` when the list is empty → this fails and the
    /// mic button silently dictates in the system language the user did not pick.
    func testDictationLocaleProvider_noSelection_yieldsNoLocales() async {
        await makeSubjects()
        store.configuration.dictationLocaleIdentifiers = []

        XCTAssertTrue(AppDependencyWiring.dictationLocaleProvider(store: store)().isEmpty,
                      "no selection must stay empty so the mic button routes to Settings")
    }

    /// RED: capture `(baseURL, provider)` eagerly outside the closure → the post-change
    /// assertion fails, and the reachability pill probes the old server forever.
    func testLLMEndpointProvider_readsBothHalvesOnEveryCall() async {
        await makeSubjects()
        store.configuration.llmBaseURLString = "http://127.0.0.1:1234"
        store.configuration.llmProvider = .lmStudio

        let provider = AppDependencyWiring.llmEndpointProvider(store: store)
        var endpoint = provider()
        XCTAssertEqual(endpoint.baseURL, "http://127.0.0.1:1234")
        XCTAssertEqual(endpoint.provider, .lmStudio)

        store.configuration.llmProvider = .ollama
        store.configuration.llmBaseURLString = "http://127.0.0.1:11434"
        endpoint = provider()
        XCTAssertEqual(endpoint.provider, .ollama,
                       "the provider must travel with the URL — a stale provider probes "
                           + "the wrong reachability path (api/v1/models vs api/tags)")
        XCTAssertEqual(endpoint.baseURL, "http://127.0.0.1:11434")
    }

    /// RED: return `monitor.isReachable` without the first-probe guard → the first assertion
    /// fails, and `folder_status` tells an external agent the LLM server is down before
    /// anything has asked it.
    func testLLMReachabilityProvider_isUnknownUntilTheFirstProbe_thenFollowsTheMonitor() async {
        await makeSubjects()
        let provider = AppDependencyWiring.llmReachabilityProvider(monitor: monitor)
        let initial = await provider()
        XCTAssertNil(initial.reachable, "no probe yet — unknown, not unreachable")

        monitor.noteReachable()

        let after = await provider()
        XCTAssertEqual(after.reachable, true)
        XCTAssertNotNil(after.checkedAt)
    }

    // MARK: - 30s Cache Staleness Threshold (§6.9, [A10, C20, D12])

    private final class CountingSession: NetworkSession, @unchecked Sendable {
        private let lock = NSLock()
        private var _requestCount = 0

        var requestCount: Int { lock.withLock { _requestCount } }

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.withLock { _requestCount += 1 }
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1:1234")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("{\"data\":[]}".utf8), response)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    func testLLMReachabilityProvider_whenCacheFresh_doesNotProbe() async {
        let session = CountingSession()
        let customMonitor = LLMStatusMonitor(session: session)
        customMonitor.startMonitoring(endpointProvider: { ("http://127.0.0.1:1234", .lmStudio) })
        defer { customMonitor.stopMonitoring() }

        customMonitor.noteReachable()
        // The moment the monitor recorded, not one read before it: `Date()` taken first left the
        // "boundary" interval short of 30 s, and `> 30` → `>= 30` survived (F6 T13).
        guard let t0 = customMonitor.lastCheckedAt else { return XCTFail("noteReachable records the check") }

        let provider = AppDependencyWiring.llmReachabilityProvider(
            monitor: customMonitor,
            now: { t0.addingTimeInterval(25) }
        )
        let res = await provider()
        XCTAssertEqual(session.requestCount, 0, "fresh cache <= 30s must not trigger probe")
        XCTAssertEqual(res.reachable, true)
    }

    func testLLMReachabilityProvider_whenCacheAt30sBoundary_doesNotProbe() async {
        let session = CountingSession()
        let customMonitor = LLMStatusMonitor(session: session)
        customMonitor.startMonitoring(endpointProvider: { ("http://127.0.0.1:1234", .lmStudio) })
        defer { customMonitor.stopMonitoring() }

        customMonitor.noteReachable()
        // The moment the monitor recorded, not one read before it: `Date()` taken first left the
        // "boundary" interval short of 30 s, and `> 30` → `>= 30` survived (F6 T13).
        guard let t0 = customMonitor.lastCheckedAt else { return XCTFail("noteReachable records the check") }

        let provider = AppDependencyWiring.llmReachabilityProvider(
            monitor: customMonitor,
            now: { t0.addingTimeInterval(30.0) }
        )
        let res = await provider()
        XCTAssertEqual(session.requestCount, 0, "cache exactly at 30.0s boundary must not trigger probe")
        XCTAssertEqual(res.reachable, true)
    }

    func testLLMReachabilityProvider_whenCacheStaleOver30s_triggersProbe() async {
        let session = CountingSession()
        let customMonitor = LLMStatusMonitor(session: session)
        customMonitor.startMonitoring(endpointProvider: { ("http://127.0.0.1:1234", .lmStudio) })
        defer { customMonitor.stopMonitoring() }

        customMonitor.noteReachable()
        // The moment the monitor recorded, not one read before it: `Date()` taken first left the
        // "boundary" interval short of 30 s, and `> 30` → `>= 30` survived (F6 T13).
        guard let t0 = customMonitor.lastCheckedAt else { return XCTFail("noteReachable records the check") }

        let provider = AppDependencyWiring.llmReachabilityProvider(
            monitor: customMonitor,
            now: { t0.addingTimeInterval(35) }
        )
        let res = await provider()
        XCTAssertEqual(session.requestCount, 1, "cache > 30s must trigger probe via checkNow")
        XCTAssertEqual(res.reachable, true)
    }

    func testLLMReachabilityProvider_whenUninitialized_triggersProbe() async {
        let session = CountingSession()
        let customMonitor = LLMStatusMonitor(session: session)
        customMonitor.startMonitoring(endpointProvider: { ("http://127.0.0.1:1234", .lmStudio) })
        defer { customMonitor.stopMonitoring() }

        let provider = AppDependencyWiring.llmReachabilityProvider(
            monitor: customMonitor,
            now: { Date() }
        )
        let res = await provider()
        XCTAssertEqual(session.requestCount, 1, "uninitialized monitor (lastCheckedAt == nil) must trigger probe")
        XCTAssertEqual(res.reachable, true)
    }

    // MARK: - wire

    /// RED: delete the `store.llmReachability = …` line → this fails, and `folder_status`
    /// never reports whether the LLM server answered.
    func testWire_installsTheLLMReachabilityReader() async {
        await makeSubjects()
        let initial = await store.llmReachability()
        XCTAssertNil(initial.reachable, "nothing is wired yet")

        AppDependencyWiring.wire(store: store, dictation: dictation,
                                 quickCapture: quickCapture, statusMonitor: monitor)
        monitor.stopMonitoring()
        monitor.noteReachable()

        let after = await store.llmReachability()
        XCTAssertEqual(after.reachable, true)
    }

    /// RED: delete the `store.quickCaptureFormState = quickCapture.formState` line → this
    /// fails, and every queued Supervisor message is silently dropped.
    func testWire_bridgesTheQueueIntoTheOrchestrator() async {
        await makeSubjects()
        XCTAssertNil(store.quickCaptureFormState, "nothing is wired yet")

        AppDependencyWiring.wire(store: store, dictation: dictation,
                                 quickCapture: quickCapture, statusMonitor: monitor)
        monitor.stopMonitoring()

        XCTAssertTrue(store.quickCaptureFormState === quickCapture.formState,
                      "the orchestrator must hold the SAME form state the panel writes "
                          + "into, not a second instance")
    }

    /// RED: delete the `dictation.userSelectedLocalesProvider = ...` line → this fails and
    /// dictation starts with no locales for every user.
    func testWire_installsTheDictationLocaleProvider() async {
        await makeSubjects()
        store.configuration.dictationLocaleIdentifiers = ["de-DE"]
        XCTAssertNil(dictation.userSelectedLocalesProvider)

        AppDependencyWiring.wire(store: store, dictation: dictation,
                                 quickCapture: quickCapture, statusMonitor: monitor)
        monitor.stopMonitoring()

        XCTAssertEqual(dictation.userSelectedLocalesProvider?().map(\.identifier), ["de-DE"])
        XCTAssertTrue(dictation.hasUserSelectedLocales,
                      "the installed provider is what `hasUserSelectedLocales` reads")
    }

    /// RED: delete the `quickCapture.setup(...)` line → the hotkeys are never registered
    /// and both assertions fail: ⌃⌥⌘0 and ⌃⌥⌘K do nothing for every user.
    func testWire_setsUpQuickCapture() async {
        await makeSubjects()
        XCTAssertFalse(quickCapture.didSetupHotkeys)

        AppDependencyWiring.wire(store: store, dictation: dictation,
                                 quickCapture: quickCapture, statusMonitor: monitor)
        monitor.stopMonitoring()

        XCTAssertTrue(quickCapture.didSetupHotkeys, "the global shortcuts must be claimed")
        XCTAssertTrue(quickCapture.store === store,
                      "setup must hand the controller the same store")
        XCTAssertTrue(quickCapture.dictation === dictation)
    }

    /// The whole block is one unit — a partially-wired app is the shape that produced the
    /// silent failures above, so assert every hand-off from a single `wire` call.
    ///
    /// `stopMonitoring()` runs synchronously right after `wire` on the same actor, so the
    /// poll `Task`'s body has not started yet and no network probe is issued: `Task { }`
    /// cannot begin until the current synchronous run yields.
    func testWire_installsEverythingAtOnce() async {
        await makeSubjects()
        store.configuration.dictationLocaleIdentifiers = ["fr-FR"]

        AppDependencyWiring.wire(store: store, dictation: dictation,
                                 quickCapture: quickCapture, statusMonitor: monitor)
        monitor.stopMonitoring()

        XCTAssertTrue(quickCapture.didSetupHotkeys)
        XCTAssertNotNil(store.quickCaptureFormState)
        XCTAssertNotNil(dictation.userSelectedLocalesProvider)
        XCTAssertFalse(monitor.isReachable,
                       "no probe completed — the monitor was cancelled before its task ran")
    }

    func testLLMReachabilityStatus_initializationAndEquality() async {
        let now = Date()
        let trueStatus = LLMReachabilityStatus(reachable: true, checkedAt: now)
        let falseStatus = LLMReachabilityStatus(reachable: false, checkedAt: now)
        let nilStatus = LLMReachabilityStatus(reachable: nil, checkedAt: nil)
        XCTAssertEqual(trueStatus.reachable, true)
        XCTAssertEqual(falseStatus.reachable, false)
        XCTAssertNil(nilStatus.reachable)
        XCTAssertEqual(trueStatus.checkedAt, now)
        XCTAssertEqual(trueStatus, LLMReachabilityStatus(reachable: true, checkedAt: now))
        XCTAssertNotEqual(trueStatus, falseStatus)
    }

    func testLLMReachabilityProvider_handlesNilAndCachedMonitor() async {
        await makeSubjects()
        let provider = AppDependencyWiring.llmReachabilityProvider(monitor: monitor)
        let initial = await provider()
        XCTAssertNil(initial.reachable)

        var weakMonitor: LLMStatusMonitor? = LLMStatusMonitor()
        let weakProvider = AppDependencyWiring.llmReachabilityProvider(monitor: weakMonitor!)
        weakMonitor = nil
        let deadResult = await weakProvider()
        XCTAssertNil(deadResult.reachable)
        XCTAssertNil(deadResult.checkedAt)
    }
}
