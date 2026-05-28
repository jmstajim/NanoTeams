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
