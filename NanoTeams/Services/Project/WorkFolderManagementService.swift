import Foundation

/// Service for work folder management and context updates.
@MainActor
final class WorkFolderManagementService {
    private let repository: any NTMSRepositoryProtocol
    private let workFolderContextService: WorkFolderContextService

    init(
        repository: any NTMSRepositoryProtocol,
        workFolderContextService: WorkFolderContextService = WorkFolderContextService()
    ) {
        self.repository = repository
        self.workFolderContextService = workFolderContextService
    }

    func openOrCreateWorkFolder(at url: URL) throws -> WorkFolderContext {
        try repository.openOrCreateWorkFolder(at: url)
    }

    func updateWorkFolderContext(_ context: String, at url: URL) throws -> WorkFolderContext {
        try repository.updateWorkFolderContext(
            at: url,
            context: context.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func generateWorkFolderContext(
        workFolderRoot: URL,
        config: LLMConfig,
        customPrompt: String? = nil
    ) async throws -> String? {
        try await workFolderContextService.generate(
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
    nonisolated deinit {}
}
