import AppKit
import CoreGraphics
import Foundation

/// Pure routing logic extracted from `QuickCaptureFormView` so the picker and
/// placeholder rules can be exercised without standing up a SwiftUI
/// environment.
///
/// Stateless — every method is a pure function of its inputs. Tested by
/// `QuickCaptureFormLogicTests`.
enum QuickCaptureFormLogic {

    /// Placeholder text for the message field, derived from the active team's
    /// mode. Chat-mode teams (no Supervisor deliverables) prompt the user to
    /// send a message; task-mode teams prompt for a task description. Nil
    /// (no team resolved yet) defaults to task framing.
    static func taskFieldPlaceholder(for team: Team?) -> String {
        if team?.isChatMode == true { return "Send a message..." }
        return "Describe your task..."
    }

    /// Mode label rendered next to the team picker ("chat" or "task"). The
    /// generated-team placeholder always shows "task" regardless of its
    /// `isChatMode` flag — the actual generated team determines real mode, and
    /// every generated team produces artifacts, so showing "chat" for the
    /// placeholder would mis-signal the post-generation behavior.
    static func teamModeLabel(for team: Team?) -> String {
        if team?.templateID == DelegationConstants.generatedTeamSentinel { return "task" }
        return team?.isChatMode == true ? "chat" : "task"
    }

    /// Teams offered in the in-picker list. Delegates to `[Team].selectableInPicker`.
    static func selectableTeams(from teams: [Team]) -> [Team] {
        teams.selectableInPicker
    }

    /// Resolves the team the picker header should display and the form should
    /// default to. Single source of truth for both the `selectedTeam` getter
    /// and the `onAppear` default in `QuickCaptureFormView`, so the two can
    /// never diverge.
    ///
    /// - An explicit `selectedTeamID` is honored against the **full** list, so
    ///   an in-progress "Generate Team…" pick (the hidden generated
    ///   placeholder) still shows in the header for the live session.
    /// - The `activeTeamID` and first-team **fallbacks** resolve against the
    ///   **selectable** set only. A default therefore can never silently land
    ///   on the generated placeholder (which the picker menu doesn't offer),
    ///   and a stale / removed `activeTeamID` falls through to the first
    ///   selectable team instead of being honored verbatim.
    ///
    /// Returns `nil` only when no explicit id matches and no team is selectable.
    static func resolveSelectedTeam(
        selectedTeamID: NTMSID?,
        activeTeamID: NTMSID?,
        availableTeams: [Team]
    ) -> Team? {
        if let id = selectedTeamID, let team = availableTeams.first(where: { $0.id == id }) {
            return team
        }
        let selectable = selectableTeams(from: availableTeams)
        if let id = activeTeamID, let team = selectable.first(where: { $0.id == id }) {
            return team
        }
        return selectable.first
    }

    /// The `selectedTeamID` the form should hold after routing the user to
    /// Settings → Teams to create a new team. `nil` means "release the pin".
    ///
    /// Why release it at all: `handleCreateTeam` makes the new team the work-folder
    /// active team, but `resolveSelectedTeam` above honors an explicit `selectedTeamID`
    /// against the FULL list BEFORE it ever consults `activeTeamID` — and by the time
    /// this menu is reachable `selectedTeamID` is non-nil. Left pinned, the user creates
    /// a team and returns to a picker still showing the old one, which defeats the entry.
    /// Releasing costs nothing on cancel: every ordinary row pick in this menu also
    /// writes `activeTeamID`, so the re-resolve lands back on the same team.
    ///
    /// The generated placeholder is EXEMPT: `selectGeneratedTeamTemplate` writes only
    /// `formState.selectedTeamID` and deliberately does NOT call `setActiveTeam`, so that
    /// pick exists nowhere else. Clearing it would silently drop an in-flight
    /// "Generate Team…" choice and drop the user back on the ordinary active team with
    /// no signal.
    ///
    /// A `current` that resolves to no team (stale / removed) also releases —
    /// re-resolving beats honoring an id that points at nothing.
    static func teamSelectionAfterNewTeamNavigation(
        current: NTMSID?,
        availableTeams: [Team]
    ) -> NTMSID? {
        guard
            let current,
            let team = availableTeams.first(where: { $0.id == current }),
            team.templateID == DelegationConstants.generatedTeamSentinel
        else { return nil }
        return current
    }

    /// Accept/reject decision for an `onGeometryChange` `measuredFormHeight`
    /// update. Returns the new value to store, or `nil` to ignore the callback.
    ///
    /// Rejects `.nan` / `.infinity` / negatives (SwiftUI emits these during
    /// speculative layout — propagating them into `.frame(height:)` would
    /// collapse the field or trigger a layout assertion). After the first
    /// measurement (current > 0), also rejects sub-2pt jitter to absorb
    /// auto-layout micro-oscillations without churning the cap downstream.
    static func acceptedMeasuredHeight(current: CGFloat, incoming: CGFloat) -> CGFloat? {
        guard incoming.isFinite, incoming >= 0 else { return nil }
        if current == 0 || abs(incoming - current) >= 2 {
            return incoming
        }
        return nil
    }

    /// Pixel cap for the QuickCapture message field, derived from the panel's
    /// measured height. Seeded from `QuickCapturePanel.panelMinSize` for any
    /// non-finite or non-positive input (`onGeometryChange` can emit `.nan` /
    /// `.infinity` during speculative layout passes — either would propagate
    /// into `.frame(height:)` and collapse the field or trigger a SwiftUI
    /// layout assertion).
    static func taskFieldMaxHeight(measuredFormHeight: CGFloat) -> CGFloat {
        let panelHeight: CGFloat = (measuredFormHeight.isFinite && measuredFormHeight > 0)
            ? measuredFormHeight
            : QuickCapturePanel.panelMinSize.height
        let halfPanel = panelHeight * 0.5
        return max(
            MessageComposerLayout.minPaneAnchoredFieldHeight,
            halfPanel - MessageComposerLayout.paneAnchoredFieldChrome
        )
    }
}
