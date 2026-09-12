import SwiftUI

/// 8-point grid spacing tokens.
nonisolated enum Spacing {
    /// Extra-extra small spacing - 2pt (for compact graph nodes only)
    static let xxs: CGFloat = 2
    /// Extra small spacing - 4pt
    static let xs: CGFloat = 4
    /// Between xs and s - 6pt (design `--nt-space-3`).
    ///
    /// The half-step the design's own scale has always carried and this file did not, so the two
    /// sites that wanted it wrote `Spacing.xs + 2` — an arithmetic spelling that reads as "4, plus
    /// a nudge" rather than as a token, and that no rename or rescale would ever follow.
    static let xsPlus: CGFloat = 6
    /// Small spacing - 8pt
    static let s: CGFloat = 8
    /// Medium spacing - 12pt
    static let m: CGFloat = 12
    /// Standard spacing - 16pt
    static let standard: CGFloat = 16
    /// Large spacing - 20pt
    static let l: CGFloat = 20
    /// Extra large spacing - 24pt
    static let xl: CGFloat = 24
}
