import Foundation

// MARK: - Bundled Update Report

/// What the version-bump reconcile could NOT apply, and why.
///
/// Owns both the short banner copy and the long durable copy so the two
/// surfaces cannot drift. The old shape was a bare `[NTMSID]`, which is why the
/// banner could only say "Bundled updates deferred for 2 teams — will retry on
/// next open": no team, no role, no reason, and the same neutral tone whether
/// one team was briefly busy or the whole folder was permanently blocked.
///
/// Two causes survive the reconcile hardening, and they need opposite handling:
///
///  * **Deferral** — a role holds a live tool loop. Transient by construction:
///    `NTMSRepository.pinsTeamAsBusy` only matches states `StatusRecoveryService`
///    parks, so the next open applies the update. Informational.
///  * **Scan failure** — a `task.json` can't be read. Nothing auto-recovers an
///    individual task file, so this blocks every team until the user acts. An
///    error, and the only case that earns a durable surface.
///
/// Modelled as one struct with an optional failure rather than a per-team reason
/// enum: a scan failure is folder-scoped, and repeating it on eight team rows
/// would read as eight independent problems.
nonisolated struct BundledUpdateReport: Hashable {

    /// One team whose bundled update was skipped this open.
    nonisolated struct DeferredTeam: Hashable, Identifiable {
        let teamID: NTMSID
        let teamName: String
        /// Every blocking role, deduped across blocking tasks. Never truncated —
        /// the copy decides what to show.
        let roleNames: [String]
        /// The first blocking task, used to name the thing the user must resolve.
        let taskID: Int
        let taskTitle: String
        /// Blocking tasks beyond `taskID`. Surfaced rather than dropped so the
        /// message can't imply resolving one task is enough.
        let otherBlockingTaskCount: Int

        var id: NTMSID { teamID }

        init(
            teamID: NTMSID,
            teamName: String,
            roleNames: [String],
            taskID: Int,
            taskTitle: String,
            otherBlockingTaskCount: Int = 0
        ) {
            self.teamID = teamID
            self.teamName = teamName
            self.roleNames = roleNames
            self.taskID = taskID
            self.taskTitle = taskTitle
            self.otherBlockingTaskCount = otherBlockingTaskCount
        }
    }

    /// The idle-role scan itself failed, so the pass fail-closed and changed
    /// nothing. Only an I/O failure lands here — an undecodable `task.json` is
    /// skipped instead, because a task that won't decode cannot be running.
    nonisolated enum ScanFailure: Hashable {
        case taskFileUnreadable(taskID: Int, relativePath: String, reason: String)

        var taskID: Int {
            switch self { case .taskFileUnreadable(let id, _, _): return id }
        }

        var relativePath: String {
            switch self { case .taskFileUnreadable(_, let path, _): return path }
        }

        var reason: String {
            switch self { case .taskFileUnreadable(_, _, let reason): return reason }
        }
    }

    var scanFailure: ScanFailure?
    var deferred: [DeferredTeam]

    init(scanFailure: ScanFailure? = nil, deferred: [DeferredTeam] = []) {
        self.scanFailure = scanFailure
        self.deferred = deferred
    }

    /// Everything bundled landed — nothing to tell the user.
    var isFullyApplied: Bool { scanFailure == nil && deferred.isEmpty }

    /// A scan failure blocks every team and needs user action; a deferral
    /// resolves itself on the next open.
    var bannerIsError: Bool { scanFailure != nil }

    // MARK: - Copy

    /// Names shown inline before the message switches to "and N more". Three
    /// keeps the two-line banner (`ErrorBannerView` uses `lineLimit(2)`) intact
    /// for typical team names.
    private static let inlineTeamNameLimit = 3

    /// Short, banner-sized. `nil` when there is nothing to report.
    var bannerMessage: String? {
        if let scanFailure {
            return "Prompt updates blocked — task #\(scanFailure.taskID)'s file can't be read, "
                + "so no team was updated. Repair or delete that task."
        }
        guard !deferred.isEmpty else { return nil }

        let tail = "Applies next time you open this folder."

        if deferred.count == 1, let team = deferred.first {
            let who = team.roleNames.first ?? "a role"
            // Several blocking tasks replace the task number rather than
            // appending to it: naming one would imply resolving it is enough,
            // and the appended form overflows the two-line banner.
            let blockingTaskCount = team.otherBlockingTaskCount + 1
            let where_ = blockingTaskCount == 1
                ? "task #\(team.taskID)"
                : "\(blockingTaskCount) tasks"
            return "\(team.teamName) kept its old prompts — \(who) is mid-run in \(where_). \(tail)"
        }

        let names = deferred.map(\.teamName)
        let shown = names.prefix(Self.inlineTeamNameLimit).joined(separator: ", ")
        // The overflow is stated, never silently dropped.
        let overflow = names.count > Self.inlineTeamNameLimit
            ? " and \(names.count - Self.inlineTeamNameLimit) more"
            : ""
        return "\(names.count) teams kept their old prompts: \(shown)\(overflow). \(tail)"
    }

    /// Long-form for the durable Work Folder settings row. Only the permanent
    /// case gets one — a deferral would be stale before the user could read it.
    var durableMessage: String? {
        guard let scanFailure else { return nil }
        return "Bundled prompt and tool updates are blocked for every team — "
            + "\(scanFailure.relativePath) can't be read (\(scanFailure.reason)). "
            + "NanoTeams can't confirm no role is mid-run, so it changes nothing. "
            + "Delete that task's folder or restore the file, then reopen this work folder."
    }
}
