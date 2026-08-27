import Foundation

/// One cached answer to "what agent skills exist for this root", with the moment
/// it was taken.
///
/// `rootPath` is the standardized work-folder path, or `""` for default storage
/// (where only the global roots and plugins contribute). It is part of the record
/// rather than implied by the file, because one install opens many folders and a
/// catalogue taken for folder A says nothing about folder B's project skills.
nonisolated struct AgentSkillsCatalogue: Codable, Hashable, Sendable {
    let rootPath: String
    /// When the walk behind this catalogue ran, quantized to the millisecond.
    ///
    /// Quantized at CONSTRUCTION, not on read: the persistence format is ISO 8601
    /// with fractional seconds, so a raw `Date()` survives the round trip only to
    /// three decimals. Left unquantized, the value a caller holds and the value on
    /// disk differ below that — and since this stamp is exactly how one tells "the
    /// catalogue was re-walked" from "it was reused", the two representations of one
    /// fact would disagree on the question the fact exists to answer (CLAUDE.md #91).
    let scannedAt: Date
    let items: [AgentSkillsSnapshot.Item]

    init(rootPath: String, scannedAt: Date, items: [AgentSkillsSnapshot.Item]) {
        self.rootPath = rootPath
        self.scannedAt = Date(timeIntervalSince1970:
            (scannedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        self.items = items
    }

    var snapshot: AgentSkillsSnapshot { AgentSkillsSnapshot(items: items) }
}

/// Disk cache for the agent-skill CATALOGUE — the answer to "what exists on this
/// machine", kept in Application Support and refreshed only when someone asks.
///
/// **Why a cache at all.** Discovery walks every skill root: the project, the home
/// conventions (`~/.claude/skills`, `~/.codex/prompts`, …) and every enabled Claude
/// Code plugin, probing 8 KB of each file it finds for frontmatter. Three surfaces
/// needed that answer and all three took it themselves — the composer's `/` picker
/// on every popover open, the Role editor's Skills tab on every appear, and every
/// single run start. The last one is what made it a latency bug: a submit spent the
/// walk before its first prompt, and on a default install nothing on that path even
/// reads the catalogue (no template ships `attachedSkillIDs`).
///
/// **Why Application Support and not the work folder.** Installed skills are a fact
/// about the MACHINE — most of them live under the home dir and have nothing to do
/// with which folder is open — and the catalogue must survive switching folders.
/// Same reasoning, and the same neighbourhood, as `BenchmarkHistoryStore`.
///
/// **Why no TTL.** A time-based refresh is a guess about when the user installs a
/// skill, and every guess is wrong in one of two directions: short enough to be
/// current is short enough to pay the walk on the interactive path (the 5-second
/// memo this replaced could never fire between two human sends), and long enough to
/// be cheap is long enough to be stale. Staleness here is *visible* — a skill you
/// just installed is missing from a list you are looking at — so the honest control
/// is the Refresh button beside that list, not a timer.
nonisolated final class AgentSkillsCatalogueStore: @unchecked Sendable {

    /// `~/Library/Application Support/NanoTeams/skills/`.
    ///
    /// Beside `.nanoteams/`, not inside it — `~/Library/Application Support/NanoTeams/`
    /// is itself the default WORK FOLDER, and filing a machine-scoped fact under one
    /// folder's tree is the coupling this store exists to avoid.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NanoTeams", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Shared instance for the surfaces that are deliberately orchestrator-free
    /// (`SkillsPickerButton` is a leaf taking only a root and a clips binding).
    /// Tests construct their own with an injected directory.
    static let shared = AgentSkillsCatalogueStore()

    /// How many roots keep a cached catalogue. A bound rather than unlimited growth:
    /// the file is read whole on every load, and a catalogue for a folder the user
    /// has not opened in a dozen switches is worth less than the bytes it costs.
    static let maxCachedRoots = 12

    let directory: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.nanoteams.skillscatalogue")

    var fileURL: URL { directory.appendingPathComponent("catalogue.json", isDirectory: false) }

    init(directory: URL = AgentSkillsCatalogueStore.defaultDirectory,
         fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// The key a root is filed under. Standardized so `/a/b` and `/a/b/` agree.
    static func key(for projectRoot: URL?) -> String {
        projectRoot?.standardizedFileURL.path ?? ""
    }

    // MARK: - Read

    /// The cached catalogue for this root, or `nil` when none was ever taken (or the
    /// file is unreadable — a corrupt cache is a cache miss, never an error the
    /// caller has to handle).
    func load(projectRoot: URL?) -> AgentSkillsCatalogue? {
        let wanted = Self.key(for: projectRoot)
        return queue.sync { readAll().first { $0.rootPath == wanted } }
    }

    // MARK: - Write

    /// Walks every skill root and replaces this root's cached catalogue.
    ///
    /// The ONLY place in the app that pays for discovery. Everything else loads.
    @discardableResult
    func rescan(projectRoot: URL?,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                now: Date = Date()) -> AgentSkillsCatalogue {
        let scanned = AgentSkillsScanner.scan(projectRoot: projectRoot,
                                              homeDirectory: homeDirectory,
                                              fileManager: fileManager)
        let entry = AgentSkillsCatalogue(rootPath: Self.key(for: projectRoot),
                                         scannedAt: now, items: scanned.items)
        queue.sync { write(entry) }
        return entry
    }

    /// The cached catalogue, taking one if there is none yet.
    ///
    /// This is what every consumer wants: a first launch scans once, and every call
    /// after that reads a file. A refresh is a separate, explicit verb.
    func loadOrScan(projectRoot: URL?,
                    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                    now: Date = Date()) -> AgentSkillsCatalogue {
        if let cached = load(projectRoot: projectRoot) { return cached }
        return rescan(projectRoot: projectRoot, homeDirectory: homeDirectory, now: now)
    }

    // MARK: - File

    private func readAll() -> [AgentSkillsCatalogue] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONCoderFactory.makeDateDecoder()
        guard let file = try? decoder.decode(CatalogueFile.self, from: data) else { return [] }
        return file.catalogues
    }

    /// Newest-first, this root's previous entry replaced, capped. Written atomically:
    /// a half-written cache would read as "no skills at all" on the next launch, which
    /// is indistinguishable from a machine with none.
    private func write(_ entry: AgentSkillsCatalogue) {
        var kept = readAll().filter { $0.rootPath != entry.rootPath }
        kept.insert(entry, at: 0)
        if kept.count > Self.maxCachedRoots {
            kept = Array(kept.sorted { $0.scannedAt > $1.scannedAt }.prefix(Self.maxCachedRoots))
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        guard let data = try? encoder.encode(CatalogueFile(catalogues: kept)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private struct CatalogueFile: Codable {
        var schemaVersion: Int = 1
        let catalogues: [AgentSkillsCatalogue]

        init(catalogues: [AgentSkillsCatalogue]) { self.catalogues = catalogues }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            self.catalogues = try container.decodeIfPresent([AgentSkillsCatalogue].self,
                                                            forKey: .catalogues) ?? []
        }
    }
}
