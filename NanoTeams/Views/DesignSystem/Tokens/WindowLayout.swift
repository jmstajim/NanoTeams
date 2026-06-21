import SwiftUI

/// Main window, sidebar, and team-board panel layout constants.
enum WindowLayout {
    /// Default main window width
    static let mainDefaultWidth: CGFloat = 760
    /// Default main window height
    static let mainDefaultHeight: CGFloat = 700

    /// Minimum sidebar width — narrow enough to fit on small windows, wide
    /// enough that the terminal header (`nanoteams ● ONLINE`) and the `01 02 …`
    /// task gutter both fit without truncation.
    static let sidebarMinWidth: CGFloat = 240
    /// Ideal sidebar width — matches the DS desktop kit (~280pt), gives task
    /// titles like "Complete NanoTeams Browser Design System..." room to read.
    static let sidebarIdealWidth: CGFloat = 280
    /// Maximum sidebar width — room for long folder/task names without crowding
    /// the detail pane.
    static let sidebarMaxWidth: CGFloat = 360

    /// Minimum width for the activity panel in HSplitView
    static let teamBoardActivityMinWidth: CGFloat = 200
    /// Minimum width for the graph panel in HSplitView
    static let teamBoardGraphMinWidth: CGFloat = 200
}
