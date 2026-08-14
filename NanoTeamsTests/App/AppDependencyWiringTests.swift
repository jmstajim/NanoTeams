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

    override func tearDown() {
        monitor?.stopMonitoring()
        monitor = nil
        dictation = nil
        quickCapture = nil
        store = nil
        super.tearDown()
    }

    private func makeSubjects() async {
        store = await TestOrchestrator.make()
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

    // MARK: - wire

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
}
