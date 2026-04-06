import Foundation

/// Service for project folder management and description updates.
@MainActor
final class WorkFolderManagementService {
    private let repository: any NTMSRepositoryProtocol
    private let workFolderDescriptionService: WorkFolderDescriptionService

    init(
        repository: any NTMSRepositoryProtocol,
        workFolderDescriptionService: WorkFolderDescriptionService = WorkFolderDescriptionService()
    ) {
        self.repository = repository
        self.workFolderDescriptionService = workFolderDescriptionService
    }

    func openOrCreateWorkFolder(at url: URL) throws -> WorkFolderContext {
        try repository.openOrCreateWorkFolder(at: url)
    }

    func updateWorkFolderDescription(_ description: String, at url: URL) throws -> WorkFolderContext {
        try repository.updateWorkFolderDescription(
            at: url,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func generateWorkFolderDescription(
        workFolderRoot: URL,
        config: LLMConfig,
        customPrompt: String? = nil
    ) async throws -> String? {
        try await workFolderDescriptionService.generate(
            workFolderRoot: workFolderRoot,
            config: config,
            customPrompt: customPrompt
        )
    }

    func fetchAvailableSchemes(workFolderRoot: URL) async -> [String] {
        await XcodeBuildHelpers.fetchAvailableSchemes(workFolderRoot: workFolderRoot)
    }

    func updateSelectedScheme(_ scheme: String?, at url: URL) throws -> WorkFolderContext {
        try repository.updateSelectedScheme(at: url, scheme: scheme)
    }
}
