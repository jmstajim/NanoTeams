import SwiftUI

/// Main window, sidebar, and team-board panel layout constants.
nonisolated enum WindowLayout {
    /// Default main window width
    static let mainDefaultWidth: CGFloat = 760
    /// Default main window height
    static let mainDefaultHeight: CGFloat = 700

    /// Ideal sidebar width — matches the DS desktop kit (~280pt), gives task
    /// titles like "Complete NanoTeams Browser Design System..." room to read.
    static let sidebarIdealWidth: CGFloat = 280
    /// Minimum width for the activity panel in HSplitView
    static let teamBoardActivityMinWidth: CGFloat = 200
    /// Minimum width for the graph panel in HSplitView
    static let teamBoardGraphMinWidth: CGFloat = 200
}
