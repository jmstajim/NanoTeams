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

    /// Persisted sidebar "read" markers. Each entry is `"<workFolderUUID>:<taskID>"`.
    var seenSupervisorInputKeys: Set<String> {
        didSet {
            storage.set(Array(seenSupervisorInputKeys), forKey: Keys.seenSupervisorInputKeys)
        }
    }

    func markTaskSeen(workFolderID: UUID, taskID: Int) {
        seenSupervisorInputKeys.insert(Self.seenKey(workFolderID: workFolderID, taskID: taskID))
    }

    func unmarkTaskSeen(workFolderID: UUID, taskID: Int) {
        seenSupervisorInputKeys.remove(Self.seenKey(workFolderID: workFolderID, taskID: taskID))
    }

    func isTaskSeen(workFolderID: UUID, taskID: Int) -> Bool {
        seenSupervisorInputKeys.contains(Self.seenKey(workFolderID: workFolderID, taskID: taskID))
    }

    func seenTaskIDs(forWorkFolder workFolderID: UUID) -> Set<Int> {
        let prefix = "\(workFolderID.uuidString):"
        var result: Set<Int> = []
        for entry in seenSupervisorInputKeys where entry.hasPrefix(prefix) {
            let suffix = entry.dropFirst(prefix.count)
            if let id = Int(suffix) {
                result.insert(id)
            }
        }
        return result
    }

    private static func seenKey(workFolderID: UUID, taskID: Int) -> String {
        "\(workFolderID.uuidString):\(taskID)"
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

    /// User's intent to enable Vision — persisted independently from the
    /// concrete URL / model fields so the toggle survives tab switches even
    /// before the user fills in any override field. `isVisionConfigured`
    /// requires both `visionEnabled` AND a model to call: either an explicit
    /// override (`visionModelName`) or — when the picker shows "Use global"
    /// (empty `visionModelName`) — a non-empty `llmModelName` to inherit
    /// from. Without this fallback, picking "Use global" silently drops
    /// `analyze_image` from role toolsets even though the UI shows vision
    /// active (see `visionLLMConfig` for the request-time fallback).
    var visionEnabled: Bool {
        didSet { storage.set(visionEnabled, forKey: Keys.visionEnabled) }
    }

    var visionModelName: String {
        didSet { storage.set(visionModelName, forKey: Keys.visionModelName) }
    }

    var visionBaseURLString: String {
        didSet { storage.set(visionBaseURLString, forKey: Keys.visionBaseURL) }
    }

    var visionMaxTokens: Int {
        didSet { storage.set(visionMaxTokens, forKey: Keys.visionMaxTokens) }
    }

    var isVisionConfigured: Bool {
        guard visionEnabled else { return false }
        // I3: trim both branches symmetrically. Pre-fix the override branch
        // accepted "   " as a real model name while the global-fallback
        // branch trimmed first — caller behaviour diverged on whitespace.
        let trimmedVision = visionModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVision.isEmpty { return true }
        return !llmModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var visionLLMConfig: LLMConfig? {
        guard isVisionConfigured else { return nil }
        // I3: also gate on a non-empty base URL. Without this, a fully-blank
        // vision setup with an empty global URL still produced an LLMConfig
        // with `baseURLString == ""`, slipping past schema-time filtering and
        // failing later at request construction with a generic transport
        // error. Trim both URLs symmetrically with the model-name fallback.
        let trimmedVisionURL = visionBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGlobalURL = llmBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedURL = trimmedVisionURL.isEmpty ? trimmedGlobalURL : trimmedVisionURL
        guard !resolvedURL.isEmpty else { return nil }

        let trimmedVisionModel = visionModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGlobalModel = llmModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedVisionModel.isEmpty ? trimmedGlobalModel : trimmedVisionModel
        return LLMConfig(
            provider: llmProvider,
            baseURLString: resolvedURL,
            modelName: resolvedModel,
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

    // MARK: - Global LLM Context

    /// App-wide instruction appended to the system prompt of every LLM call
    /// (step execution, consultation, meeting, planning, supervisor auto-answer,
    /// work-folder context generation, team generation, vision). Empty string
    /// disables the append (no separator emitted).
    ///
    /// Persistence semantics intentionally diverge from `teamGenSystemPrompt`:
    /// empty string is persisted AS empty (not removed) so the user can clear
    /// the field and have the cleared state stick. First launch with no stored
    /// key reads `AppDefaults.globalContext` via `object(forKey:) as? String ??
    /// AppDefaults.globalContext`. `resetToDefaults()` removes the key AND
    /// re-assigns to `AppDefaults.globalContext`.
    ///
    /// LM Studio session caveat: changes only take effect on fresh sessions
    /// (new run, restart role, revision, planning reset, HTTP 400 fallback).
    /// `system_prompt` is omitted on stateful continuations, so an in-flight
    /// step's response chain still uses the value baked in at session start.
    var globalContext: String {
        didSet { storage.set(globalContext, forKey: Keys.globalContext) }
    }

    // MARK: - Bash (shell command execution)

    /// How the `bash` tool resolves an "ask" command. Default `.semiAutomatic`.
    var bashMode: BashExecutionMode {
        didSet { storage.set(bashMode.rawValue, forKey: Keys.bashMode) }
    }
    /// Strictness fed to the Auto judge. Default `.standard`.
    var bashRestrictionLevel: BashRestrictionLevel {
        didSet { storage.set(bashRestrictionLevel.rawValue, forKey: Keys.bashRestrictionLevel) }
    }
    /// Patterns that force allow (after deny). Ordered list.
    var bashAllowRules: [String] {
        didSet { storage.set(bashAllowRules, forKey: Keys.bashAllowRules) }
    }
    /// Patterns that force review.
    var bashAskRules: [String] {
        didSet { storage.set(bashAskRules, forKey: Keys.bashAskRules) }
    }
    /// Patterns that force deny (highest priority).
    var bashDenyRules: [String] {
        didSet { storage.set(bashDenyRules, forKey: Keys.bashDenyRules) }
    }
    /// Confine commands in a macOS Seatbelt sandbox. Default on.
    var bashSandboxEnabled: Bool {
        didSet { storage.set(bashSandboxEnabled, forKey: Keys.bashSandboxEnabled) }
    }
    /// Per-folder read/write grants for the sandbox. Persisted as JSON.
    var bashSandboxPermissions: BashSandboxPermissions {
        didSet {
            if let data = try? JSONCoderFactory.makePersistenceEncoder().encode(bashSandboxPermissions) {
                storage.set(data, forKey: Keys.bashSandboxPermissions)
            }
        }
    }
    /// Fall back to running unsandboxed if the Seatbelt wrapper fails to launch. Default off.
    var bashAllowUnsandboxedFallback: Bool {
        didSet { storage.set(bashAllowUnsandboxedFallback, forKey: Keys.bashAllowUnsandboxedFallback) }
    }
    /// Optional dedicated LLM override (URL + model; token via Keychain by URL)
    /// for the Auto judge. `nil` = use the role's / global config. Persisted as
    /// JSON, mirroring `teamGenLLMOverride`.
    var bashJudgeLLMOverride: LLMOverride? {
        didSet {
            if let o = bashJudgeLLMOverride, !o.isEmpty,
               let data = try? JSONCoderFactory.makePersistenceEncoder().encode(o) {
                storage.set(data, forKey: Keys.bashJudgeLLMOverride)
            } else {
                storage.removeObject(forKey: Keys.bashJudgeLLMOverride)
            }
        }
    }

    /// Assembled `BashPolicy` surfaced to the LLM execution layer via
    /// `LLMStateDelegate.bashPolicy`.
    var bashPolicy: BashPolicy {
        BashPolicy(
            mode: bashMode,
            restrictionLevel: bashRestrictionLevel,
            allowRules: bashAllowRules,
            askRules: bashAskRules,
            denyRules: bashDenyRules,
            sandboxEnabled: bashSandboxEnabled,
            sandboxPermissions: bashSandboxPermissions,
            allowUnsandboxedFallback: bashAllowUnsandboxedFallback,
            judgeOverride: bashJudgeLLMOverride
        )
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

    /// FSEvents debounce window for the exploratory-search index watcher.
    /// Larger values coalesce bursty writes into one rebuild; smaller values
    /// pick up changes sooner. Clamped on assignment to
    /// `[AppDefaults.searchIndexWatcherDebounceSecondsMin, ...Max]` so the
    /// persisted value always sits inside the UI bounds.
    /// **Note:** read once at coordinator construction (folder open / toggle
    /// flip). Live editing of this value during a session does not retune
    /// the active watcher — close/reopen the folder or toggle the feature.
    var searchIndexWatcherDebounceSeconds: TimeInterval {
        didSet {
            let clamped = min(
                max(searchIndexWatcherDebounceSeconds, AppDefaults.searchIndexWatcherDebounceSecondsMin),
                AppDefaults.searchIndexWatcherDebounceSecondsMax
            )
            if clamped != searchIndexWatcherDebounceSeconds {
                searchIndexWatcherDebounceSeconds = clamped
                return
            }
            storage.set(searchIndexWatcherDebounceSeconds, forKey: Keys.searchIndexWatcherDebounceSeconds)
        }
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
        self.enterSendsMessage = (storage.object(forKey: Keys.enterSendsMessage) as? Bool) ?? true
        self.embedFilesInPrompt = storage.bool(forKey: Keys.embedFilesInPrompt)
        self.debugModeEnabled = storage.bool(forKey: Keys.debugModeEnabled)
        self.loggingEnabled = (storage.object(forKey: Keys.loggingEnabled) as? Bool) ?? Self.defaultLoggingEnabled
        self.sidebarTaskFilter = storage.string(forKey: Keys.sidebarTaskFilter)
            .flatMap(TaskFilter.init(rawValue:)) ?? .all
        self.maxLLMRetries = (storage.object(forKey: Keys.maxLLMRetries) as? Int) ?? LLMConstants.defaultMaxLLMRetries
        self.llmRequestTimeoutSeconds = (storage.object(forKey: Keys.llmRequestTimeoutSeconds) as? Int) ?? LLMConstants.defaultLLMRequestTimeoutSeconds
        self.timelineClearedUpToDate = storage.object(forKey: Keys.timelineClearedUpToDate) as? Date
        let storedVisionModel = storage.string(forKey: Keys.visionModelName) ?? ""
        self.visionModelName = storedVisionModel
        self.visionBaseURLString = storage.string(forKey: Keys.visionBaseURL) ?? ""
        self.visionMaxTokens = (storage.object(forKey: Keys.visionMaxTokens) as? Int) ?? 0
        // Back-compat: existing installs with a configured vision model but no
        // explicit `visionEnabled` flag yet should default to ON so users don't
        // lose their working setup on upgrade.
        self.visionEnabled = (storage.object(forKey: Keys.visionEnabled) as? Bool)
            ?? !storedVisionModel.isEmpty
        let rawIDs = (storage.object(forKey: Keys.dismissedNotificationIDs) as? [String]) ?? []
        self.dismissedNotificationIDs = Set(rawIDs)
        let rawTipIDs = (storage.object(forKey: Keys.dismissedFeatureTipIDs) as? [String]) ?? []
        self.dismissedFeatureTipIDs = Set(rawTipIDs)
        let rawSeenKeys = (storage.object(forKey: Keys.seenSupervisorInputKeys) as? [String]) ?? []
        self.seenSupervisorInputKeys = Set(rawSeenKeys)
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
        // `object(forKey:) as? String` (not `string(forKey:)`) — distinguishes
        // "key absent" (default applies) from "stored empty string" (cleared
        // by user, must persist).
        self.globalContext = (storage.object(forKey: Keys.globalContext) as? String)
            ?? AppDefaults.globalContext
        let storedSearchIndexWatcherDebounce = (storage.object(forKey: Keys.searchIndexWatcherDebounceSeconds) as? Double)
            ?? AppDefaults.searchIndexWatcherDebounceSeconds
        self.searchIndexWatcherDebounceSeconds = min(
            max(storedSearchIndexWatcherDebounce, AppDefaults.searchIndexWatcherDebounceSecondsMin),
            AppDefaults.searchIndexWatcherDebounceSecondsMax
        )
        self.bashMode = storage.string(forKey: Keys.bashMode)
            .flatMap(BashExecutionMode.init(rawValue:)) ?? BashConstants.defaultMode
        self.bashRestrictionLevel = storage.string(forKey: Keys.bashRestrictionLevel)
            .flatMap(BashRestrictionLevel.init(rawValue:)) ?? BashConstants.defaultRestrictionLevel
        self.bashAllowRules = (storage.object(forKey: Keys.bashAllowRules) as? [String]) ?? []
        self.bashAskRules = (storage.object(forKey: Keys.bashAskRules) as? [String]) ?? []
        self.bashDenyRules = (storage.object(forKey: Keys.bashDenyRules) as? [String]) ?? []
        // sandbox defaults ON — `object(forKey:) as? Bool` distinguishes "absent"
        // (apply default true) from a stored `false`.
        self.bashSandboxEnabled = (storage.object(forKey: Keys.bashSandboxEnabled) as? Bool)
            ?? BashConstants.defaultSandboxEnabled
        if let data = storage.data(forKey: Keys.bashSandboxPermissions),
           let decoded = try? JSONCoderFactory.makeDateDecoder().decode(BashSandboxPermissions.self, from: data) {
            self.bashSandboxPermissions = decoded
        } else {
            self.bashSandboxPermissions = BashSandboxPermissions()
        }
        self.bashAllowUnsandboxedFallback = storage.bool(forKey: Keys.bashAllowUnsandboxedFallback)
        // Migrate the legacy plain `bashJudgeModel` string into the override struct.
        if let data = storage.data(forKey: Keys.bashJudgeLLMOverride),
           let decoded = try? JSONCoderFactory.makeDateDecoder().decode(LLMOverride.self, from: data),
           !decoded.isEmpty {
            self.bashJudgeLLMOverride = decoded
        } else if let legacyModel = storage.string(forKey: Keys.bashJudgeModel),
                  !legacyModel.trimmingCharacters(in: .whitespaces).isEmpty {
            let migrated = LLMOverride(modelName: legacyModel)
            self.bashJudgeLLMOverride = migrated
            // Write through ONCE and drop the legacy key (didSet doesn't fire during
            // init). Mirrors `migrateExpandedSearchKeys` — without this the migration
            // re-runs every launch and could resurrect a later-cleared override.
            if let data = try? JSONCoderFactory.makePersistenceEncoder().encode(migrated) {
                storage.set(data, forKey: Keys.bashJudgeLLMOverride)
            }
            storage.removeObject(forKey: Keys.bashJudgeModel)
        } else {
            self.bashJudgeLLMOverride = nil
        }
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
        storage.removeObject(forKey: Keys.enterSendsMessage)
        storage.removeObject(forKey: Keys.embedFilesInPrompt)
        storage.removeObject(forKey: Keys.debugModeEnabled)
        storage.removeObject(forKey: Keys.loggingEnabled)
        storage.removeObject(forKey: Keys.maxLLMRetries)
        storage.removeObject(forKey: Keys.llmRequestTimeoutSeconds)
        storage.removeObject(forKey: Keys.visionEnabled)
        storage.removeObject(forKey: Keys.visionModelName)
        storage.removeObject(forKey: Keys.visionBaseURL)
        storage.removeObject(forKey: Keys.visionMaxTokens)
        storage.removeObject(forKey: Keys.dismissedNotificationIDs)
        storage.removeObject(forKey: Keys.dismissedFeatureTipIDs)
        storage.removeObject(forKey: Keys.seenSupervisorInputKeys)
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
        storage.removeObject(forKey: Keys.searchIndexWatcherDebounceSeconds)
        storage.removeObject(forKey: Keys.globalContext)
        storage.removeObject(forKey: Keys.bashMode)
        storage.removeObject(forKey: Keys.bashRestrictionLevel)
        storage.removeObject(forKey: Keys.bashAllowRules)
        storage.removeObject(forKey: Keys.bashAskRules)
        storage.removeObject(forKey: Keys.bashDenyRules)
        storage.removeObject(forKey: Keys.bashSandboxEnabled)
        storage.removeObject(forKey: Keys.bashSandboxPermissions)
        storage.removeObject(forKey: Keys.bashAllowUnsandboxedFallback)
        storage.removeObject(forKey: Keys.bashJudgeModel)
        storage.removeObject(forKey: Keys.bashJudgeLLMOverride)

        let provider = LLMProvider.lmStudio
        llmProvider = provider
        llmBaseURLString = provider.defaultBaseURL
        llmModelName = provider.defaultModel
        llmMaxTokens = provider.defaultMaxTokens
        llmTemperature = nil
        enterSendsMessage = true
        embedFilesInPrompt = false
        debugModeEnabled = false
        loggingEnabled = Self.defaultLoggingEnabled
        maxLLMRetries = LLMConstants.defaultMaxLLMRetries
        llmRequestTimeoutSeconds = LLMConstants.defaultLLMRequestTimeoutSeconds
        visionEnabled = false
        visionModelName = ""
        visionBaseURLString = ""
        visionMaxTokens = 0
        dismissedNotificationIDs = []
        dismissedFeatureTipIDs = []
        seenSupervisorInputKeys = []
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
        searchIndexWatcherDebounceSeconds = AppDefaults.searchIndexWatcherDebounceSeconds
        globalContext = AppDefaults.globalContext
        bashMode = BashConstants.defaultMode
        bashRestrictionLevel = BashConstants.defaultRestrictionLevel
        bashAllowRules = []
        bashAskRules = []
        bashDenyRules = []
        bashSandboxEnabled = BashConstants.defaultSandboxEnabled
        bashSandboxPermissions = BashSandboxPermissions()
        bashAllowUnsandboxedFallback = false
        bashJudgeLLMOverride = nil
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
