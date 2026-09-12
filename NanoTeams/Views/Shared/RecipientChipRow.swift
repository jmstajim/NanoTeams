import SwiftUI

// MARK: - Recipient Chip

/// One pill in a `RecipientChipRow`.
///
/// A top-level type parameterised only by its id, not a member of the row's generic: the caller
/// builds these before it knows what accessory it will hang inside them, and
/// `RecipientChipRow<Recipient, ContextFillIndicator>.Chip` is not a thing anyone should have to
/// spell.
///
/// `nonisolated` so the mapping from a surface's own model to a row of chips — which is where
/// the ORDER and the dot come from, and therefore the only part of a chip row that can be wrong
/// — stays reachable from a test. `Views/` is outside the coverage denominator (CLAUDE.md
/// §View Conventions), so a rule that can only be reached through a `body` is a rule nobody
/// checks.
nonisolated struct RecipientChip<ID: Hashable>: Identifiable, Equatable {
    let id: ID
    let label: String
    /// SF Symbol. The asking role's own icon, or the shape of the action (a reply arrow, a
    /// retry loop) when the chip is not simply naming a role.
    let icon: String
    /// The colour the pill wears when selected. A role's tint, so the chip and the role's
    /// avatar in the feed agree about who is being addressed.
    let tint: Color
    /// This branch is holding an unsent reply nobody is currently editing — the dot.
    var hasUnsentDraft: Bool = false

    init(id: ID, label: String, icon: String, tint: Color, hasUnsentDraft: Bool = false) {
        self.id = id
        self.label = label
        self.icon = icon
        self.tint = tint
        self.hasUnsentDraft = hasUnsentDraft
    }
}

// MARK: - Recipient Chip Row

/// The horizontal row of pills that says who a composer is talking to.
///
/// Both answering surfaces render it. That is the point: the docked composer grew this row
/// (chips, hover, the trailing fade, the geometry probe behind it) while Quick Capture had no
/// switcher at all, so the panel showed whichever question `SupervisorQuestionInbox` listed
/// first and the rest were unreachable from it. Writing the row a second time inside the panel
/// would have produced a second set of answers to "which chip is selected", "what does the dot
/// mean", "when does the fade appear" — the shape `TerminalChoiceList` was extracted to stop
/// (five hand-rolled choice lists, three glyph vocabularies).
///
/// What the row does NOT own is which chips exist and which is selected: both are handed in.
/// The composer's row includes the roles it can queue a message to and the panel's does not,
/// and a component that decided that for them would have to know about both.
///
/// - Parameter accessory: rendered inside the pill, to the right of the label. The composer
///   hangs its `ContextFillIndicator` there — the fill belongs to the conversation the chip
///   addresses, so it rides the chip rather than sitting beside the row.
/// `ID: Sendable` because `ScrollPosition.scrollTo(id:)` and `.task(id:)` both carry the id
/// across an isolation boundary. Every id this row is built with is a value type of Strings
/// already, so the constraint costs nothing and states what was true anyway.
struct RecipientChipRow<ID: Hashable & Sendable, Accessory: View>: View {
    let chips: [RecipientChip<ID>]
    let selection: ID?
    /// Leading caption ("To"), or nil where the surface's own header already says it.
    var leadingLabel: String? = nil
    /// `SupervisorAnswerFocus.waitingBadge` — nil below two waiting questions.
    var badge: String? = nil
    let onSelect: (ID) -> Void
    @ViewBuilder let accessory: (RecipientChip<ID>) -> Accessory

    /// Owned here rather than by each surface. The composer used to keep this beside its own
    /// selection and sanitize it whenever the row changed; a hover that names a chip which is
    /// no longer in `chips` simply matches nothing, so the sanitize was upkeep for a state that
    /// cannot go wrong once it lives with the thing it describes.
    @State private var hovered: ID?
    /// Keeps the selected pill on screen. The panel re-hosts its `NSHostingView` on every
    /// rebuild — and a chip tap IS a rebuild — so a freshly-built row starts at the leading
    /// edge, which puts the chip the user just tapped off screen the moment the row overflows.
    /// The composer does not re-host, and gets the same courtesy for free when a submit moves
    /// the aim to a chip further right.
    @State private var scrollPosition = ScrollPosition()
    /// The scroll axis behind the trailing fade. Both numbers are needed: the container width
    /// converts the fade's pt band into a gradient stop, the content width says whether to draw
    /// it at all. `.zero` reads as "not overflowing" — no fade beats a fade promising a scroll
    /// that does nothing.
    @State private var geometry: EdgeFade.AxisGeometry = .zero

    var body: some View {
        if !chips.isEmpty {
            HStack(spacing: Spacing.xs) {
                if let leadingLabel {
                    MonoLabel(text: leadingLabel, size: .xs)
                        .padding(.trailing, Spacing.xxs)
                }
                if let badge {
                    // Outside the ScrollView: it is a summary of the whole row, so scrolling
                    // the row must not scroll away the count of what is in it.
                    TerminalStatusBadge(
                        glyph: TerminalGlyph.review, label: badge,
                        color: Colors.warning, bordered: false)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(chips) { chip in
                            pill(chip, isSelected: selection == chip.id)
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                    // Lock to intrinsic vertical extent — `HStack` can't wrap, but without
                    // `.fixedSize` it can be stretched by parent layout pressure when the chip
                    // count grows. Keeps the row strictly single-line.
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollTargetLayout()
                }
                .scrollPosition($scrollPosition)
                .onChange(of: selection) { _, current in
                    guard let current else { return }
                    scrollPosition.scrollTo(id: current, anchor: .center)
                }
                .task(id: selection) {
                    // `onChange` covers a live row; this covers the freshly-hosted one, where
                    // the selection did not change — the whole view did.
                    guard let selection else { return }
                    scrollPosition.scrollTo(id: selection, anchor: .center)
                }
                .onScrollGeometryChange(for: EdgeFade.AxisGeometry.self) { geo in
                    EdgeFade.AxisGeometry(
                        container: geo.containerSize.width,
                        content: geo.contentSize.width
                    )
                } action: { _, measured in
                    geometry = measured
                }
                .edgeFade(.trailing, length: geometry.container, isActive: geometry.isOverflowing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Pill

    private func pill(_ chip: RecipientChip<ID>, isSelected: Bool) -> some View {
        let isHovered = hovered == chip.id
        let fill: Color = isSelected
            ? chip.tint
            : (isHovered ? Colors.surfaceHover : Colors.surfaceElevated)

        // Two sibling zones in one pill: the name selects, the accessory does its own thing.
        // Not nested buttons — a `Button` inside a `Button`'s label has no defined hit
        // resolution on macOS.
        return HStack(spacing: 0) {
            Button {
                withAnimation(Animations.quick) { onSelect(chip.id) }
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: chip.icon)
                        .font(Typography.caption2.weight(.semibold))
                    Text(chip.label)
                        .font(Typography.termXs.weight(.semibold))
                        .lineLimit(1)
                    if chip.hasUnsentDraft {
                        // The dot says "your unfinished reply to this one is still here". Amber
                        // rather than the accent: the accent IS the selected pill's fill, and a
                        // mark wearing it would read as another kind of selection. On a
                        // selected pill it switches to the on-accent ink for the same reason a
                        // label does — the fill underneath it is the tint.
                        Text(TerminalGlyph.bullet)
                            .font(Typography.term2xs)
                            .foregroundStyle(isSelected ? Colors.textOnAccent : Colors.warning)
                    }
                }
                .foregroundStyle(isSelected ? Colors.textOnAccent : Colors.textPrimary)
                .padding(.horizontal, Spacing.s - 2)
                .padding(.vertical, Spacing.xs)
                // The fill spans both zones, so this zone needs a shape of its own or the
                // selection target collapses to the icon-and-text box (CLAUDE.md #12).
                // `IconButtonHitAreaPinTests` does not cover a composite label, so this is held
                // by the shape, not by a pin.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The dot's own `accessibilityLabel` would be swallowed: this `Button` overrides the
            // label of its whole subtree, so a child's label never reaches the element. The
            // state has to be spelled on the element that carries it.
            .accessibilityLabel(
                chip.hasUnsentDraft ? "\(chip.label), has an unsent reply" : chip.label)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            accessory(chip)
        }
        // ONE fill for the whole pill, both zones. An accessory draws no ground of its own —
        // it adapts its ink to this one.
        .background(fill)
        .clipShape(RoundedRectangle.squircle(CornerRadius.small))
        .overlay(
            RoundedRectangle.squircle(CornerRadius.small)
                .strokeBorder(isSelected ? Color.clear : Colors.borderSubtle, lineWidth: 0.5)
        )
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        .onHover { hovering in
            hovered = hovering ? chip.id : nil
        }
        .animationWithReduceMotion(Animations.quick, value: isSelected)
        .animationWithReduceMotion(Animations.quick, value: isHovered)
    }
}

extension RecipientChipRow where Accessory == EmptyView {
    /// A row with nothing hanging inside its pills — Quick Capture's.
    init(
        chips: [RecipientChip<ID>],
        selection: ID?,
        leadingLabel: String? = nil,
        badge: String? = nil,
        onSelect: @escaping (ID) -> Void
    ) {
        self.init(
            chips: chips, selection: selection, leadingLabel: leadingLabel, badge: badge,
            onSelect: onSelect, accessory: { _ in EmptyView() })
    }
}

#if DEBUG
#Preview("Recipient Chips") {
    @Previewable @State var selection: String? = "pm"

    return VStack(alignment: .leading, spacing: Spacing.l) {
        RecipientChipRow(
            chips: [
                RecipientChip(
                    id: "pm", label: "Answer Product Manager",
                    icon: "arrowshape.turn.up.left", tint: Colors.accent),
                RecipientChip(
                    id: "tl", label: "Answer Tech Lead", icon: "arrowshape.turn.up.left",
                    tint: Colors.purple, hasUnsentDraft: true),
                RecipientChip(id: "swe", label: "Software Engineer", icon: "hammer", tint: Colors.accent),
            ],
            selection: selection,
            leadingLabel: "To",
            badge: SupervisorAnswerFocus.waitingBadge(count: 2),
            onSelect: { selection = $0 })

        RecipientChipRow(
            chips: [RecipientChip(id: "solo", label: "Coding Assistant", icon: "chevron.left.forwardslash.chevron.right", tint: Colors.accent)],
            selection: "solo",
            onSelect: { _ in })
    }
    .padding(Spacing.l)
    .frame(width: 460)
    .background(Colors.surfaceCard)
}
#endif
