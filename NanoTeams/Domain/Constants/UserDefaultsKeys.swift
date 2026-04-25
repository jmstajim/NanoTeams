import Foundation

/// Centralized UserDefaults keys.
/// New keys use the `NanoTeams.<area>.<name>.v1` convention. Legacy keys below
/// (without the prefix/suffix) were introduced before the convention and are
/// kept verbatim so existing installs keep reading their stored values.
enum UserDefaultsKeys {
    static let llmBaseURL = "NanoTeams.llm.baseURL.v1"
    static let llmModel = "NanoTeams.llm.model.v1"
    static let thinkingExpandedByDefault = "NanoTeams.ui.thinkingExpandedByDefault.v1"
    static let toolCallsExpandedByDefault = "NanoTeams.ui.toolCallsExpandedByDefault.v1"
    static let artifactsExpandedByDefault = "NanoTeams.ui.artifactsExpandedByDefault.v1"
    static let debugModeEnabled = "NanoTeams.ui.debugModeEnabled.v1"
    static let maxLLMRetries = "NanoTeams.llm.maxRetries.v1"
    static let llmRequestTimeoutSeconds = "NanoTeams.llm.requestTimeoutSeconds.v1"
    static let lastOpenedWorkFolderPath = "LastOpenedProjectPath"
    static let appAppearance = "appAppearance"
    static let selectedSettingsTab = "selectedSettingsTab"
    static let timelineClearedUpToDate = "NanoTeams.ui.timelineClearedUpToDate.v1"
    static let visionModelName = "NanoTeams.vision.model.v1"
    static let visionBaseURL = "NanoTeams.vision.baseURL.v1"
    static let visionMaxTokens = "NanoTeams.vision.maxTokens.v1"
    static let quickCapturePanelFrame = "NanoTeams.QuickCapturePanel"
    static let dismissedNotificationIDs = "NanoTeams.ui.dismissedNotificationIDs.v1"
    static let graphPanelVisible = "NanoTeams.ui.graphPanelVisible.v1"
    static let quickCaptureKeepOpenInChat = "NanoTeams.ui.quickCaptureKeepOpenInChat.v1"
    static let enterSendsMessage = "NanoTeams.ui.enterSendsMessage.v1"
    static let loggingEnabled = "NanoTeams.debug.loggingEnabled.v1"
    static let sidebarTaskFilter = "NanoTeams.ui.sidebarTaskFilter.v1"
    static let quickCaptureEmbedFiles = "NanoTeams.ui.quickCaptureEmbedFiles.v1"
    static let teamGenLLMOverride = "NanoTeams.teamgen.llmOverride.v1"
    static let teamGenSystemPrompt = "NanoTeams.teamgen.systemPrompt.v1"
    static let teamGenForcedSupervisorMode = "NanoTeams.teamgen.forcedSupervisorMode.v1"
    static let teamGenForcedAcceptanceMode = "NanoTeams.teamgen.forcedAcceptanceMode.v1"
    static let lastAppUpdateCheckAt = "NanoTeams.appUpdate.lastCheckAt.v1"
    static let skippedAppUpdateTags = "NanoTeams.appUpdate.skippedTags.v1"
    static let cachedAppUpdateRelease = "NanoTeams.appUpdate.cachedRelease.v1"
    static let appUpdateCheckInterval = "NanoTeams.appUpdate.checkInterval.v1"
    /// Locale identifiers the user opted into for dictation (array of strings).
    /// Empty = fall back to `Locale.preferredLanguages`.
    static let dictationLocales = "NanoTeams.dictation.locales.v1"
    static let expandedSearchEnabled = "NanoTeams.search.expandedSearchEnabled.v1"
    static let expandedSearchEmbeddingConfig = "NanoTeams.search.expandedSearchEmbeddingConfig.v1"
    static let expandedSearchPerTokenThreshold = "NanoTeams.search.expandedSearchPerTokenThreshold.v1"
    static let expandedSearchPhraseThreshold = "NanoTeams.search.expandedSearchPhraseThreshold.v1"
}
