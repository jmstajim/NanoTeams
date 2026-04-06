import Foundation

/// Service responsible for managing role definitions, tool definitions, and project settings.
@MainActor
final class SettingsService {
    private let repository: any NTMSRepositoryProtocol

    init(repository: any NTMSRepositoryProtocol) {
        self.repository = repository
    }

    func saveToolDefinitions(_ tools: [ToolDefinitionRecord], at url: URL) throws -> WorkFolderContext {
        try repository.updateTools(at: url, tools: tools)
    }

    func resetWorkFolderSettings(at url: URL) throws -> WorkFolderContext {
        print("[SettingsService] Resetting at: \(url.path)")
        return try repository.resetWorkFolderSettings(at: url)
    }
}
