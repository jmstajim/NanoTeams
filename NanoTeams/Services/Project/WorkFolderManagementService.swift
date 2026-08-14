import Foundation

/// Service for work folder management and context updates.
@MainActor
final class WorkFolderManagementService {
    private let repository: any NTMSRepositoryProtocol
    private let workFolderContextService: WorkFolderContextService
    /// The `xcodebuild -list` invocation behind `fetchAvailableSchemes`.
    ///
    /// Defaulted to the live runner here — unlike every *parameter* carrying this
    /// protocol, which has no default. This is the service's own init, the one place
    /// production names its collaborators (same shape as `workFolderContextService`
    /// above), and the only construction site is `NTMSOrchestrator.init`. A value
    /// type with no state, so it is safe as a default argument: CLAUDE.md §49's
    /// "never default to an expression that constructs a class" is about `@MainActor`
    /// classes reviving the sync-test `abort()`.
    private let xcodebuildRunner: any XcodebuildRunning

    init(
        repository: any NTMSRepositoryProtocol,
        workFolderContextService: WorkFolderContextService = WorkFolderContextService(),
        xcodebuildRunner: any XcodebuildRunning = SystemXcodebuildRunner()
    ) {
        self.repository = repository
        self.workFolderContextService = workFolderContextService
        self.xcodebuildRunner = xcodebuildRunner
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
        await XcodeBuildHelpers.fetchAvailableSchemes(
            workFolderRoot: workFolderRoot, runner: xcodebuildRunner)
    }

    func updateSelectedScheme(_ scheme: String?, at url: URL) throws -> WorkFolderContext {
        try repository.updateSelectedScheme(at: url, scheme: scheme)
    }
    nonisolated deinit {}
}
