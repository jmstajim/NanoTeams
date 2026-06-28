import Foundation

// UserDefaults persistence-key registry for StoreConfiguration. A distinct
// concern from the live observable settings + their mutators (which stay
// co-located in the main type per Information Expert).
extension StoreConfiguration {

    enum Keys {
        static let llmProvider = "llmProvider"
        static let llmBaseURL = UserDefaultsKeys.llmBaseURL
        static let llmModel = UserDefaultsKeys.llmModel
        static let llmMaxTokens = "llmMaxTokens"
        static let llmTemperature = "llmTemperature"
        static let debugModeEnabled = UserDefaultsKeys.debugModeEnabled
        static let maxLLMRetries = UserDefaultsKeys.maxLLMRetries
        static let llmRequestTimeoutSeconds = UserDefaultsKeys.llmRequestTimeoutSeconds
        static let timelineClearedUpToDate = UserDefaultsKeys.timelineClearedUpToDate
        static let visionEnabled = UserDefaultsKeys.visionEnabled
        static let visionModelName = UserDefaultsKeys.visionModelName
        static let visionBaseURL = UserDefaultsKeys.visionBaseURL
        static let visionMaxTokens = UserDefaultsKeys.visionMaxTokens
        static let dismissedNotificationIDs = UserDefaultsKeys.dismissedNotificationIDs
        static let dismissedFeatureTipIDs = UserDefaultsKeys.dismissedFeatureTipIDs
        static let seenSupervisorInputKeys = UserDefaultsKeys.seenSupervisorInputKeys
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
        static let searchIndexWatcherDebounceSeconds = UserDefaultsKeys.searchIndexWatcherDebounceSeconds
        static let searchContextBefore = UserDefaultsKeys.searchContextBefore
        static let searchContextAfter = UserDefaultsKeys.searchContextAfter
        static let globalContext = UserDefaultsKeys.globalContext
        static let bashMode = UserDefaultsKeys.bashMode
        static let bashRestrictionLevel = UserDefaultsKeys.bashRestrictionLevel
        static let bashAllowRules = UserDefaultsKeys.bashAllowRules
        static let bashAskRules = UserDefaultsKeys.bashAskRules
        static let bashDenyRules = UserDefaultsKeys.bashDenyRules
        static let bashSandboxEnabled = UserDefaultsKeys.bashSandboxEnabled
        static let bashSandboxPermissions = UserDefaultsKeys.bashSandboxPermissions
        static let bashAllowUnsandboxedFallback = UserDefaultsKeys.bashAllowUnsandboxedFallback
        static let bashJudgeModel = UserDefaultsKeys.bashJudgeModel
        static let bashJudgeLLMOverride = UserDefaultsKeys.bashJudgeLLMOverride
    }
}
