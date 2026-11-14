import Foundation

/// The moments each external agent's task creations were committed in one work folder, on disk
/// (`.nanoteams/internal/autovisor/external_creations.json`), so the sliding creation window
/// (`AutovisorTuning.maxExternalCreationsPerWindow` per `externalCreationWindowMinutes`) outlives
/// the process. It lived in `AutovisorCreationLedger` alone until 2026-11-12 (F6 L4): after a
/// relaunch `folder_status.limits.created_in_window` read 0 beside two creations a quarter of an
/// hour old, and the agent could create a full window again.
///
/// It records CREATIONS, not tasks: a task closed or deleted since still counts, which is what
/// the window means ("closing a task never refills it"). That is why it is not derived from the
/// task index, which forgets a deleted task.
///
/// Written only by the process holding the folder — the commit it follows is a creation the
/// folder's write gate let through — and read once per open.
nonisolated struct ExternalCreationWindowStore {

    /// The file's shape: one entry per agent, its commit moments oldest first.
    struct Contents: Codable, Equatable {
        var schemaVersion: Int = 1
        var creations: [String: [Date]]
    }

    let url: URL
    var fileManager: FileManager = .default
    /// How far back a stamp is kept: the longest window the settings offer, or the folder's own
    /// window when it was set longer by hand (`retentionMinutes(forWindow:)`).
    var retentionMinutes: Int = AutovisorConstants.maxExternalCreationWindowMinutes

    /// The retention for a folder whose window is `windowMinutes` long.
    static func retentionMinutes(forWindow windowMinutes: Int) -> Int {
        max(windowMinutes, AutovisorConstants.maxExternalCreationWindowMinutes)
    }

    /// The stamps worth keeping at `now`: within the retention and not in the future. A stamp
    /// past `now` is a clock that moved back since it was written; counting it would hold the
    /// window shut for as long as the clock is behind.
    static func kept(
        _ stamps: [UUID: [Date]], now: Date, retentionMinutes: Int = AutovisorConstants.maxExternalCreationWindowMinutes
    ) -> [UUID: [Date]] {
        let cutoff = now.addingTimeInterval(-TimeInterval(max(1, retentionMinutes) * 60))
        var kept: [UUID: [Date]] = [:]
        for (agentID, dates) in stamps {
            let inRange = dates.filter { $0 >= cutoff && $0 <= now }.sorted()
            if !inRange.isEmpty { kept[agentID] = inRange }
        }
        return kept
    }

    /// What the folder recorded, kept at `now`. A missing or unreadable file is an empty window —
    /// the one state a folder with no record of creations is in.
    func load(now: Date) -> [UUID: [Date]] {
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONCoderFactory.makeDateDecoder().decode(Contents.self, from: data)
        else { return [:] }
        var stamps: [UUID: [Date]] = [:]
        for (key, dates) in contents.creations {
            guard let agentID = UUID(uuidString: key) else { continue }
            stamps[agentID] = dates
        }
        return Self.kept(stamps, now: now, retentionMinutes: retentionMinutes)
    }

    /// Replaces the file with `stamps` kept at `now`, its directory owner-only like every
    /// internal one.
    func save(_ stamps: [UUID: [Date]], now: Date) throws {
        let kept = Self.kept(stamps, now: now, retentionMinutes: retentionMinutes)
        let contents = Contents(creations: Dictionary(uniqueKeysWithValues: kept.map { ($0.key.uuidString, $0.value) }))
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: NTMSRepository.internalDirAttributes)
        }
        try AtomicJSONStore(fileManager: fileManager).write(contents, to: url)
    }
}
