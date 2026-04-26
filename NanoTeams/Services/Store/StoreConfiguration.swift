import Foundation
import Observation

// MARK: - Configuration Storage

/// Abstracts the persistence backend for `StoreConfiguration` (DIP).
/// `UserDefaults` conforms automatically — no additional code needed.
protocol ConfigurationStorage {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func data(forKey key: String) -> Data?
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: ConfigurationStorage {}

// MARK: - App Update Check Interval

/// User-selected cadence for the background "is there a newer NanoTeams release?"
/// check. The user-initiated "Check for Updates" button bypasses this entirely
/// — `force == true` always fires the network call regardless of the setting.
enum AppUpdateCheckInterval: String, CaseIterable, Identifiable, Codable, Hashable {
    case daily, weekly, biweekly, monthly, never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        case .never: return "Never"
        }
    }

    /// `nil` means background checks are disabled; the user can still trigger
    /// a forced check from the Updates settings tab.
    var seconds: TimeInterval? {
        switch self {
        case .daily: return 86_400
        case .weekly: return 7 * 86_400
        case .biweekly: return 14 * 86_400
        case .monthly: return 30 * 86_400
        case .never: return nil
        }
    }
}

// MARK: - Store Configuration

/// Manages UserDefaults-backed configuration settings for the store.
@Observable @MainActor
final class StoreConfiguration {

    @ObservationIgnored
    private var storage: any ConfigurationStorage

    var llmProvider: LLMProvider {
        didSet {
            storage.set(llmProvider.rawValue, forKey: Keys.llmProvider)
            // Auto-update URL and model when provider changes
            if oldValue != llmProvider {
                llmBaseURLString = llmProvider.defaultBaseURL
                llmModelName = llmProvider.defaultModel
                llmMaxTokens = llmProvider.defaultMaxTokens
            }
        }
    }

    var llmBaseURLString: String {
        didSet { storage.set(llmBaseURLString, forKey: Keys.llmBaseURL) }
    }

    var llmModelName: String {
        didSet { storage.set(llmModelName, forKey: Keys.llmModel) }
    }

    var llmMaxTokens: Int {
        didSet { storage.set(llmMaxTokens, forKey: Keys.llmMaxTokens) }
    }

    var llmTemperature: Double? {
        didSet {
            if let temp = llmTemperature {
                storage.set(temp, forKey: Keys.llmTemperature)
            } else {
                storage.removeObject(forKey: Keys.llmTemperature)
            }
        }
    }

    var thinkingExpandedByDefault: Bool {
        didSet { storage.set(thinkingExpandedByDefault, forKey: Keys.thinkingExpandedByDefault) }
    }

    var toolCallsExpandedByDefault: Bool {
        didSet { storage.set(toolCallsExpandedByDefault, forKey: Keys.toolCallsExpandedByDefault) }
    }

    var artifactsExpandedByDefault: Bool {
        didSet { storage.set(artifactsExpandedByDefault, forKey: Keys.artifactsExpandedByDefault) }
    }

    var enterSendsMessage: Bool {
        didSet { storage.set(enterSendsMessage, forKey: Keys.enterSendsMessage) }
    }

    var embedFilesInPrompt: Bool {
        didSet { storage.set(embedFilesInPrompt, forKey: Keys.embedFilesInPrompt) }
    }

    var debugModeEnabled: Bool {
        didSet { storage.set(debugModeEnabled, forKey: Keys.debugModeEnabled) }
    }

    var loggingEnabled: Bool {
        didSet { storage.set(loggingEnabled, forKey: Keys.loggingEnabled) }
    }

    var sidebarTaskFilter: TaskFilter {
        didSet { storage.set(sidebarTaskFilter.rawValue, forKey: Keys.sidebarTaskFilter) }
    }

    var timelineClearedUpToDate: Date? {
        didSet {
            if let date = timelineClearedUpToDate {
                storage.set(date, forKey: Keys.timelineClearedUpToDate)
            } else {
                storage.removeObject(forKey: Keys.timelineClearedUpToDate)
            }
        }
    }

    var dismissedNotificationIDs: Set<String> {
        didSet {
            storage.set(Array(dismissedNotificationIDs), forKey: Keys.dismissedNotificationIDs)
        }
    }

    func dismissNotification(id: String) {
        dismissedNotificationIDs.insert(id)
    }

    func undismissNotification(id: String) {
        dismissedNotificationIDs.remove(id)
    }

    var dismissedFeatureTipIDs: Set<String> {
        didSet {
            storage.set(Array(dismissedFeatureTipIDs), forKey: Keys.dismissedFeatureTipIDs)
        }
    }

    func dismissFeatureTip(id: String) {
        dismissedFeatureTipIDs.insert(id)
    }

    func undismissFeatureTip(id: String) {
        dismissedFeatureTipIDs.remove(id)
    }

    func dismiss(_ tip: FeatureTipID) {
        dismissFeatureTip(id: tip.rawValue)
    }

    func isDismissed(_ tip: FeatureTipID) -> Bool {
        dismissedFeatureTipIDs.contains(tip.rawValue)
    }

    // MARK: - Vision Model

    var visionModelName: String {
        didSet { storage.set(visionModelName, forKey: Keys.visionModelName) }
    }

    var visionBaseURLString: String {
        didSet { storage.set(visionBaseURLString, forKey: Keys.visionBaseURL) }
    }

    var visionMaxTokens: Int {
        didSet { storage.set(visionMaxTokens, forKey: Keys.visionMaxTokens) }
    }

    var isVisionConfigured: Bool { !visionModelName.isEmpty }

    var visionLLMConfig: LLMConfig? {
        guard isVisionConfigured else { return nil }
        return LLMConfig(
            provider: llmProvider,
            baseURLString: visionBaseURLString.isEmpty ? llmBaseURLString : visionBaseURLString,
            modelName: visionModelName,
            maxTokens: visionMaxTokens,
            requestTimeoutSeconds: llmRequestTimeoutSeconds
        )
    }

    /// Maximum consecutive LLM server error retries before failing the step. 0 = unlimited.
    var maxLLMRetries: Int {
        didSet {
            let clamped = max(0, maxLLMRetries)
            if clamped != maxLLMRetries {
                maxLLMRetries = clamped
                return
            }
            storage.set(maxLLMRetries, forKey: Keys.maxLLMRetries)
        }
    }

    /// Streaming HTTP request timeout in seconds. 0 = no timeout (wait indefinitely).
    /// Applied to every streaming LLM call.
    var llmRequestTimeoutSeconds: Int {
        didSet {
            if llmRequestTimeoutSeconds < 0 {
                llmRequestTimeoutSeconds = 0
                return
            }
            storage.set(llmRequestTimeoutSeconds, forKey: Keys.llmRequestTimeoutSeconds)
        }
    }

    // MARK: - Team Generation

    /// Per-team-generation LLM override. nil = use global config.
    var teamGenLLMOverride: LLMOverride? {
        didSet {
            if let o = teamGenLLMOverride, !o.isEmpty,
               let data = try? JSONCoderFactory.makePersistenceEncoder().encode(o) {
                storage.set(data, forKey: Keys.teamGenLLMOverride)
            } else {
                storage.removeObject(forKey: Keys.teamGenLLMOverride)
            }
        }
    }

    /// Custom system prompt for team generation. Empty = use built-in default.
    var teamGenSystemPrompt: String {
        didSet {
            if teamGenSystemPrompt.isEmpty {
                storage.removeObject(forKey: Keys.teamGenSystemPrompt)
            } else {
                storage.set(teamGenSystemPrompt, forKey: Keys.teamGenSystemPrompt)
            }
        }
    }

    /// Trimmed prompt or nil when empty — passed to `TeamGenerationService.generate`.
    var teamGenSystemPromptOrNil: String? {
        let t = teamGenSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Forced supervisor mode applied post-generation. nil = use whatever the LLM chose.
    var teamGenForcedSupervisorMode: SupervisorMode? {
        didSet {
            if let v = teamGenForcedSupervisorMode {
                storage.set(v.rawValue, forKey: Keys.teamGenForcedSupervisorMode)
            } else {
                storage.removeObject(forKey: Keys.teamGenForcedSupervisorMode)
            }
        }
    }

    /// Forced acceptance mode applied post-generation. nil = use whatever the LLM chose.
    var teamGenForcedAcceptanceMode: AcceptanceMode? {
        didSet {
            if let v = teamGenForcedAcceptanceMode {
                storage.set(v.rawValue, forKey: Keys.teamGenForcedAcceptanceMode)
            } else {
                storage.removeObject(forKey: Keys.teamGenForcedAcceptanceMode)
            }
        }
    }

    // MARK: - App Update

    /// Timestamp of the last successful GitHub releases check. Used to throttle
    /// the daily (default) automatic refresh; nil means "never checked".
    var lastAppUpdateCheckAt: Date? {
        didSet {
            if let date = lastAppUpdateCheckAt {
                storage.set(date, forKey: Keys.lastAppUpdateCheckAt)
            } else {
                storage.removeObject(forKey: Keys.lastAppUpdateCheckAt)
            }
        }
    }

    /// Release tags the user dismissed via the Watchtower app-update card.
    var skippedAppUpdateTags: Set<String> {
        didSet {
            storage.set(Array(skippedAppUpdateTags), forKey: Keys.skippedAppUpdateTags)
        }
    }

    /// Last successfully-fetched release payload, persisted so the Watchtower
    /// card re-appears on relaunch within the active throttle window (otherwise
    /// `refresh()` skips the network call and `availableRelease` stays nil).
    /// Cleared when the user skips the tag or when the check yields no newer
    /// release.
    var cachedAppUpdateRelease: AppUpdateChecker.Release? {
        didSet {
            if let release = cachedAppUpdateRelease,
               let data = try? JSONCoderFactory.makePersistenceEncoder().encode(release)
            {
                storage.set(data, forKey: Keys.cachedAppUpdateRelease)
            } else {
                storage.removeObject(forKey: Keys.cachedAppUpdateRelease)
            }
        }
    }

    /// User-selected cadence for the background app-update probe.
    var appUpdateCheckInterval: AppUpdateCheckInterval {
        didSet {
            storage.set(appUpdateCheckInterval.rawValue, forKey: Keys.appUpdateCheckInterval)
        }
    }

    // MARK: - Exploratory Search

    /// Gates the exploratory-search feature: when true, `search(exploratory: true)`
    /// calls through to the semantic vector index (per-token + whole-phrase
    /// embeddings) intersected with the token posting index; when false, it
    /// falls back to a plain search. Proactive indexing (and the on-disk
    /// `search_index.json`, `vocab_vectors.*`) is also gated on this flag.
    var exploratorySearchEnabled: Bool {
        didSet { storage.set(exploratorySearchEnabled, forKey: Keys.exploratorySearchEnabled) }
    }

    /// Per-exploratory-search embedding-model config. `nil` = use the default
    /// (`EmbeddingConfig.defaultNomicLMStudio`). Powers the offline vector
    /// index build AND the query-time whole-phrase expansion call.
    var exploratorySearchEmbeddingConfig: EmbeddingConfig? {
        didSet {
            if let config = exploratorySearchEmbeddingConfig,
               let data = try? JSONCoderFactory.makePersistenceEncoder().encode(config) {
                storage.set(data, forKey: Keys.exploratorySearchEmbeddingConfig)
            } else {
                storage.removeObject(forKey: Keys.exploratorySearchEmbeddingConfig)
            }
        }
    }

    /// Effective embedding config — user override or the built-in default.
    var effectiveEmbeddingConfig: EmbeddingConfig {
        exploratorySearchEmbeddingConfig ?? .defaultNomicLMStudio
    }

    /// Cosine threshold for per-token vector expansion (queries that have at
    /// least one token already in the vocab). 0.0-1.0. Higher = stricter.
    var exploratorySearchPerTokenThreshold: Double {
        didSet {
            storage.set(exploratorySearchPerTokenThreshold,
                        forKey: Keys.exploratorySearchPerTokenThreshold)
        }
    }

    /// Cosine threshold for whole-phrase expansion (multi-word or OOV queries
    /// that fire one /v1/embeddings round-trip). Typically lower than
    /// `exploratorySearchPerTokenThreshold` because a phrase vector is a noisier
    /// signal than a specific token's stored vector.
    var exploratorySearchPhraseThreshold: Double {
        didSet {
            storage.set(exploratorySearchPhraseThreshold,
                        forKey: Keys.exploratorySearchPhraseThreshold)
        }
    }

    /// When `true`, `search` calls without an explicit `exploratory` argument
    /// run in exploratory mode by default. Independent of `exploratorySearchEnabled`:
    /// this flag only controls the default for missing args; if the feature is
    /// disabled the processor still falls back to plain search.
    var searchExploratoryByDefault: Bool {
        didSet { storage.set(searchExploratoryByDefault, forKey: Keys.searchExploratoryByDefault) }
    }

    // MARK: - Tools

    /// Hard line limit enforced by `read_file`. Files exceeding this return an
    /// error directing the LLM to use `read_lines` with explicit ranges.
    /// Clamped to `[AppDefaults.readFileMaxLinesMin, AppDefaults.readFileMaxLinesMax]`
    /// on assignment so the persisted value can never violate the UI bounds.
    var readFileMaxLines: Int {
        didSet {
            let clamped = min(max(readFileMaxLines, AppDefaults.readFileMaxLinesMin), AppDefaults.readFileMaxLinesMax)
            if clamped != readFileMaxLines {
                readFileMaxLines = clamped
                return
            }
            storage.set(readFileMaxLines, forKey: Keys.readFileMaxLines)
        }
    }

    /// Default cap on `search` results when the LLM omits `max_results`.
    /// Clamped to `[AppDefaults.searchMaxResultsMin, AppDefaults.searchMaxResultsMax]`
    /// on assignment so the persisted value can never violate the UI bounds.
    var searchMaxResults: Int {
        didSet {
            let clamped = min(max(searchMaxResults, AppDefaults.searchMaxResultsMin), AppDefaults.searchMaxResultsMax)
            if clamped != searchMaxResults {
                searchMaxResults = clamped
                return
            }
            storage.set(searchMaxResults, forKey: Keys.searchMaxResults)
        }
    }

    /// Default number of source lines to include before each `search` match
    /// when the LLM omits `context_before`. Clamped to
    /// `[AppDefaults.searchContextMin, AppDefaults.searchContextMax]`.
    var searchContextBefore: Int {
        didSet {
            let clamped = min(max(searchContextBefore, AppDefaults.searchContextMin), AppDefaults.searchContextMax)
            if clamped != searchContextBefore {
                searchContextBefore = clamped
                return
            }
            storage.set(searchContextBefore, forKey: Keys.searchContextBefore)
        }
    }

    /// Default number of source lines to include after each `search` match
    /// when the LLM omits `context_after`. Clamped to
    /// `[AppDefaults.searchContextMin, AppDefaults.searchContextMax]`.
    var searchContextAfter: Int {
        didSet {
            let clamped = min(max(searchContextAfter, AppDefaults.searchContextMin), AppDefaults.searchContextMax)
            if clamped != searchContextAfter {
                searchContextAfter = clamped
                return
            }
            storage.set(searchContextAfter, forKey: Keys.searchContextAfter)
        }
    }

    // MARK: - Dictation

    /// Locale identifiers the user explicitly enabled for dictation. Empty
    /// means no dictation language is configured — `DictationService.start`
    /// surfaces a friendly error in that case and the mic button routes the
    /// user to Settings → Dictation. There is NO `Locale.preferredLanguages`
    /// fallback. Only the intersection with installed on-device models is
    /// actually used at runtime; this array just expresses user intent.
    /// Identifiers are normalized to `Locale(identifier:).identifier` form
    /// on load (see `init`) so legacy hyphenated entries (`ru-RU`) and
    /// canonical underscored entries (`ru_RU`) compare equal.
    var dictationLocaleIdentifiers: [String] {
        didSet {
            storage.set(dictationLocaleIdentifiers, forKey: Keys.dictationLocales)
        }
    }

    private static var defaultLoggingEnabled: Bool {
#if DEBUG
        return true
#else
        return false
#endif
    }

    private enum Keys {
        static let llmProvider = "llmProvider"
        static let llmBaseURL = UserDefaultsKeys.llmBaseURL
        static let llmModel = UserDefaultsKeys.llmModel
        static let llmMaxTokens = "llmMaxTokens"
        static let llmTemperature = "llmTemperature"
        static let thinkingExpandedByDefault = UserDefaultsKeys.thinkingExpandedByDefault
        static let toolCallsExpandedByDefault = UserDefaultsKeys.toolCallsExpandedByDefault
        static let artifactsExpandedByDefault = UserDefaultsKeys.artifactsExpandedByDefault
        static let debugModeEnabled = UserDefaultsKeys.debugModeEnabled
        static let maxLLMRetries = UserDefaultsKeys.maxLLMRetries
        static let llmRequestTimeoutSeconds = UserDefaultsKeys.llmRequestTimeoutSeconds
        static let timelineClearedUpToDate = UserDefaultsKeys.timelineClearedUpToDate
        static let visionModelName = UserDefaultsKeys.visionModelName
        static let visionBaseURL = UserDefaultsKeys.visionBaseURL
        static let visionMaxTokens = UserDefaultsKeys.visionMaxTokens
        static let dismissedNotificationIDs = UserDefaultsKeys.dismissedNotificationIDs
        static let dismissedFeatureTipIDs = UserDefaultsKeys.dismissedFeatureTipIDs
        static let enterSendsMessage = UserDefaultsKeys.enterSendsMessage
        static let embedFilesInPrompt = UserDefaultsKeys.quickCaptureEmbedFiles
        static let loggingEnabled = UserDefaultsKeys.loggingEnabled
        static let sidebarTaskFilter = UserDefaultsKeys.sidebarTaskFilter
        static let teamGenLLMOverride = UserDefaultsKeys.teamGenLLMOverride
        static let teamGenSystemPrompt = UserDefaultsKeys.teamGenSystemPrompt
        static let teamGenForcedSupervisorMode = UserDefaultsKeys.teamGenForcedSupervisorMode
        static let teamGenForcedAcceptanceMode = UserDefaultsKeys.teamGenForcedAcceptanceMode
        static let lastAppUpdateCheckAt = UserDefaultsKeys.lastAppUpdateCheckAt
        static let skippedAppUpdateTags = UserDefaultsKeys.skippedAppUpdateTags
        static let cachedAppUpdateRelease = UserDefaultsKeys.cachedAppUpdateRelease
        static let appUpdateCheckInterval = UserDefaultsKeys.appUpdateCheckInterval
        static let dictationLocales = UserDefaultsKeys.dictationLocales
        static let exploratorySearchEnabled = UserDefaultsKeys.exploratorySearchEnabled
        static let exploratorySearchEmbeddingConfig = UserDefaultsKeys.exploratorySearchEmbeddingConfig
        static let exploratorySearchPerTokenThreshold = UserDefaultsKeys.exploratorySearchPerTokenThreshold
        static let exploratorySearchPhraseThreshold = UserDefaultsKeys.exploratorySearchPhraseThreshold
        static let searchExploratoryByDefault = UserDefaultsKeys.searchExploratoryByDefault
        static let readFileMaxLines = UserDefaultsKeys.readFileMaxLines
        static let searchMaxResults = UserDefaultsKeys.searchMaxResults
        static let searchContextBefore = UserDefaultsKeys.searchContextBefore
        static let searchContextAfter = UserDefaultsKeys.searchContextAfter
    }

    init(storage: any ConfigurationStorage = UserDefaults.standard) {
        self.storage = storage
        Self.migrateExpandedSearchKeys(storage)
        let providerRaw = storage.string(forKey: Keys.llmProvider)
        let provider = providerRaw.flatMap(LLMProvider.init(rawValue:)) ?? .lmStudio
        self.llmProvider = provider
        self.llmBaseURLString = storage.string(forKey: Keys.llmBaseURL) ?? provider.defaultBaseURL
        self.llmModelName = storage.string(forKey: Keys.llmModel) ?? provider.defaultModel
        self.llmMaxTokens = (storage.object(forKey: Keys.llmMaxTokens) as? Int) ?? provider.defaultMaxTokens
        self.llmTemperature = storage.object(forKey: Keys.llmTemperature) as? Double
        self.thinkingExpandedByDefault = storage.bool(forKey: Keys.thinkingExpandedByDefault)
        self.toolCallsExpandedByDefault = storage.bool(forKey: Keys.toolCallsExpandedByDefault)
        self.artifactsExpandedByDefault = storage.bool(forKey: Keys.artifactsExpandedByDefault)
        self.enterSendsMessage = (storage.object(forKey: Keys.enterSendsMessage) as? Bool) ?? true
        self.embedFilesInPrompt = storage.bool(forKey: Keys.embedFilesInPrompt)
        self.debugModeEnabled = storage.bool(forKey: Keys.debugModeEnabled)
        self.loggingEnabled = (storage.object(forKey: Keys.loggingEnabled) as? Bool) ?? Self.defaultLoggingEnabled
        self.sidebarTaskFilter = storage.string(forKey: Keys.sidebarTaskFilter)
            .flatMap(TaskFilter.init(rawValue:)) ?? .all
        self.maxLLMRetries = (storage.object(forKey: Keys.maxLLMRetries) as? Int) ?? LLMConstants.defaultMaxLLMRetries
        self.llmRequestTimeoutSeconds = (storage.object(forKey: Keys.llmRequestTimeoutSeconds) as? Int) ?? LLMConstants.defaultLLMRequestTimeoutSeconds
        self.timelineClearedUpToDate = storage.object(forKey: Keys.timelineClearedUpToDate) as? Date
        self.visionModelName = storage.string(forKey: Keys.visionModelName) ?? ""
        self.visionBaseURLString = storage.string(forKey: Keys.visionBaseURL) ?? ""
        self.visionMaxTokens = (storage.object(forKey: Keys.visionMaxTokens) as? Int) ?? 0
        let rawIDs = (storage.object(forKey: Keys.dismissedNotificationIDs) as? [String]) ?? []
        self.dismissedNotificationIDs = Set(rawIDs)
        let rawTipIDs = (storage.object(forKey: Keys.dismissedFeatureTipIDs) as? [String]) ?? []
        self.dismissedFeatureTipIDs = Set(rawTipIDs)
        if let data = storage.data(forKey: Keys.teamGenLLMOverride),
           let decoded = try? JSONCoderFactory.makeDateDecoder().decode(LLMOverride.self, from: data),
           !decoded.isEmpty {
            self.teamGenLLMOverride = decoded
        } else {
            self.teamGenLLMOverride = nil
        }
        self.teamGenSystemPrompt = storage.string(forKey: Keys.teamGenSystemPrompt) ?? ""
        self.teamGenForcedSupervisorMode = storage.string(forKey: Keys.teamGenForcedSupervisorMode)
            .flatMap(SupervisorMode.init(rawValue:))
        self.teamGenForcedAcceptanceMode = storage.string(forKey: Keys.teamGenForcedAcceptanceMode)
            .flatMap(AcceptanceMode.init(rawValue:))
        self.lastAppUpdateCheckAt = storage.object(forKey: Keys.lastAppUpdateCheckAt) as? Date
        let rawSkippedTags = (storage.object(forKey: Keys.skippedAppUpdateTags) as? [String]) ?? []
        self.skippedAppUpdateTags = Set(rawSkippedTags)
        if let data = storage.data(forKey: Keys.cachedAppUpdateRelease),
           let decoded = try? JSONCoderFactory.makeDateDecoder().decode(AppUpdateChecker.Release.self, from: data)
        {
            self.cachedAppUpdateRelease = decoded
        } else {
            self.cachedAppUpdateRelease = nil
        }
        self.appUpdateCheckInterval = storage.string(forKey: Keys.appUpdateCheckInterval)
            .flatMap(AppUpdateCheckInterval.init(rawValue:)) ?? .daily
        // Normalize-and-dedupe on load.
        //
        // On macOS 26, Foundation's plain `Locale.identifier` PRESERVES the
        // input form — both `"ru-RU"` and `"ru_RU"` round-trip unchanged.
        // The only way to actually canonicalize is `.identifier(.bcp47)`,
        // which always emits hyphenated form (`ru-RU`).
        //
        // Without this, a legacy `["en_US","ru_RU"]` can't be matched against
        // a `model.id == "en-US"` row id on macOS 26 — the English row shows
        // unchecked while the engine still receives the `en_US` entry from
        // the provider. Worse, toggling Russian appends `ru-RU` next to the
        // legacy `ru_RU`, accumulating duplicate slots across launches.
        let storedDictationLocales = (storage.object(forKey: Keys.dictationLocales) as? [String]) ?? []
        var seenDictationLocales: Set<String> = []
        let normalizedDictationLocales = storedDictationLocales
            .map { Locale(identifier: $0).identifier(.bcp47) }
            .filter { seenDictationLocales.insert($0).inserted }
        self.dictationLocaleIdentifiers = normalizedDictationLocales
        if storedDictationLocales != normalizedDictationLocales {
            storage.set(normalizedDictationLocales, forKey: Keys.dictationLocales)
        }
        self.exploratorySearchEnabled = storage.bool(forKey: Keys.exploratorySearchEnabled)
        if let data = storage.data(forKey: Keys.exploratorySearchEmbeddingConfig),
           let decoded = try? JSONCoderFactory.makeDateDecoder().decode(EmbeddingConfig.self, from: data) {
            self.exploratorySearchEmbeddingConfig = decoded
        } else {
            self.exploratorySearchEmbeddingConfig = nil
        }
        // Defaults tuned from the plan. Kept as `Double` (`UserDefaults` has
        // first-class `double(forKey:)`) but applied as `Float` at the vector
        // site — Accelerate and nomic both use Float32.
        self.exploratorySearchPerTokenThreshold =
            (storage.object(forKey: Keys.exploratorySearchPerTokenThreshold) as? Double) ?? 0.75
        self.exploratorySearchPhraseThreshold =
            (storage.object(forKey: Keys.exploratorySearchPhraseThreshold) as? Double) ?? 0.70
        self.searchExploratoryByDefault = storage.bool(forKey: Keys.searchExploratoryByDefault)
        let storedReadFileMaxLines = (storage.object(forKey: Keys.readFileMaxLines) as? Int) ?? AppDefaults.readFileMaxLines
        self.readFileMaxLines = min(max(storedReadFileMaxLines, AppDefaults.readFileMaxLinesMin), AppDefaults.readFileMaxLinesMax)
        let storedSearchMaxResults = (storage.object(forKey: Keys.searchMaxResults) as? Int) ?? AppDefaults.searchMaxResults
        self.searchMaxResults = min(max(storedSearchMaxResults, AppDefaults.searchMaxResultsMin), AppDefaults.searchMaxResultsMax)
        let storedSearchContextBefore = (storage.object(forKey: Keys.searchContextBefore) as? Int) ?? AppDefaults.searchContextBefore
        self.searchContextBefore = min(max(storedSearchContextBefore, AppDefaults.searchContextMin), AppDefaults.searchContextMax)
        let storedSearchContextAfter = (storage.object(forKey: Keys.searchContextAfter) as? Int) ?? AppDefaults.searchContextAfter
        self.searchContextAfter = min(max(storedSearchContextAfter, AppDefaults.searchContextMin), AppDefaults.searchContextMax)
    }

    // MARK: - Migration

    /// One-shot migration: copies legacy `expandedSearch*` UserDefaults keys
    /// into the new `exploratorySearch*` keys and removes the originals.
    /// Idempotent — after the first run there's nothing left to migrate.
    /// TODO(2026-Q3): remove once all live installs have migrated.
    private static func migrateExpandedSearchKeys(_ storage: any ConfigurationStorage) {
        let pairs: [(old: String, new: String)] = [
            ("NanoTeams.search.expandedSearchEnabled.v1",           UserDefaultsKeys.exploratorySearchEnabled),
            ("NanoTeams.search.expandedSearchEmbeddingConfig.v1",   UserDefaultsKeys.exploratorySearchEmbeddingConfig),
            ("NanoTeams.search.expandedSearchPerTokenThreshold.v1", UserDefaultsKeys.exploratorySearchPerTokenThreshold),
            ("NanoTeams.search.expandedSearchPhraseThreshold.v1",   UserDefaultsKeys.exploratorySearchPhraseThreshold),
        ]
        for (oldKey, newKey) in pairs {
            // Copy only when the new key is empty — never clobber a value the
            // user committed to under the new name. But always drop the legacy
            // key afterwards so the next migration run is a no-op.
            if storage.object(forKey: newKey) == nil, let value = storage.object(forKey: oldKey) {
                storage.set(value, forKey: newKey)
            }
            storage.removeObject(forKey: oldKey)
        }
    }

    // MARK: - Reset

    func resetToDefaults() {
        storage.removeObject(forKey: Keys.llmProvider)
        storage.removeObject(forKey: Keys.llmBaseURL)
        storage.removeObject(forKey: Keys.llmModel)
        storage.removeObject(forKey: Keys.llmMaxTokens)
        storage.removeObject(forKey: Keys.llmTemperature)
        storage.removeObject(forKey: Keys.thinkingExpandedByDefault)
        storage.removeObject(forKey: Keys.toolCallsExpandedByDefault)
        storage.removeObject(forKey: Keys.artifactsExpandedByDefault)
        storage.removeObject(forKey: Keys.enterSendsMessage)
        storage.removeObject(forKey: Keys.embedFilesInPrompt)
        storage.removeObject(forKey: Keys.debugModeEnabled)
        storage.removeObject(forKey: Keys.loggingEnabled)
        storage.removeObject(forKey: Keys.maxLLMRetries)
        storage.removeObject(forKey: Keys.llmRequestTimeoutSeconds)
        storage.removeObject(forKey: Keys.visionModelName)
        storage.removeObject(forKey: Keys.visionBaseURL)
        storage.removeObject(forKey: Keys.visionMaxTokens)
        storage.removeObject(forKey: Keys.dismissedNotificationIDs)
        storage.removeObject(forKey: Keys.dismissedFeatureTipIDs)
        storage.removeObject(forKey: Keys.sidebarTaskFilter)
        storage.removeObject(forKey: Keys.teamGenLLMOverride)
        storage.removeObject(forKey: Keys.teamGenSystemPrompt)
        storage.removeObject(forKey: Keys.teamGenForcedSupervisorMode)
        storage.removeObject(forKey: Keys.teamGenForcedAcceptanceMode)
        storage.removeObject(forKey: Keys.lastAppUpdateCheckAt)
        storage.removeObject(forKey: Keys.skippedAppUpdateTags)
        storage.removeObject(forKey: Keys.cachedAppUpdateRelease)
        storage.removeObject(forKey: Keys.appUpdateCheckInterval)
        storage.removeObject(forKey: Keys.dictationLocales)
        storage.removeObject(forKey: Keys.exploratorySearchEnabled)
        storage.removeObject(forKey: Keys.exploratorySearchEmbeddingConfig)
        storage.removeObject(forKey: Keys.exploratorySearchPerTokenThreshold)
        storage.removeObject(forKey: Keys.exploratorySearchPhraseThreshold)
        storage.removeObject(forKey: Keys.searchExploratoryByDefault)
        storage.removeObject(forKey: Keys.readFileMaxLines)
        storage.removeObject(forKey: Keys.searchMaxResults)
        storage.removeObject(forKey: Keys.searchContextBefore)
        storage.removeObject(forKey: Keys.searchContextAfter)

        let provider = LLMProvider.lmStudio
        llmProvider = provider
        llmBaseURLString = provider.defaultBaseURL
        llmModelName = provider.defaultModel
        llmMaxTokens = provider.defaultMaxTokens
        llmTemperature = nil
        thinkingExpandedByDefault = false
        toolCallsExpandedByDefault = false
        artifactsExpandedByDefault = false
        enterSendsMessage = true
        embedFilesInPrompt = false
        debugModeEnabled = false
        loggingEnabled = Self.defaultLoggingEnabled
        maxLLMRetries = LLMConstants.defaultMaxLLMRetries
        llmRequestTimeoutSeconds = LLMConstants.defaultLLMRequestTimeoutSeconds
        visionModelName = ""
        visionBaseURLString = ""
        visionMaxTokens = 0
        dismissedNotificationIDs = []
        dismissedFeatureTipIDs = []
        sidebarTaskFilter = .all
        teamGenLLMOverride = nil
        teamGenSystemPrompt = ""
        teamGenForcedSupervisorMode = nil
        teamGenForcedAcceptanceMode = nil
        lastAppUpdateCheckAt = nil
        skippedAppUpdateTags = []
        cachedAppUpdateRelease = nil
        appUpdateCheckInterval = .daily
        dictationLocaleIdentifiers = []
        exploratorySearchEnabled = false
        exploratorySearchEmbeddingConfig = nil
        exploratorySearchPerTokenThreshold = 0.75
        exploratorySearchPhraseThreshold = 0.70
        searchExploratoryByDefault = false
        readFileMaxLines = AppDefaults.readFileMaxLines
        searchMaxResults = AppDefaults.searchMaxResults
        searchContextBefore = AppDefaults.searchContextBefore
        searchContextAfter = AppDefaults.searchContextAfter
    }

    // MARK: - Work Folder Path

    /// Last-opened project folder path, persisted for session restore.
    var lastOpenedWorkFolderPath: String? {
        get { storage.string(forKey: UserDefaultsKeys.lastOpenedWorkFolderPath) }
        set {
            if let newValue {
                storage.set(newValue, forKey: UserDefaultsKeys.lastOpenedWorkFolderPath)
            } else {
                storage.removeObject(forKey: UserDefaultsKeys.lastOpenedWorkFolderPath)
            }
        }
    }

    // MARK: - Convenience Aliases

    var llmBaseURL: String {
        get { llmBaseURLString }
        set { llmBaseURLString = newValue }
    }

    /// Builds a global LLMConfig from current settings.
    var globalLLMConfig: LLMConfig {
        LLMConfig(
            provider: llmProvider,
            baseURLString: llmBaseURLString,
            modelName: llmModelName,
            maxTokens: llmMaxTokens,
            temperature: llmTemperature,
            requestTimeoutSeconds: llmRequestTimeoutSeconds
        )
    }
    nonisolated deinit {}
}
