import SwiftUI

/// A tool's annotations as a person reads them — the server's claims as tags, a contradiction
/// the server made named, and what the app assumes where the server said nothing as a line in
/// words.
///
/// The ONE rendering of `MCPAnnotationChips`, shared by the review sheet and the approval card:
/// until 2026-09-24 each surface drew its own chips from its own source, and the two disagreed
/// about the same tool (F31, F54). Everything drawn here is decided by the value — which chips,
/// in which tone, whether the note has a row to sit in; this view only draws it.
struct MCPAnnotationChipsView: View {

    let chips: MCPAnnotationChips
    /// A note that qualifies the claims, drawn right after the last claimed chip — only where
    /// there is one (`MCPAnnotationChips.claimedRow(note:)`). The approval card passes "the
    /// server's own claim" on a server not marked trusted; the review sheet passes none, because
    /// its Annotations card says "Claims, not facts" under every tool.
    var claimNote: String?

    /// The gap between two chips on one line.
    static let chipSpacing: CGFloat = Spacing.xxs
    /// The gap between two lines of claimed chips.
    static let lineSpacing: CGFloat = Spacing.xxs

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            // Broken onto as many lines as the width needs: a tool stating all four hints false
            // draws about 410 points of fixed-size chips, and the chat column can be 200 wide.
            // Until 2026-10-28 this was one `HStack`, and the card grew past its column.
            if let row = chips.claimedRow(note: claimNote) {
                ClaimedChipsFlow(spacing: Self.chipSpacing, lineSpacing: Self.lineSpacing) {
                    ForEach(row.chips) { chip in
                        Self.badge(for: chip)
                            .layoutProbe("chip:\(chip.id)")
                    }
                    if let note = row.note {
                        Self.noteText(note)
                            .layoutProbe("chip-note")
                    }
                }
            }
            // A contradiction is the server's own doing, and wears the warning glyph.
            if let note = chips.contradictionNote {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    StatusGlyph(glyph: TerminalGlyph.review, color: Colors.warning)
                    Text(note)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                }
            }
            if let assumed = chips.assumedLine {
                Text(assumed)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
        }
    }

    /// The note after the last claimed chip. Static, so a layout test measures the note the row
    /// draws.
    static func noteText(_ note: String) -> some View {
        Text(note)
            .font(Typography.term2xs)
            .foregroundStyle(Colors.textTertiary)
            .lineLimit(1)
            .padding(.leading, Spacing.xxs)
    }

    /// A neutral claim is a tag; a claim naming a risk wears the warning glyph and ink, the
    /// way the contradiction note below does. Static, so a layout test measures the chips the
    /// row draws.
    @ViewBuilder
    static func badge(for chip: MCPAnnotationChips.Chip) -> some View {
        switch chip.tone {
        case .neutral:
            TerminalStatusBadge.tag(label: chip.label)
        case .caution:
            TerminalStatusBadge(glyph: TerminalGlyph.review, label: chip.label, color: Colors.warning)
        }
    }
}

// MARK: - The claimed row's layout

/// The claimed chips, and the note after the last of them, left to right on their first text
/// baseline — the `HStack` this replaced — broken onto a new line wherever the next one would
/// cross the width offered. Every item keeps its own size: a chip is fixed-size and never
/// narrowed, so its label never breaks inside it; only the note, which truncates, is ever
/// offered less than it asks for, and only when it does not fit on a line of its own. With no
/// width offered (an ideal size, `.fixedSize()`) everything is one line. Reports the width its
/// widest line USES, so a leading-aligned frame around it stays where it was.
private struct ClaimedChipsFlow: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    /// Where each subview goes, and at what size, for a width of `maxWidth`.
    private struct Arrangement {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var size: CGSize = .zero
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, within: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, within: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let origin = arrangement.origins[index]
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(arrangement.sizes[index]))
        }
    }

    /// One pass: each item at its ideal size (never wider than a line), placed after the one
    /// before it or at the start of a new line; each line is closed by aligning its items on the
    /// first text baseline, the way an `HStack(alignment: .firstTextBaseline)` does.
    private func arrange(_ subviews: Subviews, within maxWidth: CGFloat) -> Arrangement {
        var arrangement = Arrangement()
        var baselines: [CGFloat] = []
        var lineStart = 0
        var x: CGFloat = 0
        var lineTop: CGFloat = 0
        var widest: CGFloat = 0

        func closeLine(upTo end: Int) {
            guard lineStart < end else { return }
            let ascent = baselines[lineStart..<end].max() ?? 0
            var descent: CGFloat = 0
            for index in lineStart..<end {
                arrangement.origins[index].y = lineTop + ascent - baselines[index]
                descent = max(descent, arrangement.sizes[index].height - baselines[index])
            }
            lineTop += ascent + descent + lineSpacing
        }

        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified)
            let proposal = ProposedViewSize(width: min(ideal.width, maxWidth), height: nil)
            let size = subview.sizeThatFits(proposal)
            if x > 0, x + size.width > maxWidth {
                closeLine(upTo: index)
                lineStart = index
                x = 0
            }
            arrangement.origins.append(CGPoint(x: x, y: 0))
            arrangement.sizes.append(size)
            baselines.append(subview.dimensions(in: proposal)[VerticalAlignment.firstTextBaseline])
            widest = max(widest, x + size.width)
            x += size.width + spacing
        }
        closeLine(upTo: subviews.count)
        arrangement.size = CGSize(width: widest, height: subviews.isEmpty ? 0 : lineTop - lineSpacing)
        return arrangement
    }
}
