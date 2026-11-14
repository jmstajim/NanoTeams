import Foundation

/// The external creation window across relaunches (F6 L4): the ledger's committed stamps are
/// written on every commit and read back on every open (`ExternalCreationWindowStore`).
extension NTMSOrchestrator {

    /// Commits a creation slot — the one way a reservation becomes a creation — and, for an
    /// external agent's, writes the window it now stands at. A write that fails leaves the
    /// window exact in memory; only a relaunch before the next successful write forgets it.
    func commitCreation(_ reservation: AutovisorCreationLedger.Reservation, now: Date = MonotonicClock.shared.now()) {
        autovisorCreationLedger.commit(reservation, now: now)
        guard case .externalAgent = reservation.actor, let root = workFolderURL, hasRealWorkFolder else { return }
        try? creationWindowStore(workFolderRoot: root).save(autovisorCreationLedger.externalCreationStamps, now: now)
    }

    /// Reads the window a previous process left in the folder just opened into the ledger the
    /// transition emptied.
    func restoreExternalCreationWindow(workFolderRoot root: URL, now: Date = MonotonicClock.shared.now()) {
        autovisorCreationLedger.restoreExternalCreations(creationWindowStore(workFolderRoot: root).load(now: now))
    }

    /// The folder's store, keeping stamps as far back as its window reaches.
    private func creationWindowStore(workFolderRoot root: URL) -> ExternalCreationWindowStore {
        let window = snapshot?.workFolder.settings.autovisorTuning.externalCreationWindowMinutes
            ?? AutovisorConstants.externalCreationWindowMinutes
        return ExternalCreationWindowStore(
            url: NTMSPaths(workFolderRoot: root).externalCreationsJSON, fileManager: fileManager,
            retentionMinutes: ExternalCreationWindowStore.retentionMinutes(forWindow: window))
    }
}
