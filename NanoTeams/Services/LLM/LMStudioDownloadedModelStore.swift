import Foundation

/// Downloaded-model management for LM Studio — filesystem, not HTTP.
///
/// LM Studio has NO delete surface at any layer: its REST route table carries
/// `models`, `models/load`, `models/unload`, `models/download` and
/// `models/download/status` and nothing else; the `lms` CLI has no `rm`; the
/// JS/Python SDKs expose memory-only lifecycle. Deletion exists solely inside
/// its GUI. So the only way an app can free that disk space is to move the
/// model's directory to the Trash itself.
///
/// Two consequences shape this type:
/// - **Local only.** There is no protocol to ask a remote LM Studio to delete
///   anything, so `deletionCapability` reports `.unavailable` for a non-loopback
///   endpoint instead of quietly trashing files on the wrong machine.
/// - **Server-independent.** Listing and deleting read the disk, so they work
///   with LM Studio closed — which is the common case when someone is trying to
///   reclaim space.
///
/// Deletion is `trashItem`, never `removeItem`: a 20 GB re-download is an
/// expensive mistake to make irreversible.
nonisolated struct LMStudioDownloadedModelStore: DownloadedModelStore {

    /// `FileManager` isn't `Sendable`, but this reference is set once at init
    /// and only ever read — the same effectively-immutable shape the codebase
    /// already marks this way (`JSONCoderFactory`'s formatters,
    /// `NTMSRepository.internalDirAttributes`). The methods used here (directory
    /// enumeration, `fileExists`, `trashItem`) are documented thread-safe.
    nonisolated(unsafe) private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    }

    // MARK: - Listing

    func listDownloaded(config: LLMConfig) async throws -> [DownloadedModel] {
        // A remote LM Studio's downloads are on another machine — listing this
        // machine's folder there would be an outright lie, not a degraded view.
        guard LMStudioModelsFolder.isLocalEndpoint(baseURLString: config.baseURLString) else {
            return []
        }
        guard let root = LMStudioModelsFolder.resolveRoot(home: homeDirectory, fileManager: fileManager) else {
            return []
        }
        return scan(root: root)
    }

    /// Walks exactly `<root>/<publisher>/<repoDir>`. Each `repoDir` is one
    /// downloadable unit — for GGUF that directory can hold several
    /// quantizations, which the model picker shows as separate models but which
    /// share one folder and are therefore deleted together. Presenting the
    /// FOLDER (and saying how many quantizations it holds) is the only framing
    /// that matches what deletion actually does.
    private func scan(root: URL) -> [DownloadedModel] {
        var models: [DownloadedModel] = []

        for publisherURL in childDirectories(of: root) {
            let publisher = publisherURL.lastPathComponent
            for repoURL in childDirectories(of: publisherURL) {
                let repoDir = repoURL.lastPathComponent
                // Listed ⇒ deletable, by construction: the row is only offered
                // if the SAME predicate `delete` will apply accepts it. Without
                // this, a symlink pointing outside the models root would list
                // normally (with the target's size) and then fail on Remove —
                // a dead row that looks like a bug rather than a policy.
                guard LMStudioModelsFolder.resolveModelDirectory(
                    id: "\(publisher)/\(repoDir)", root: root) != nil
                else { continue }

                let quantizationCount = ggufCount(in: repoURL)
                models.append(
                    DownloadedModel(
                        id: "\(publisher)/\(repoDir)",
                        displayName: "\(publisher)/\(repoDir)",
                        sizeBytes: directorySize(of: repoURL),
                        detail: quantizationCount > 1 ? "\(quantizationCount) quantizations" : nil,
                        // Residency needs the running server, which this store
                        // deliberately doesn't require. The orchestrator
                        // overlays it when it can (`downloadedModels(config:)`).
                        isLoaded: false,
                        referenceHints: LMStudioModelsFolder.referenceHints(
                            publisher: publisher, repoDir: repoDir)
                    )
                )
            }
        }

        return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func childDirectories(of url: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.filter { entry in
            (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    /// How many QUANTIZATIONS the folder holds — which is not the same as how many `.gguf` files
    /// are in it.
    ///
    /// A multimodal GGUF repo ships its vision projector as a second `.gguf` beside the weights
    /// (observed on disk: `Qwythos-9B-…-Q4_K_M.gguf` next to `mmproj-Qwythos-9B-…-F16.gguf`), and
    /// counting it made the card announce "2 quantizations" for a model that has one. The
    /// projector is a companion to the SAME quantization, not an alternative to it, and the number
    /// on that row is the user's only clue about what Remove takes away.
    ///
    /// Matched on the `mmproj-` prefix, which is the naming convention llama.cpp emits and both
    /// LM Studio and the GGUF repackagers preserve. A projector that ever failed to match would
    /// only restore today's over-count, never hide a real quantization.
    private func ggufCount(in url: URL) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        return entries.filter {
            $0.pathExtension.lowercased() == "gguf"
                && !$0.lastPathComponent.lowercased().hasPrefix("mmproj-")
        }.count
    }

    /// Recursive size. Prefers allocated size (what the volume actually spends)
    /// and falls back to logical size; a file whose size can't be read
    /// contributes nothing rather than aborting the whole measurement.
    private func directorySize(of url: URL) -> Int64? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return nil }

        var total: Int64 = 0
        for case let entry as URL in enumerator {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
            let bytes = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            total += Int64(bytes)
        }
        return total
    }

    // MARK: - Deletion

    func deletionCapability(config: LLMConfig) async -> DownloadedModelDeletion {
        guard LMStudioModelsFolder.isLocalEndpoint(baseURLString: config.baseURLString) else {
            return .unavailable(
                reason: "LM Studio has no delete API, so models can only be removed from the machine "
                    + "running it. This server isn't local — manage its downloads in LM Studio's My Models."
            )
        }
        guard LMStudioModelsFolder.resolveRoot(home: homeDirectory, fileManager: fileManager) != nil else {
            return .unavailable(
                reason: "Couldn't find LM Studio's models folder. Check the Models Directory in LM Studio's settings."
            )
        }
        return .movesToTrash
    }

    func delete(modelID: String, config: LLMConfig) async throws {
        guard LMStudioModelsFolder.isLocalEndpoint(baseURLString: config.baseURLString) else {
            throw LMStudioModelDeletionError.remoteServer
        }
        guard let root = LMStudioModelsFolder.resolveRoot(home: homeDirectory, fileManager: fileManager) else {
            throw LMStudioModelDeletionError.modelsFolderNotFound
        }
        guard let directory = LMStudioModelsFolder.resolveModelDirectory(id: modelID, root: root) else {
            throw LMStudioModelDeletionError.invalidModelID(modelID)
        }
        // Already gone is the outcome the caller wanted — idempotent, matching
        // the Ollama store's 404 rule.
        guard fileManager.fileExists(atPath: directory.path) else { return }

        do {
            try fileManager.trashItem(at: directory, resultingItemURL: nil)
        } catch {
            // Deliberately NOT falling back to `removeItem`. Trashing can fail
            // on volumes without a Trash, and silently upgrading a reversible
            // action into a permanent one is exactly the surprise this feature
            // must not spring on someone deleting a 20 GB download.
            throw LMStudioModelDeletionError.trashFailed(underlying: error)
        }
    }

    func storageLocationDescription(config: LLMConfig) async -> String? {
        guard LMStudioModelsFolder.isLocalEndpoint(baseURLString: config.baseURLString),
              let root = LMStudioModelsFolder.resolveRoot(home: homeDirectory, fileManager: fileManager)
        else { return nil }
        return root.path
    }
}

// MARK: - Errors

nonisolated enum LMStudioModelDeletionError: LocalizedError, Equatable {
    case remoteServer
    case modelsFolderNotFound
    case invalidModelID(String)
    case trashFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .remoteServer:
            "LM Studio models can only be removed on the machine running LM Studio."
        case .modelsFolderNotFound:
            "Couldn't find LM Studio's models folder."
        case .invalidModelID(let id):
            "\"\(id)\" doesn't name a model folder inside LM Studio's models directory."
        case .trashFailed(let underlying):
            "Couldn't move the model to the Trash: \(underlying.localizedDescription)"
        }
    }

    static func == (lhs: LMStudioModelDeletionError, rhs: LMStudioModelDeletionError) -> Bool {
        switch (lhs, rhs) {
        case (.remoteServer, .remoteServer),
             (.modelsFolderNotFound, .modelsFolderNotFound):
            true
        case (.invalidModelID(let l), .invalidModelID(let r)):
            l == r
        case (.trashFailed, .trashFailed):
            true
        default:
            false
        }
    }
}
