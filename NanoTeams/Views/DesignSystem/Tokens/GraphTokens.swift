import SwiftUI

/// Design tokens for team graph drawing (connections, labels, node dimensions).
nonisolated enum GraphTokens {
    /// Default line width for connections
    static let connectionLineWidth: CGFloat = 1.5
    /// Highlighted connection line width
    static let highlightedLineWidth: CGFloat = 2.5
    /// Arrow head length
    static let arrowLength: CGFloat = 8
    /// Highlighted arrow head length
    static let highlightedArrowLength: CGFloat = 10
    /// Label pill corner radius
    static let labelCornerRadius: CGFloat = CornerRadius.micro
    /// Label pill horizontal padding
    static let labelPaddingH: CGFloat = 4
    /// Label pill vertical padding
    static let labelPaddingV: CGFloat = 2
    /// Node approximate max width (for fit calculations)
    static let nodeMaxWidth: CGFloat = 130
    /// Node approximate height (for fit calculations)
    static let nodeHeight: CGFloat = 70
    /// Graph edge padding
    static let edgePadding: CGFloat = 20
    /// Fraction of node width used for distributing multiple connection ports (0.0-1.0)
    static let portSpreadFraction: CGFloat = 0.4
    /// Spacing between centered round dots on dashed connection strokes.
    /// Pairs with `StrokeStyle(dash: [0.01, dotSpacing], lineCap: .round)` so
    /// each "dash" collapses into a circular dot with diameter = lineWidth.
    static let dotSpacing: CGFloat = 6
}
