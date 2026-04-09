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
            maxTokens: visionMaxTokens
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
        static let timelineClearedUpToDate = UserDefaultsKeys.timelineClearedUpToDate
        static let visionModelName = UserDefaultsKeys.visionModelName
        static let visionBaseURL = UserDefaultsKeys.visionBaseURL
        static let visionMaxTokens = UserDefaultsKeys.visionMaxTokens
        static let dismissedNotificationIDs = UserDefaultsKeys.dismissedNotificationIDs
        static let enterSendsMessage = UserDefaultsKeys.enterSendsMessage
        static let embedFilesInPrompt = UserDefaultsKeys.quickCaptureEmbedFiles
        static let loggingEnabled = UserDefaultsKeys.loggingEnabled
        static let sidebarTaskFilter = UserDefaultsKeys.sidebarTaskFilter
    }

    init(storage: any ConfigurationStorage = UserDefaults.standard) {
        self.storage = storage
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
        self.loggingEnabled = storage.bool(forKey: Keys.loggingEnabled)
        self.sidebarTaskFilter = storage.string(forKey: Keys.sidebarTaskFilter)
            .flatMap(TaskFilter.init(rawValue:)) ?? .all
        self.maxLLMRetries = (storage.object(forKey: Keys.maxLLMRetries) as? Int) ?? LLMConstants.defaultMaxLLMRetries
        self.timelineClearedUpToDate = storage.object(forKey: Keys.timelineClearedUpToDate) as? Date
        self.visionModelName = storage.string(forKey: Keys.visionModelName) ?? ""
        self.visionBaseURLString = storage.string(forKey: Keys.visionBaseURL) ?? ""
        self.visionMaxTokens = (storage.object(forKey: Keys.visionMaxTokens) as? Int) ?? 0
        let rawIDs = (storage.object(forKey: Keys.dismissedNotificationIDs) as? [String]) ?? []
        self.dismissedNotificationIDs = Set(rawIDs)
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
        storage.removeObject(forKey: Keys.visionModelName)
        storage.removeObject(forKey: Keys.visionBaseURL)
        storage.removeObject(forKey: Keys.visionMaxTokens)
        storage.removeObject(forKey: Keys.dismissedNotificationIDs)
        storage.removeObject(forKey: Keys.sidebarTaskFilter)

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
        loggingEnabled = false
        maxLLMRetries = LLMConstants.defaultMaxLLMRetries
        visionModelName = ""
        visionBaseURLString = ""
        visionMaxTokens = 0
        dismissedNotificationIDs = []
        sidebarTaskFilter = .all
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
            temperature: llmTemperature
        )
    }
    nonisolated deinit {}
}
