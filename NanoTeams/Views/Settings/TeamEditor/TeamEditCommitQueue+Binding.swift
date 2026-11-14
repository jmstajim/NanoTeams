import SwiftUI

// MARK: - Team Editor binding

extension TeamEditCommitQueue {

    /// The `Binding<Team>` every Team Editor surface edits through.
    ///
    /// Reads, in order: the value staged for the team, when there is one — so a second write in
    /// the same handler, or a keystroke while the previous one is still being written, starts from
    /// the edit before it; then the team as the folder stores it NOW — so a write that landed after
    /// `team` was rendered (this queue's, or one from beside it: an Autovisor sync, a Team Editor
    /// action) is the base of the next edit instead of being reverted by it; and `team` itself only
    /// once `lifecycle` has ended, so a binding that outlived a folder switch never reads the next
    /// folder's team of the same id. Writes by staging. `lifecycle` is the folder `team` was read
    /// in; a value staged under it is written nowhere else.
    func binding(for team: Team, editedIn lifecycle: WorkFolderLifecycle) -> Binding<Team> {
        let teamID = team.id
        return Binding(
            get: {
                self.draft(for: teamID, editedIn: lifecycle)
                    ?? self.folder?.storedTeam(teamID, editedIn: lifecycle)
                    ?? team
            },
            // A refusal is the folder having changed under a binding rendered before it: the
            // value belonged to a folder that is gone, and the editor is about to show the new one.
            set: { _ = self.stage($0, editedIn: lifecycle) }
        )
    }
}
