import Foundation
import Observation
#if DEBUG
import Synchronization
#endif

// MARK: - Configuration Storage

/// Abstracts the persistence backend for `StoreConfiguration` (DIP).
/// `UserDefaults` conforms automatically — no additional code needed.
/// `nonisolated`: a pure storage abstraction with no UI dependency, and `Theme.current` — a
/// static read reached from AppKit's appearance-resolution thread — has to call it from a
/// nonisolated context. `UserDefaults`'s own methods are nonisolated in Foundation, so this
/// narrows nothing for the production conformer.
nonisolated protocol ConfigurationStorage {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func data(forKey key: String) -> Data?
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

nonisolated extension UserDefaults: ConfigurationStorage {}

// MARK: - App Update Check Interval

/// User-selected cadence for the background "is there a newer NanoTeams release?"
/// check. The user-initiated "Check for Updates" button bypasses this entirely
/// — `force == true` always fires the network call regardless of the setting.
/// `nonisolated` per the house rule for pure value types: it is a `Codable` enum persisted into
/// UserDefaults with no UI dependency, so it has no business inheriting the app target's
/// `@MainActor` default isolation. Every sibling of this shape in `Domain/` is already marked.
nonisolated enum AppUpdateCheckInterval: String, CaseIterable, Identifiable, Codable, Hashable {
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
            if oldValue != llmProvider {
                // Remember the OLD provider's endpoint before switching, then
                // restore the NEW provider's remembered endpoint (or its
                // defaults). A look at the other provider must never destroy
                // a customized URL + model — and because the bearer token is
                // Keychain-keyed by URL, restoring the URL also reconnects
                // the saved token. Blank/whitespace remembered values restore
                // the DEFAULTS: resurrecting an empty URL (cleared mid-edit
                // before the flip) would leave every request throwing
                // invalidBaseURL with no visible cause.
                rememberEndpoint(for: oldValue, url: llmBaseURLString, model: llmModelName)
                let restored = rememberedEndpoint(for: llmProvider)
                llmBaseURLString = Self.nonBlank(restored?.url) ?? llmProvider.defaultBaseURL
                llmModelName = Self.nonBlank(restored?.model) ?? llmProvider.defaultModel
                // A flip rewrites the URL programmatically, so there is no field
                // commit for endpoint-keyed views to observe. Bump for them.
                noteLLMEndpointCommitted()
            }
        }
    }

    /// Bumped when the LLM endpoint changes at a COMMIT boundary: the URL field's
    /// Return / focus-loss, a provider flip (which rewrites URL + model
    /// programmatically, so there is no commit event to observe), and
    /// `resetToDefaults`.
    ///
    /// Endpoint-keyed views key `.task(id:)` off this instead of the live
    /// `llmBaseURLString`, which the Settings URL `TextField` writes on EVERY
    /// keystroke — a live key re-fires the task per typed character, each time with
    /// a brand-new uncached key, producing one request per keystroke against
    /// half-typed hosts. Same rule the residency reconcile already follows
    /// ("reconcile from commit boundaries only").
    ///
    /// Session-scoped, deliberately not persisted: it identifies "which endpoint
    /// generation is this process on", which has no meaning across launches.
    private(set) var llmEndpointGeneration: Int = 0

    func noteLLMEndpointCommitted() {
        llmEndpointGeneration &+= 1
    }

    /// Last-used (URL, model) per provider — what makes the provider picker a
    /// reversible toggle instead of a destructive reset.
    nonisolated struct ProviderEndpoint: Codable, Equatable {
        var url: String
        var model: String
    }

    @ObservationIgnored
    private var providerEndpointMemory: [String: ProviderEndpoint] = [:]

    private func rememberEndpoint(for provider: LLMProvider, url: String, model: String) {
        providerEndpointMemory[provider.rawValue] = ProviderEndpoint(url: url, model: model)
        if let data = try? JSONEncoder().encode(providerEndpointMemory) {
            storage.set(data, forKey: Keys.llmProviderEndpoints)
        }
    }

    private func rememberedEndpoint(for provider: LLMProvider) -> ProviderEndpoint? {
        providerEndpointMemory[provider.rawValue]
    }

    /// Every endpoint this app KNOWS for `provider` — most-recently-intended first, blanks
    /// dropped, de-duplicated on `normalizedBaseURL`.
    ///
    /// Neither half of the pair can answer alone, which is why this lives here rather than at the
    /// caller: the ACTIVE provider's endpoint is in `llmBaseURLString`, and
    /// `providerEndpointMemory` only ever holds the endpoint of a provider the user has switched
    /// AWAY from (`llmProvider.didSet` remembers `oldValue`). This type owns both, so it is the
    /// Information Expert for "where have we been told this provider lives".
    ///
    /// Deliberately does NOT fall back to `provider.defaultBaseURL`. The question is what we know,
    /// and a default is not knowledge — it is a proposal. A caller that wants to propose one must
    /// do it on screen, where the user can see the address and change it before anything is sent
    /// there; merging it in here would make a guess indistinguishable from a fact at every call
    /// site, which is the shape `DEBTS.md` D-B1 §2 refused.
    func knownLLMEndpoints(for provider: LLMProvider) -> [String] {
        let candidates = [
            provider == llmProvider ? llmBaseURLString : nil,
            rememberedEndpoint(for: provider)?.url,
            benchmarkTarget?.provider == provider ? benchmarkTarget?.baseURLString : nil,
        ]
        var seen: Set<String> = []
        return candidates
            .compactMap { Self.nonBlank($0) }
            .filter { seen.insert($0.normalizedBaseURL).inserted }
    }

    /// `nil` for nil/empty/whitespace-only — restore-time filter so a blank
    /// remembered field falls through to the provider default.
    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    var llmBaseURLString: String {
        didSet { storage.set(llmBaseURLString, forKey: Keys.llmBaseURL) }
    }

    var llmModelName: String {
        didSet { storage.set(llmModelName, forKey: Keys.llmModel) }
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

    /// Persisted Watchtower inbox dismissals. Each entry is
    /// `"<workFolderUUID>:<WatchtowerDismissKey.storageKey>"` — the same namespacing
    /// `seenSupervisorInputKeys` uses, and for the same reason (task IDs are
    /// per-folder sequential ints). Mutated only through the typed helpers below;
    /// `private(set)` so no caller can hand-roll an un-namespaced entry.
    ///
    /// Every helper checks membership before mutating (`contains` per key; the filtered
    /// count in `forgetDismissals`): `Set.insert` of a member, `Set.remove` of a
    /// non-member and a filter that drops nothing leave the set unchanged but still fire `didSet`, i.e.
    /// a whole-set re-serialisation to UserDefaults plus an observation tick — and the
    /// no-op IS the common case (every answer retires a key that is almost never there,
    /// `MainLayoutView` re-dismisses every visible banner on each chat open). A check
    /// that decides whether to write must not cost the write (CLAUDE.md #106); pinned by
    /// `DismissalStoreProbe`.
    private(set) var dismissedNotificationKeys: Set<String> {
        didSet {
            #if DEBUG
            DismissalStoreProbe.noteWrite()
            #endif
            storage.set(Array(dismissedNotificationKeys), forKey: Keys.dismissedNotificationIDs)
        }
    }

    func dismissNotification(workFolderID: UUID, key: WatchtowerDismissKey) {
        let entry = Self.dismissEntry(workFolderID: workFolderID, key: key)
        guard !dismissedNotificationKeys.contains(entry) else { return }
        dismissedNotificationKeys.insert(entry)
    }

    func undismissNotification(workFolderID: UUID, key: WatchtowerDismissKey) {
        let entry = Self.dismissEntry(workFolderID: workFolderID, key: key)
        guard dismissedNotificationKeys.contains(entry) else { return }
        dismissedNotificationKeys.remove(entry)
    }

    /// Batch form — one `didSet`, therefore one `UserDefaults` write and one
    /// observation tick, for a garbage-collection sweep that expires several keys.
    /// Membership is checked per KEY (O(|keys|) hashed lookups), never by walking the
    /// stored set; no hit ⇒ no write.
    func undismissNotifications(workFolderID: UUID, keys: Set<WatchtowerDismissKey>) {
        let hits = keys.map { Self.dismissEntry(workFolderID: workFolderID, key: $0) }
            .filter { dismissedNotificationKeys.contains($0) }
        guard !hits.isEmpty else { return }
        dismissedNotificationKeys.subtract(hits)
    }

    func isDismissed(workFolderID: UUID, key: WatchtowerDismissKey) -> Bool {
        dismissedNotificationKeys.contains(Self.dismissEntry(workFolderID: workFolderID, key: key))
    }

    /// Every dismissal recorded for one work folder, decoded back into keys.
    /// Entries that no longer parse (a format that predates `WatchtowerDismissKey`)
    /// are skipped rather than guessed at.
    func dismissedKeys(forWorkFolder workFolderID: UUID) -> Set<WatchtowerDismissKey> {
        let prefix = "\(workFolderID.uuidString):"
        var result: Set<WatchtowerDismissKey> = []
        for entry in dismissedNotificationKeys where entry.hasPrefix(prefix) {
            if let key = WatchtowerDismissKey(storageKey: String(entry.dropFirst(prefix.count))) {
                result.insert(key)
            }
        }
        return result
    }

    /// Drops every dismissal belonging to one task — called when the task is closed or
    /// deleted, so nothing of it rides the set into later sessions. A task that never had
    /// a banner dismissed is the common closed task, and a filter that drops nothing must
    /// not re-serialise the set (see the property's doc).
    func forgetDismissals(workFolderID: UUID, taskID: Int) {
        let prefix = "\(workFolderID.uuidString):t\(taskID)::"
        let kept = dismissedNotificationKeys.filter { !$0.hasPrefix(prefix) }
        // The filter is the membership check here; a count compare costs nothing more.
        guard kept.count != dismissedNotificationKeys.count else { return }
        dismissedNotificationKeys = kept
    }

    private static func dismissEntry(workFolderID: UUID, key: WatchtowerDismissKey) -> String {
        "\(workFolderID.uuidString):\(key.storageKey)"
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

    /// Which API family the Vision server speaks. `nil` = inherit the global
    /// provider. Needed because `visionBaseURLString` can point at a DIFFERENT
    /// server than the global chat LLM — after a global provider flip, an
    /// explicit LM Studio vision server must not be spoken to in Ollama wire
    /// format (and vice versa). Resolution lives in `resolvedVisionProvider`.
    var visionProvider: LLMProvider? {
        didSet {
            if let visionProvider {
                storage.set(visionProvider.rawValue, forKey: Keys.visionProvider)
            } else {
                storage.removeObject(forKey: Keys.visionProvider)
            }
        }
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
        // error. The empty→global fallback (symmetric trimming on BOTH the URL
        // and the model name) lives in `StoreConfiguration+ModelResolution` so
        // the model-switch hook resolves it identically — a second, hand-rolled
        // copy in the view diverged on whitespace.
        let resolvedURL = resolvedVisionBaseURL
        guard !resolvedURL.isEmpty else { return nil }

        return LLMConfig(
            provider: resolvedVisionProvider,
            baseURLString: resolvedURL,
            modelName: resolvedVisionModel(for: visionModelName),
            requestTimeoutSeconds: llmRequestTimeoutSeconds,
            keepAliveSeconds: ollamaKeepAliveSeconds
        )
    }

    /// Maximum consecutive LLM server error retries before failing the step. 0 = unlimited.
    /// The benchmark screen's own target. `nil` until the user first opens the screen, which
    /// seeds it from the active LLM settings; from then on the two are independent, so measuring
    /// a model never switches the app onto it.
    var benchmarkTarget: BenchmarkTarget? {
        didSet {
            guard let benchmarkTarget,
                  let data = try? JSONCoderFactory.makePersistenceEncoder().encode(benchmarkTarget)
            else {
                storage.removeObject(forKey: Keys.benchmarkTarget)
                return
            }
            storage.set(data, forKey: Keys.benchmarkTarget)
        }
    }

    /// Measured samples per benchmark run, excluding the warm-up.
    ///
    /// Clamped to the range the UI offers rather than trusted: a hand-edited default of 0 would
    /// make every run fail with "no usable samples", and a huge one would hold the machine for
    /// minutes with no way to tell that from a hang.
    /// Providers the user has switched OFF for the sweep.
    ///
    /// Persisted, unlike the rest of the sweep's screen state, because it is the one part that is
    /// a safety statement rather than a view: "measure what you like, but do not unload my
    /// Ollama". A preference that evaporated on relaunch would silently re-arm the unloads it was
    /// set to prevent, and the user would have no reason to look.
    var benchmarkExcludedProviders: Set<LLMProvider> {
        didSet {
            guard benchmarkExcludedProviders != oldValue else { return }
            storage.set(
                benchmarkExcludedProviders.map(\.rawValue).sorted(),
                forKey: Keys.benchmarkExcludedProviders)
        }
    }

    var benchmarkRepeats: Int {
        didSet {
            let clamped = min(max(benchmarkRepeats, AppDefaults.benchmarkRepeatsRange.lowerBound),
                              AppDefaults.benchmarkRepeatsRange.upperBound)
            if clamped != benchmarkRepeats {
                benchmarkRepeats = clamped
                return
            }
            storage.set(benchmarkRepeats, forKey: Keys.benchmarkRepeats)
        }
    }

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

    /// Seconds Ollama is asked to keep the model (and its KV prefix cache) resident.
    /// Only reaches the wire for Ollama — LM Studio residency is managed explicitly by
    /// `ChatModelEnsurer`. `0` unloads immediately; negative keeps it loaded indefinitely.
    var ollamaKeepAliveSeconds: Int {
        didSet {
            storage.set(ollamaKeepAliveSeconds, forKey: Keys.ollamaKeepAliveSeconds)
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

    /// LM Studio chat instances this app manages, persisted so they survive a
    /// relaunch. Without this the ledger is in-memory only, and a model the app
    /// loaded in a previous session becomes permanently unreclaimable: it is no
    /// longer referenced by any slot, so adoption skips it, and residency
    /// reconciliation only ever unloads what it owns. Entries are re-claimed on
    /// open ONLY if the instance is still resident (see `ChatModelEnsurer.restore`).
    var chatModelLedger: [OwnedChatModel] {
        didSet {
            if chatModelLedger.isEmpty {
                storage.removeObject(forKey: Keys.chatModelLedger)
            } else if let data = try? JSONCoderFactory.makePersistenceEncoder()
                .encode(chatModelLedger) {
                storage.set(data, forKey: Keys.chatModelLedger)
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

    /// App-wide instruction injected into the system prompt of every TOOL-LOOP
    /// LLM call. Exactly three consumers: step execution, `ask_teammate`
    /// consultation, team meetings. One-shot calls — supervisor auto-answer,
    /// work-folder context generation, team generation, vision — deliberately do
    /// NOT receive it. Defaults to `AppDefaults.globalContext`; an empty value
    /// emits no `## Global guidance` section at all rather than a bodyless header.
    ///
    /// Persistence semantics intentionally diverge from `teamGenSystemPrompt`:
    /// empty string is persisted AS empty (not removed) so the user can clear
    /// the field and have the cleared state stick. First launch with no stored
    /// key reads `AppDefaults.globalContext` via `object(forKey:) as? String ??
    /// AppDefaults.globalContext`, and that fallback does NOT persist (`didSet`
    /// never fires during `init`) — which is the only reason a new default reaches
    /// an untouched install at all.
    ///
    /// A stored copy of a default is what PINS an install: assigning the default
    /// fires `didSet` and persists it, after which no future default can reach it.
    /// Both former offenders are fixed — `resetToDefaults()` re-removes the key
    /// after its assignment, and the settings card routes through
    /// `resetGlobalContextToDefault()` instead of assigning directly.
    /// `purgeStaleDefaultGlobalContext` unwinds the installs already pinned by the
    /// old behaviour, byte-exactly, without discarding a real customisation.
    ///
    /// LM Studio session caveat: changes only take effect on fresh sessions
    /// (new run, restart role, revision, HTTP 400 fallback). `system_prompt` is
    /// omitted on stateful continuations, so an in-flight step's response chain
    /// still uses the value baked in at session start.
    var globalContext: String {
        didSet { storage.set(globalContext, forKey: Keys.globalContext) }
    }

    /// Restore `globalContext` to the shipped default WITHOUT pinning a copy of it.
    ///
    /// The obvious `config.globalContext = AppDefaults.globalContext` is the exact
    /// move that created the pinned cohort `purgeStaleDefaultGlobalContext` exists
    /// to unwind: `didSet` persists the assigned value, so the install stops
    /// following the shipped default from that click onward. Assign (for the
    /// in-memory value and the observation it publishes), then drop the key so the
    /// `init` fallback owns the value again on the next launch.
    func resetGlobalContextToDefault() {
        globalContext = AppDefaults.globalContext
        storage.removeObject(forKey: Keys.globalContext)
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

    // MARK: - Computer Use (screen control)

    /// How computer-use actions are resolved. Default `.off`.
    var computerUseMode: ComputerUseMode {
        didSet { storage.set(computerUseMode.rawValue, forKey: Keys.computerUseMode) }
    }
    /// Strictness fed to the Auto judge. Default `.standard`.
    var computerUseRestrictionLevel: ComputerUseRestrictionLevel {
        didSet { storage.set(computerUseRestrictionLevel.rawValue, forKey: Keys.computerUseRestrictionLevel) }
    }
    /// Bundle ids / app names the tools may target. Empty = any app.
    var computerUseTargetAppAllowlist: [String] {
        didSet { storage.set(computerUseTargetAppAllowlist, forKey: Keys.computerUseTargetAppAllowlist) }
    }
    /// Patterns that force-deny `ui_type`. Empty by default.
    var computerUseBlockedTypingPatterns: [String] {
        didSet { storage.set(computerUseBlockedTypingPatterns, forKey: Keys.computerUseBlockedTypingPatterns) }
    }
    /// Patterns that force-deny `ui_key`. Empty by default.
    var computerUseBlockedKeyCombos: [String] {
        didSet { storage.set(computerUseBlockedKeyCombos, forKey: Keys.computerUseBlockedKeyCombos) }
    }
    /// Activate + raise the target window before a click/type. Default on.
    var computerUseRaiseTargetWindowBeforeClick: Bool {
        didSet { storage.set(computerUseRaiseTargetWindowBeforeClick, forKey: Keys.computerUseRaiseTargetWindowBeforeClick) }
    }
    /// Gate only the first `screen_capture` per run, then auto-allow. Default on.
    var computerUseGateFirstCaptureOnly: Bool {
        didSet { storage.set(computerUseGateFirstCaptureOnly, forKey: Keys.computerUseGateFirstCaptureOnly) }
    }
    /// Optional dedicated LLM override for the Auto judge (token via Keychain by URL).
    var computerUseJudgeLLMOverride: LLMOverride? {
        didSet {
            if let o = computerUseJudgeLLMOverride, !o.isEmpty,
               let data = try? JSONCoderFactory.makePersistenceEncoder().encode(o) {
                storage.set(data, forKey: Keys.computerUseJudgeLLMOverride)
            } else {
                storage.removeObject(forKey: Keys.computerUseJudgeLLMOverride)
            }
        }
    }

    /// Mirrors `ComputerUsePolicy.isEnabled` for view-layer callers that hold the
    /// config, not the assembled policy (same convention as `isVisionConfigured`).
    var isComputerUseEnabled: Bool { computerUseMode != .off }

    /// Assembled `ComputerUsePolicy` surfaced to the LLM execution layer.
    var computerUsePolicy: ComputerUsePolicy {
        ComputerUsePolicy(
            mode: computerUseMode,
            restrictionLevel: computerUseRestrictionLevel,
            targetAppAllowlist: computerUseTargetAppAllowlist,
            blockedTypingPatterns: computerUseBlockedTypingPatterns,
            blockedKeyCombos: computerUseBlockedKeyCombos,
            raiseTargetWindowBeforeClick: computerUseRaiseTargetWindowBeforeClick,
            gateFirstCaptureOnly: computerUseGateFirstCaptureOnly,
            judgeOverride: computerUseJudgeLLMOverride
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

    /// Vision is ON out of the box: with an empty `visionModelName` the
    /// request-time fallback in `visionLLMConfig` inherits the global model,
    /// so enabling by default makes `analyze_image` work as soon as the
    /// global LLM is configured. An explicitly stored toggle value always
    /// wins over this default.
    private static let defaultVisionEnabled = true

    init(storage: any ConfigurationStorage = UserDefaults.standard) {
        self.storage = storage
        Self.purgeStaleDefaultGlobalContext(storage)
        self.providerEndpointMemory = storage.data(forKey: Keys.llmProviderEndpoints)
            .flatMap { try? JSONDecoder().decode([String: ProviderEndpoint].self, from: $0) }
            ?? [:]
        let providerRaw = storage.string(forKey: Keys.llmProvider)
        let provider = providerRaw.flatMap(LLMProvider.init(rawValue:)) ?? .lmStudio
        self.llmProvider = provider
        self.llmBaseURLString = storage.string(forKey: Keys.llmBaseURL) ?? provider.defaultBaseURL
        self.llmModelName = storage.string(forKey: Keys.llmModel) ?? provider.defaultModel
        self.enterSendsMessage = (storage.object(forKey: Keys.enterSendsMessage) as? Bool) ?? true
        self.embedFilesInPrompt = storage.bool(forKey: Keys.embedFilesInPrompt)
        self.debugModeEnabled = storage.bool(forKey: Keys.debugModeEnabled)
        self.loggingEnabled = (storage.object(forKey: Keys.loggingEnabled) as? Bool) ?? Self.defaultLoggingEnabled
        self.sidebarTaskFilter = storage.string(forKey: Keys.sidebarTaskFilter)
            .flatMap(TaskFilter.init(rawValue:)) ?? .all
        self.benchmarkRepeats = (storage.object(forKey: Keys.benchmarkRepeats) as? Int)
            ?? AppDefaults.benchmarkRepeats
        self.benchmarkTarget = storage.data(forKey: Keys.benchmarkTarget)
            .flatMap { try? JSONCoderFactory.makeDateDecoder().decode(BenchmarkTarget.self, from: $0) }
        self.benchmarkExcludedProviders = Set(
            (storage.object(forKey: Keys.benchmarkExcludedProviders) as? [String] ?? [])
                .compactMap(LLMProvider.init(rawValue:)))
        self.maxLLMRetries = (storage.object(forKey: Keys.maxLLMRetries) as? Int) ?? LLMConstants.defaultMaxLLMRetries
        self.llmRequestTimeoutSeconds = (storage.object(forKey: Keys.llmRequestTimeoutSeconds) as? Int) ?? LLMConstants.defaultLLMRequestTimeoutSeconds
        self.ollamaKeepAliveSeconds = (storage.object(forKey: Keys.ollamaKeepAliveSeconds) as? Int) ?? LLMConstants.defaultOllamaKeepAliveSeconds
        self.timelineClearedUpToDate = storage.object(forKey: Keys.timelineClearedUpToDate) as? Date
        self.visionModelName = storage.string(forKey: Keys.visionModelName) ?? ""
        self.visionBaseURLString = storage.string(forKey: Keys.visionBaseURL) ?? ""
        self.visionProvider = storage.string(forKey: Keys.visionProvider)
            .flatMap(LLMProvider.init(rawValue:))
        // An explicitly stored toggle value (user touched the setting) always
        // wins; while the key is absent — fresh installs and upgrades that
        // never opened Vision settings — Vision defaults to ON. This subsumes
        // the old back-compat rule (ON only when a vision model was stored).
        self.visionEnabled = (storage.object(forKey: Keys.visionEnabled) as? Bool)
            ?? Self.defaultVisionEnabled
        let rawIDs = (storage.object(forKey: Keys.dismissedNotificationIDs) as? [String]) ?? []
        self.dismissedNotificationKeys = Set(rawIDs)
        // One-shot: `.v1` held bare `dismissID` strings with no task scope, so they
        // can neither be matched nor expired under the new format. Delete rather than
        // leave permanent garbage; the visible cost is that a handful of pre-upgrade
        // dismissals reappear once, which is the safe direction (a banner returning
        // beats a banner suppressed forever).
        // TODO(2026-Q4): remove once all live installs have purged.
        storage.removeObject(forKey: Keys.legacyDismissedNotificationIDsV1)
        let rawTipIDs = (storage.object(forKey: Keys.dismissedFeatureTipIDs) as? [String]) ?? []
        self.dismissedFeatureTipIDs = Set(rawTipIDs)
        let rawSeenKeys = (storage.object(forKey: Keys.seenSupervisorInputKeys) as? [String]) ?? []
        self.seenSupervisorInputKeys = Set(rawSeenKeys)
        self.chatModelLedger = storage.data(forKey: Keys.chatModelLedger)
            .flatMap { try? JSONCoderFactory.makeDateDecoder().decode([OwnedChatModel].self, from: $0) }
            ?? []
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
        // One-shot migration of the legacy plain `bashJudgeModel` string into the
        // override struct. Shipped 2026-06-27; carried no date until 2026-09-05, which
        // is why the scan that guards dated obligations could not see it (DEBTS.md D-32).
        // TODO(2026-Q4): remove once all live installs have migrated.
        if let data = storage.data(forKey: Keys.bashJudgeLLMOverride),
           let decoded = try? JSONCoderFactory.makeDateDecoder().decode(LLMOverride.self, from: data),
           !decoded.isEmpty {
            self.bashJudgeLLMOverride = decoded
        } else if let legacyModel = storage.string(forKey: Keys.bashJudgeModel),
                  !legacyModel.trimmingCharacters(in: .whitespaces).isEmpty {
            let migrated = LLMOverride(modelName: legacyModel)
            self.bashJudgeLLMOverride = migrated
            // Write through ONCE and drop the legacy key (didSet doesn't fire during
            // init) — without this the migration re-runs every launch and could
            // resurrect an override the user later cleared.
            if let data = try? JSONCoderFactory.makePersistenceEncoder().encode(migrated) {
                storage.set(data, forKey: Keys.bashJudgeLLMOverride)
            }
            storage.removeObject(forKey: Keys.bashJudgeModel)
        } else {
            self.bashJudgeLLMOverride = nil
        }
        self.computerUseMode = storage.string(forKey: Keys.computerUseMode)
            .flatMap(ComputerUseMode.init(rawValue:)) ?? .manual
        self.computerUseRestrictionLevel = storage.string(forKey: Keys.computerUseRestrictionLevel)
            .flatMap(ComputerUseRestrictionLevel.init(rawValue:)) ?? .standard
        self.computerUseTargetAppAllowlist = (storage.object(forKey: Keys.computerUseTargetAppAllowlist) as? [String]) ?? []
        self.computerUseBlockedTypingPatterns = (storage.object(forKey: Keys.computerUseBlockedTypingPatterns) as? [String]) ?? []
        self.computerUseBlockedKeyCombos = (storage.object(forKey: Keys.computerUseBlockedKeyCombos) as? [String]) ?? []
        self.computerUseRaiseTargetWindowBeforeClick = (storage.object(forKey: Keys.computerUseRaiseTargetWindowBeforeClick) as? Bool) ?? true
        self.computerUseGateFirstCaptureOnly = (storage.object(forKey: Keys.computerUseGateFirstCaptureOnly) as? Bool) ?? true
        if let data = storage.data(forKey: Keys.computerUseJudgeLLMOverride),
           let decoded = try? JSONCoderFactory.makeDateDecoder().decode(LLMOverride.self, from: data), !decoded.isEmpty {
            self.computerUseJudgeLLMOverride = decoded
        } else {
            self.computerUseJudgeLLMOverride = nil
        }
    }

    // MARK: - Migration

    /// One-shot: drop a stored `globalContext` byte-identical to any RETIRED
    /// default, so the current `AppDefaults.globalContext` applies again.
    ///
    /// Concretely this is what frees an install still carrying the
    /// `Exception: 2–3 genuinely independent reads` escape clause — the text the
    /// current bare rule exists to replace, and the one a reasoning model spends
    /// its turn adjudicating.
    ///
    /// A user who never touched the setting has no stored key at all (the
    /// `?? AppDefaults.globalContext` fallback in `init` does not persist —
    /// `didSet` never fires during `init`), so they pick up a new default for
    /// free. The pinned cohort is everyone who clicked "Reset to Default" or ran
    /// `resetToDefaults()` back when both ASSIGNED the then-current default and
    /// persisted a copy of it through `didSet`. Both paths are fixed now (they
    /// share `resetGlobalContextToDefault()`, which drops the key after assigning),
    /// so the cohort is closed and this purge only unwinds the installs in it.
    ///
    /// Removing the KEY rather than overwriting it with today's default is what
    /// makes those installs track FUTURE defaults too.
    ///
    /// Matching byte-exactly is the whole safety property: a value equal to a
    /// shipped default is a copy, never a choice, so removing it cannot discard
    /// a customisation. Bumping the key to `.v2` would — that is why this is a
    /// targeted purge and not a version bump.
    /// Idempotent. Deliberately carries NO `TODO(<year>-Q<n>)`: every future retirement
    /// of a `globalContext` default re-arms this purge by adding a literal to
    /// `AppDefaults.retiredGlobalContextDefaults`, so the only action a date could ever
    /// prompt is extending it — and a date that can only be extended is noise in the scan
    /// that guards real deadlines. What discharges this is the roster going empty, not a
    /// quarter passing (DEBTS.md D-32, 2026-09-05).
    private static func purgeStaleDefaultGlobalContext(_ storage: any ConfigurationStorage) {
        // Unwrap BEFORE the roster lookup. The old `Optional<String> == String`
        // comparison typechecked; `[String].contains` does not, and the shortcut
        // fix (`?? ""`) would make an accidental empty roster entry match every
        // untouched install.
        guard let stored = storage.object(forKey: Keys.globalContext) as? String,
              AppDefaults.retiredGlobalContextDefaults.contains(stored) else { return }
        storage.removeObject(forKey: Keys.globalContext)
    }

    // MARK: - Reset

    func resetToDefaults() {
        storage.removeObject(forKey: Keys.llmProvider)
        storage.removeObject(forKey: Keys.llmProviderEndpoints)
        storage.removeObject(forKey: Keys.llmBaseURL)
        storage.removeObject(forKey: Keys.llmModel)
        storage.removeObject(forKey: Keys.enterSendsMessage)
        storage.removeObject(forKey: Keys.embedFilesInPrompt)
        storage.removeObject(forKey: Keys.debugModeEnabled)
        storage.removeObject(forKey: Keys.loggingEnabled)
        storage.removeObject(forKey: Keys.benchmarkRepeats)
        storage.removeObject(forKey: Keys.benchmarkTarget)
        storage.removeObject(forKey: Keys.benchmarkExcludedProviders)
        storage.removeObject(forKey: Keys.maxLLMRetries)
        storage.removeObject(forKey: Keys.llmRequestTimeoutSeconds)
        storage.removeObject(forKey: Keys.ollamaKeepAliveSeconds)
        storage.removeObject(forKey: Keys.visionEnabled)
        storage.removeObject(forKey: Keys.visionModelName)
        storage.removeObject(forKey: Keys.visionBaseURL)
        storage.removeObject(forKey: Keys.visionProvider)
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
        storage.removeObject(forKey: Keys.computerUseMode)
        storage.removeObject(forKey: Keys.computerUseRestrictionLevel)
        storage.removeObject(forKey: Keys.computerUseTargetAppAllowlist)
        storage.removeObject(forKey: Keys.computerUseBlockedTypingPatterns)
        storage.removeObject(forKey: Keys.computerUseBlockedKeyCombos)
        storage.removeObject(forKey: Keys.computerUseRaiseTargetWindowBeforeClick)
        storage.removeObject(forKey: Keys.computerUseGateFirstCaptureOnly)
        storage.removeObject(forKey: Keys.computerUseJudgeLLMOverride)

        let provider = LLMProvider.lmStudio
        // Wipe BEFORE the provider assignment (whose didSet would re-remember
        // the outgoing endpoint) AND re-remove the key after it, so a reset
        // from a non-default provider leaves no endpoint memory behind.
        providerEndpointMemory = [:]
        llmProvider = provider
        providerEndpointMemory = [:]
        storage.removeObject(forKey: Keys.llmProviderEndpoints)
        llmBaseURLString = provider.defaultBaseURL
        llmModelName = provider.defaultModel
        enterSendsMessage = true
        embedFilesInPrompt = false
        debugModeEnabled = false
        loggingEnabled = Self.defaultLoggingEnabled
        benchmarkRepeats = AppDefaults.benchmarkRepeats
        benchmarkTarget = nil
        benchmarkExcludedProviders = []
        maxLLMRetries = LLMConstants.defaultMaxLLMRetries
        llmRequestTimeoutSeconds = LLMConstants.defaultLLMRequestTimeoutSeconds
        ollamaKeepAliveSeconds = LLMConstants.defaultOllamaKeepAliveSeconds
        visionEnabled = Self.defaultVisionEnabled
        visionProvider = nil
        visionModelName = ""
        visionBaseURLString = ""
        dismissedNotificationKeys = []
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
        // NOT a bare `globalContext = AppDefaults.globalContext`: that assignment's
        // `didSet` re-persists the default and undoes the removal near the top of
        // this function, pinning the install to today's text. The helper assigns
        // and then drops the key again — same contract as the settings card's
        // Reset button, so the two can't drift.
        resetGlobalContextToDefault()
        bashMode = BashConstants.defaultMode
        bashRestrictionLevel = BashConstants.defaultRestrictionLevel
        bashAllowRules = []
        bashAskRules = []
        bashDenyRules = []
        bashSandboxEnabled = BashConstants.defaultSandboxEnabled
        bashSandboxPermissions = BashSandboxPermissions()
        bashAllowUnsandboxedFallback = false
        bashJudgeLLMOverride = nil
        computerUseMode = .manual
        computerUseRestrictionLevel = .standard
        computerUseTargetAppAllowlist = []
        computerUseBlockedTypingPatterns = []
        computerUseBlockedKeyCombos = []
        computerUseRaiseTargetWindowBeforeClick = true
        computerUseGateFirstCaptureOnly = true
        computerUseJudgeLLMOverride = nil
        // The URL and model above were reset programmatically. `llmProvider`'s
        // `didSet` bumps only when the provider actually CHANGED, so a reset that
        // leaves the provider alone would otherwise strand endpoint-keyed views on
        // the pre-reset generation.
        noteLLMEndpointCommitted()
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
            requestTimeoutSeconds: llmRequestTimeoutSeconds,
            keepAliveSeconds: ollamaKeepAliveSeconds
        )
    }
    nonisolated deinit {}
}

#if DEBUG
/// Work-bound seam for the persisted dismissal set: how many times `didSet`
/// re-serialised the WHOLE set to UserDefaults since the last reset.
///
/// It lives inside the `didSet`, not beside a call site, for the reason CLAUDE.md #62
/// records: the defect being pinned is a mutation that changes nothing and still
/// writes, and a counter placed at the helper's entry would count calls whether or
/// not they wrote. A regression here is invisible in OUTPUT — a redundant identical
/// write returns exactly the same dismissal state — which is why the pin is a
/// counter, not an assertion on the set.
nonisolated enum DismissalStoreProbe {
    private static let _writes = Atomic<Int>(0)
    static func noteWrite() { _writes.wrappingAdd(1, ordering: .relaxed) }
    static func _testWrites() -> Int { _writes.load(ordering: .relaxed) }
    static func _testReset() { _writes.store(0, ordering: .relaxed) }
}
#endif
