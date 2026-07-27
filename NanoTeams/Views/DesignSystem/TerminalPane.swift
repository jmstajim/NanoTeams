import SwiftUI

// MARK: - TerminalPane

/// A titled box-drawing pane — the design's primary container. A `surfaceCard`
/// fill + 1px hairline border, with the title "cut into" the top border in the
/// `┤ TITLE ├` convention. Without a title it's a plain bordered card.
struct TerminalPane<Content: View>: View {
    var title: String?
    /// Tint the cut-in title with the accent.
    var titleAccent: Bool = false
    /// A trailing control rendered on the title line (e.g. a Badge / count).
    var headerTrailing: AnyView?
    /// Fill — defaults to the card surface; pass `.clear` for a border-only frame.
    var fill: Color = Colors.surfaceCard
    var contentPadding: CGFloat = Spacing.m
    @ViewBuilder var content: () -> Content

    init(
        title: String? = nil,
        titleAccent: Bool = false,
        fill: Color = Colors.surfaceCard,
        contentPadding: CGFloat = Spacing.m,
        headerTrailing: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.titleAccent = titleAccent
        self.fill = fill
        self.contentPadding = contentPadding
        self.headerTrailing = headerTrailing
        self.content = content
    }

    var body: some View {
        content()
            .padding(contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle.squircle(CornerRadius.medium))
            .overlay(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if let title {
                    titleChip(title)
                        .padding(.leading, Spacing.m)
                        .offset(y: -6)
                }
            }
    }

    // Accessibility is applied per-element rather than by combining the chip:
    // `.accessibilityElement(children: .combine)` flattens descendants and DROPS
    // their actions, so an interactive `headerTrailing` (e.g. an `InfoTip`) would
    // be unreachable to VoiceOver and Full Keyboard Access. The label stays on the
    // title `Text` — dropping it would leave the UPPERCASED string as the spoken
    // label for every pane in the app.
    private func titleChip(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text("┤")
                .foregroundStyle(Colors.borderSubtle)
                .accessibilityHidden(true)
            HStack(spacing: Spacing.xs) {
                Text(title.uppercased())
                    .fontWeight(.medium)
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(titleAccent ? Colors.accent : Colors.textTertiary)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
                if let headerTrailing { headerTrailing }
            }
            Text("├")
                .foregroundStyle(Colors.borderSubtle)
                .accessibilityHidden(true)
        }
        .font(Typography.term2xs)
        // The page background behind the chip masks the border line, so the
        // title reads as cut into the top edge (panes sit on `surfacePrimary`).
        .padding(.horizontal, 4)
        .background(Colors.surfacePrimary)
    }
}

// MARK: - Dot-grid canvas background

/// The dot-grid graph canvas surface. Intentionally faint — depth comes from
/// the node borders, not the grid. Tune `dotColor` to taste; the design ships
/// it nearly invisible.
struct DotGridBackground: View {
    var spacing: CGFloat = 18
    var dotColor: Color = Colors.borderSubtle
    var dotRadius: CGFloat = 0.7

    var body: some View {
        Canvas { ctx, size in
            let d = dotRadius * 2
            var y: CGFloat = spacing
            while y < size.height {
                var x: CGFloat = spacing
                while x < size.width {
                    let rect = CGRect(x: x - dotRadius, y: y - dotRadius, width: d, height: d)
                    ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - TerminalDivider

/// A 1px hairline `borderSubtle` rule — the DS replacement for native `Divider()`.
/// The native control derives from `.tertiary` opacity, which produces a slightly
/// different hue than the rest of the terminal chrome; this primitive locks
/// every separator to the same token used for card outlines and rule labels
/// (`Colors.borderSubtle`), so panes, list rows and section separators read as
/// the same line.
///
/// Use inside view hierarchies (between rows, after sheet headers, etc.). Do NOT
/// use inside `Menu { ... }` blocks — native `Divider()` there is real menu
/// chrome and a `Rectangle` won't render as a menu separator.
struct TerminalDivider: View {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Colors.borderSubtle)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
            .accessibilityHidden(true)
    }
}

#Preview("TerminalPane") {
    VStack(spacing: Spacing.l) {
        TerminalPane(title: "Activity feed", headerTrailing: AnyView(
            Text("RUN #4").foregroundStyle(Colors.textTertiary)
        )) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("$ read_file Calculator.swift → ok").font(Typography.termSm)
                Text("engineer is working…").font(Typography.termSm).foregroundStyle(Colors.accent)
            }
        }
        TerminalPane(title: "Team", titleAccent: true) {
            Text("Engineering · 4 members").font(Typography.termBase)
        }
    }
    .padding(Spacing.xl)
    .frame(width: 420)
    .background(Colors.surfacePrimary)
}
