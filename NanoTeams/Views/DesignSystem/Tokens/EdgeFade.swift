import SwiftUI

/// Fixed-length fade at one edge of a scrolling view — the "there is more past this edge" hint.
///
/// The length is in POINTS, and that is the whole reason this type exists. A `LinearGradient`
/// mask can only speak in RELATIVE stops (0…1), so the two sites that wanted a fade wrote the
/// stop out by hand — `0.88` on the question preview, `0.92` on the chip row. A fraction is a
/// length only at the size it was authored at: 12 % of the question card is 24pt in an
/// unmeasured pane and 58pt — three and a half lines of `Typography.termBase` — in a tall one,
/// so the card swallowed the end of every long question on a large window while barely hinting
/// at all on a small one. The dependency runs backwards from what a hint wants.
///
/// `TeamActivityFeedView`'s timeline fade never had the bug because it was never written as a
/// fraction: it is a `LinearGradient` with `.frame(height: Spacing.l)`. This type gives the two
/// mask sites the same fixed-length guarantee, converting pt → stop against a frame length the
/// CALLER already knows. Deliberately no `GeometryReader` inside the mask: both sites have the
/// length in hand (a computed cap; a scroll container's width), and reading it back through
/// layout would add a measurement path whose degenerate values — `.infinity` on the first
/// frame, `.nan` from a speculative pass — are exactly what `fadeStart` has to defend against.
nonisolated enum EdgeFade {

    /// Which edge of the view fades out.
    enum Edge: Hashable {
        case top, bottom, leading, trailing

        /// Whether the fade runs along the vertical axis — picks height vs width when a caller
        /// reads the frame length it passes as `length:`.
        var isVertical: Bool { self == .top || self == .bottom }
    }

    // MARK: - Tokens

    /// Standard fade band — the same 20pt `TeamActivityFeedView` fades its timeline into the
    /// composer with. A fixed point length, never a fraction: not growing with the container
    /// IS the property being bought.
    static let standard: CGFloat = Spacing.l

    /// Tolerance for "the content overflows its container". A horizontally scrolling row can
    /// report a content width a fraction of a point past the container's on an exact fit, and
    /// a fade drawn there would dim the last chip while promising a scroll that does nothing.
    static let overflowSlack: CGFloat = 0.5

    // MARK: - Pure math

    /// Relative location (0…1) where the fade BEGINS, for a frame `length` pt long along the
    /// faded axis and a `fade` pt band measured back from the edge.
    ///
    /// Total by construction. Every degenerate input — non-finite, zero or negative, on either
    /// argument — returns 1, i.e. fully opaque and no visible fade, because the alternative is
    /// worse than useless: a `NaN` stop location makes `CGGradient` order its stops by a
    /// comparison that is false in both directions, and the undefined mask that comes back can
    /// be alpha 0 over the whole frame. In a mask that means the content silently DISAPPEARS,
    /// with no crash and no log. A band at least as long as the frame clamps to 0 (the whole
    /// frame fades) rather than going negative.
    static func fadeStart(length: CGFloat, fade: CGFloat) -> CGFloat {
        guard length.isFinite, length > 0 else { return 1 }
        guard fade.isFinite, fade > 0 else { return 1 }
        guard fade < length else { return 0 }
        return min(1, max(0, (length - fade) / length))
    }

    /// Mask stops: opaque up to `fadeStart`, transparent at the faded edge.
    ///
    /// `.black` / `.clear` are alpha values here, not colours — a mask reads only alpha, which
    /// is also why this needs no `…FadeClear` colour token the way an opaque overlay would.
    static func stops(length: CGFloat, fade: CGFloat) -> [Gradient.Stop] {
        [
            Gradient.Stop(color: .black, location: 0),
            Gradient.Stop(color: .black, location: fadeStart(length: length, fade: fade)),
            Gradient.Stop(color: .clear, location: 1),
        ]
    }

    /// Orientation such that gradient location 1 lands ON `edge`. One stop array serves all
    /// four edges — reversing the stops per edge would be a second place for the same
    /// arithmetic to be wrong.
    static func points(for edge: Edge) -> (start: UnitPoint, end: UnitPoint) {
        switch edge {
        case .bottom: return (start: .top, end: .bottom)
        case .top: return (start: .bottom, end: .top)
        case .trailing: return (start: .leading, end: .trailing)
        case .leading: return (start: .trailing, end: .leading)
        }
    }

    /// Whether a scrolling axis' content runs past its viewport — the gate for drawing the fade
    /// at all. Non-finite geometry reads as "not overflowing": no fade beats a fade that lies.
    static func isOverflowing(
        contentLength: CGFloat,
        containerLength: CGFloat,
        slack: CGFloat = overflowSlack
    ) -> Bool {
        guard contentLength.isFinite, containerLength.isFinite else { return false }
        return contentLength > containerLength + slack
    }

    /// One scrolling axis' measured geometry — the payload shape for `onScrollGeometryChange`,
    /// which needs a single `Equatable` value. Carries BOTH numbers because a fade needs both:
    /// the container length converts its pt band to a stop, the content length says whether to
    /// draw it at all. Seeded `.zero`, which reads as "not overflowing" until the first tick.
    struct AxisGeometry: Equatable {
        var container: CGFloat
        var content: CGFloat

        static let zero = AxisGeometry(container: 0, content: 0)

        var isOverflowing: Bool {
            EdgeFade.isOverflowing(contentLength: content, containerLength: container)
        }
    }
}

extension View {
    /// Fade the last `fade` POINTS before `edge`, against a frame `length` pt long on that axis.
    ///
    /// `.mask` is applied unconditionally and `isActive` switches only the mask's CONTENT. An
    /// `if isActive { mask } else { self }` in a `@ViewBuilder` would change the branch — and
    /// with it the structural identity of the masked subtree — every time overflow toggled,
    /// resetting the scroll offset inside it.
    ///
    /// A mask rather than the opaque `LinearGradient` overlay `TeamActivityFeedView` uses: an
    /// overlay has to be painted in the exact surface colour behind it (a `…FadeClear` token
    /// per surface — this modifier's two call sites sit on two different surfaces) and must opt
    /// out of hit testing or it eats the drag that selects text. A mask is correct over any
    /// ground. The cost is that masked-out pixels stop hit testing, so the band itself is not
    /// selectable — acceptable at 20pt, and strictly better than the band it replaces.
    func edgeFade(
        _ edge: EdgeFade.Edge,
        length: CGFloat,
        fade: CGFloat = EdgeFade.standard,
        isActive: Bool = true
    ) -> some View {
        let points = EdgeFade.points(for: edge)
        return mask {
            if isActive {
                LinearGradient(
                    stops: EdgeFade.stops(length: length, fade: fade),
                    startPoint: points.start,
                    endPoint: points.end
                )
            } else {
                Rectangle()
            }
        }
    }
}
