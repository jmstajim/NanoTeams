import SwiftUI

/// Main window, sidebar, and team-board panel layout constants.
enum WindowLayout {
    /// Default main window width
    static let mainDefaultWidth: CGFloat = 760
    /// Default main window height
    static let mainDefaultHeight: CGFloat = 700

    /// Minimum sidebar width
    static let sidebarMinWidth: CGFloat = 200
    /// Ideal sidebar width
    static let sidebarIdealWidth: CGFloat = 200
    /// Maximum sidebar width
    static let sidebarMaxWidth: CGFloat = 240

    /// Minimum width for the activity panel in HSplitView
    static let teamBoardActivityMinWidth: CGFloat = 200
    /// Minimum width for the graph panel in HSplitView
    static let teamBoardGraphMinWidth: CGFloat = 200
}
