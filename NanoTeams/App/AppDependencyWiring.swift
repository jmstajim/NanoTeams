import Foundation

// MARK: - App Dependency Wiring

/// The cross-object wiring the main window performs once, on appear.
///
/// Lifted out of `NanoTeamsApp.body`'s `.onAppear` because that closure is dead under
/// XCTest by construction: `body` returns `Color.clear` when `isRunningTests`, so the
/// entire `else` branch — every one of these hand-offs — shipped unverified. What was
/// unverified is not decoration:
///
/// - `store.quickCaptureFormState` is the bridge the LLM pipeline drains queued
///   Supervisor messages through (`consumeQueuedSupervisorMessage`). Unset, every
///   queued message is silently dropped on the next iteration.
/// - `dictation.userSelectedLocalesProvider` is a CLOSURE, not a snapshot, precisely so
///   a Settings change mid-session is picked up. Installed as an array it would freeze
///   at launch-time locales.
/// - the LLM endpoint provider has the same live-read contract, and a stale capture
///   would poll the previous server forever after a provider flip.
///
/// The two providers are exposed separately from `wire` so their live-read contract is
/// assertable without constructing an `LLMStatusMonitor` (whose poll task is private)
/// or a `DictationService`.
@MainActor
enum AppDependencyWiring {

    /// The locale provider handed to `DictationService`.
    ///
    /// Returns a closure over `store`, not a resolved `[Locale]`: `DictationService`
    /// calls it on every `start()` and on every `hasUserSelectedLocales` read, so the
    /// user adding a language in Settings must take effect without a relaunch.
    /// Unparseable identifiers are `Locale`'s problem, not ours — `Locale(identifier:)`
    /// is non-failable and yields a locale that simply matches no installed model.
    static func dictationLocaleProvider(store: NTMSOrchestrator) -> () -> [Locale] {
        { store.configuration.dictationLocaleIdentifiers.map { Locale(identifier: $0) } }
    }

    /// The endpoint provider handed to `LLMStatusMonitor`.
    ///
    /// Same live-read contract, for the same reason: the monitor polls on a 120 s timer
    /// and must observe a URL or provider change committed in Settings rather than the
    /// values that happened to be current at launch. Returns both halves together
    /// because a provider without its matching URL probes the wrong path
    /// (`LLMProvider.reachabilityProbePath` differs between LM Studio and Ollama).
    static func llmEndpointProvider(
        store: NTMSOrchestrator
    ) -> @MainActor () -> (baseURL: String, provider: LLMProvider) {
        { (store.configuration.llmBaseURLString, store.configuration.llmProvider) }
    }

    /// Installs every hand-off the main window used to perform inline.
    ///
    /// `quickCapture` is a parameter rather than `QuickCaptureController.shared` so a
    /// test can wire a controller whose `HotkeyManager` is a double — `setup` registers
    /// real system-wide Carbon hotkeys, and a test that claimed ⌃⌥⌘0 for the duration
    /// of the run would take it from the developer's machine.
    static func wire(
        store: NTMSOrchestrator,
        dictation: DictationService,
        quickCapture: QuickCaptureController,
        statusMonitor: LLMStatusMonitor
    ) {
        quickCapture.setup(store: store, dictation: dictation)
        // Weak on the store's side — QuickCaptureController owns the strong reference.
        store.quickCaptureFormState = quickCapture.formState
        dictation.userSelectedLocalesProvider = dictationLocaleProvider(store: store)
        statusMonitor.startMonitoring(endpointProvider: llmEndpointProvider(store: store))
    }
}
