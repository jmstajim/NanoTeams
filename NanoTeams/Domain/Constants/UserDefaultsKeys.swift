import Foundation

/// Centralized UserDefaults keys.
/// New keys use the `NanoTeams.<area>.<name>.v1` convention. Legacy keys below
/// (without the prefix/suffix) were introduced before the convention and are
/// kept verbatim so existing installs keep reading their stored values.
nonisolated enum UserDefaultsKeys {
    static let llmBaseURL = "NanoTeams.llm.baseURL.v1"
    static let llmModel = "NanoTeams.llm.model.v1"
    static let debugModeEnabled = "NanoTeams.ui.debugModeEnabled.v1"
    static let maxLLMRetries = "NanoTeams.llm.maxRetries.v1"
    static let llmRequestTimeoutSeconds = "NanoTeams.llm.requestTimeoutSeconds.v1"
    static let lastOpenedWorkFolderPath = "LastOpenedProjectPath"
    static let appAppearance = "appAppearance"
    /// Selected dark-mode theme — one of `Theme.allCases.rawValue`. Applied only
    /// when the effective color scheme resolves to dark; light always uses the
    /// shared paper palette regardless of this value.
    static let activeTheme = "NanoTeams.ui.activeTheme.v1"
    /// Whether the `NTMSLoader` spinner fires its decorative glitch bursts
    /// (character scramble + RGB-split + jitter). `false` keeps the spinner
    /// rotating but suppresses the glitch flourish. Default on (absent ⇒ on).
    static let spinnerGlitchEnabled = "NanoTeams.ui.spinnerGlitchEnabled.v1"
    static let selectedSettingsTab = "selectedSettingsTab"
    static let timelineClearedUpToDate = "NanoTeams.ui.timelineClearedUpToDate.v1"
    static let visionEnabled = "NanoTeams.vision.enabled.v1"
    static let visionModelName = "NanoTeams.vision.model.v1"
    static let visionBaseURL = "NanoTeams.vision.baseURL.v1"
    static let quickCapturePanelFrame = "NanoTeams.QuickCapturePanel"
    static let dismissedNotificationIDs = "NanoTeams.ui.dismissedNotificationIDs.v1"
    static let dismissedFeatureTipIDs = "NanoTeams.ui.dismissedFeatureTipIDs.v1"
    /// Persisted sidebar "read" markers for chat tasks awaiting Supervisor input.
    /// Stored as `Set<String>` of `"<workFolderUUID>:<taskID>"`. Namespacing by
    /// work folder is required because task IDs are per-folder sequential `Int`s
    /// starting at 1 — without it, opening a different folder would mis-attribute
    /// seen state to unrelated tasks.
    static let seenSupervisorInputKeys = "NanoTeams.ui.seenSupervisorInputKeys.v1"
    static let graphPanelVisible = "NanoTeams.ui.graphPanelVisible.v1"
    static let quickCaptureKeepOpenInChat = "NanoTeams.ui.quickCaptureKeepOpenInChat.v1"
    static let enterSendsMessage = "NanoTeams.ui.enterSendsMessage.v1"
    static let loggingEnabled = "NanoTeams.debug.loggingEnabled.v1"
    static let sidebarTaskFilter = "NanoTeams.ui.sidebarTaskFilter.v1"
    static let quickCaptureEmbedFiles = "NanoTeams.ui.quickCaptureEmbedFiles.v1"
    static let teamGenLLMOverride = "NanoTeams.teamgen.llmOverride.v1"
    static let chatModelLedger = "NanoTeams.llm.chatModelLedger.v1"
    static let teamGenSystemPrompt = "NanoTeams.teamgen.systemPrompt.v1"
    static let teamGenForcedSupervisorMode = "NanoTeams.teamgen.forcedSupervisorMode.v1"
    static let teamGenForcedAcceptanceMode = "NanoTeams.teamgen.forcedAcceptanceMode.v1"
    static let lastAppUpdateCheckAt = "NanoTeams.appUpdate.lastCheckAt.v1"
    static let skippedAppUpdateTags = "NanoTeams.appUpdate.skippedTags.v1"
    static let cachedAppUpdateRelease = "NanoTeams.appUpdate.cachedRelease.v1"
    static let appUpdateCheckInterval = "NanoTeams.appUpdate.checkInterval.v1"
    /// Locale identifiers the user opted into for dictation (array of strings).
    /// Empty = no dictation language selected; the mic button routes the user
    /// to Settings → Dictation. There is no `preferredLanguages` fallback.
    static let dictationLocales = "NanoTeams.dictation.locales.v1"
    static let exploratorySearchEnabled = "NanoTeams.search.exploratorySearchEnabled.v1"
    static let exploratorySearchEmbeddingConfig = "NanoTeams.search.exploratorySearchEmbeddingConfig.v1"
    static let exploratorySearchPerTokenThreshold = "NanoTeams.search.exploratorySearchPerTokenThreshold.v1"
    static let exploratorySearchPhraseThreshold = "NanoTeams.search.exploratorySearchPhraseThreshold.v1"
    static let searchIndexWatcherDebounceSeconds = "NanoTeams.search.watcherDebounceSeconds.v1"
    static let searchExploratoryByDefault = "NanoTeams.search.exploratoryByDefault.v1"
    static let readFileMaxLines = "NanoTeams.read_file.maxLines.v1"
    static let searchMaxResults = "NanoTeams.search.maxResults.v1"
    static let searchContextBefore = "NanoTeams.search.contextBefore.v1"
    static let searchContextAfter = "NanoTeams.search.contextAfter.v1"
    static let globalContext = "NanoTeams.llm.globalContext.v1"
    // Bash (shell command execution) policy.
    static let bashMode = "NanoTeams.bash.mode.v1"
    static let bashRestrictionLevel = "NanoTeams.bash.restrictionLevel.v1"
    static let bashAllowRules = "NanoTeams.bash.allowRules.v1"
    static let bashAskRules = "NanoTeams.bash.askRules.v1"
    static let bashDenyRules = "NanoTeams.bash.denyRules.v1"
    static let bashSandboxEnabled = "NanoTeams.bash.sandboxEnabled.v1"
    static let bashSandboxPermissions = "NanoTeams.bash.sandboxPermissions.v1"
    static let bashAllowUnsandboxedFallback = "NanoTeams.bash.allowUnsandboxedFallback.v1"
    /// Legacy plain judge-model key; migrated into `bashJudgeLLMOverride` on read.
    static let bashJudgeModel = "NanoTeams.bash.judgeModel.v1"
    static let bashJudgeLLMOverride = "NanoTeams.bash.judgeLLMOverride.v1"
    // Computer Use (screen control) policy. Declared here (not as inline literals) so the
    // token-leak guard's `UserDefaultsKeys` scan covers them, matching every other setting.
    static let computerUseMode = "NanoTeams.computerUse.mode.v1"
    static let computerUseRestrictionLevel = "NanoTeams.computerUse.restrictionLevel.v1"
    static let computerUseTargetAppAllowlist = "NanoTeams.computerUse.targetAppAllowlist.v1"
    static let computerUseBlockedTypingPatterns = "NanoTeams.computerUse.blockedTypingPatterns.v1"
    static let computerUseBlockedKeyCombos = "NanoTeams.computerUse.blockedKeyCombos.v1"
    static let computerUseRaiseTargetWindowBeforeClick = "NanoTeams.computerUse.raiseTargetWindow.v1"
    static let computerUseGateFirstCaptureOnly = "NanoTeams.computerUse.gateFirstCapture.v1"
    static let computerUseJudgeLLMOverride = "NanoTeams.computerUse.judgeLLMOverride.v1"
}
