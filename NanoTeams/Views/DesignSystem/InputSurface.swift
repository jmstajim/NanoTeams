import AppKit
import SwiftUI

/// The one answer to "what does a text-entry surface look like" — tokens, metrics, and the two
/// appliers that use them.
///
/// Before this the tree carried TEN answers across ~63 render positions: two DS modifiers that
/// disagreed on padding by 4pt, an inline byte-for-byte copy of one of them that had already
/// drifted, four hand-rolled `surfaceElevated` fills with NO border, a search field with a fill
/// but no border on a same-coloured pane, and two AppKit representables — one filling the
/// CARD surface, one filling nothing at all and inheriting whatever host it landed in. Nine of
/// the ten were named by no test, so changing any of them turned nothing red and the class grew
/// instead of converging (CLAUDE.md #51).
///
/// TWO appliers, not one, because the render stacks genuinely differ and pretending otherwise
/// would be a lie: a SwiftUI input is chrome AROUND a view, while an `NSScrollView`-backed one has
/// to be painted by AppKit — CLAUDE.md #50 forbids `.clipShape`, an AppKit wrapper view and a
/// layer mask around the representable. What is single is the DECISION: both appliers read the
/// tokens below, and `Ratchet/InputSurfacePinTests` pins that no third applier appears.
///
/// **The border is not optional.** On `oledDark` all four surface levels are `#000000` and on
/// `daylightLight` `surfaceElevated == surfaceCard == #FFFFFF`, so on those palettes the fill
/// carries nothing and the hairline is the entire affordance. That is also why a flush position
/// (an input whose host is already `surfacePrimary` — QuickCapture, the Settings detail pane) is
/// the design's normal case rather than a defect.
nonisolated enum InputSurface {

    // MARK: - Tokens

    /// Deliberately not spelled `Colors.surfacePrimary` — see `Colors.inputSurfaceLevel` for why
    /// the level is written once and derived twice.
    static var fill: Color { Colors.surfaceInput }
    static var nsFill: NSColor { Colors.nsSurfaceInput }
    static var border: Color { Colors.borderSubtle }
    static let borderWidth: CGFloat = 1
    static var shape: RoundedRectangle { .squircle(CornerRadius.small) }

    // MARK: - Density

    /// The two shapes a text input takes. They differ in INSET and nothing else — never in fill,
    /// border, radius or stroke width.
    enum Density: Equatable {
        /// Multi-line editors. 4pt uniform, chosen to equal the AppKit editors' `textContainerInset`
        /// so a SwiftUI `TextEditor` and an `NSTextView` put the caret the same distance from the
        /// border. Six sites that used 8pt shrink by 4pt on each edge.
        case editor
        /// Single-line fields — the pre-existing `terminalField()` geometry, unchanged, so its 12
        /// call sites do not move.
        case field

        var horizontalInset: CGFloat {
            switch self {
            case .editor: Spacing.xs
            case .field: Spacing.s
            }
        }

        var verticalInset: CGFloat {
            switch self {
            case .editor: Spacing.xs
            case .field: Spacing.xs + 1
            }
        }

        /// Chrome floor. `.editor` has none — a multi-line editor's height is the caller's business.
        var chromeMinHeight: CGFloat? {
            switch self {
            case .editor: nil
            case .field: Spacing.l + Spacing.s
            }
        }

        /// AppKit counterpart of the SwiftUI insets, read by `stamp` so the two cannot drift.
        var nsTextInset: NSSize { NSSize(width: horizontalInset, height: verticalInset) }
    }

    // MARK: - AppKit applier

    /// Stamps the input surface onto an `NSScrollView` + `NSTextView` pair.
    ///
    /// **The fill goes on the SCROLL VIEW, not the text view, and that is geometry rather than
    /// preference.** Both editable representables build their text view with `minSize = .zero` and
    /// `autoresizingMask = [.width]`, while SwiftUI sizes the SCROLL view to
    /// `lineHeight * minLineCount + inset` (`minLineCount` is 3 for `AutovisorGoalComposer` and for
    /// `MessageComposer`'s editor init). An empty goal field is therefore a one-line document
    /// inside a three-line viewport, and a `textView.backgroundColor` fill would paint the top
    /// third and leave the rest showing the host. The scroll view paints its whole bounds
    /// regardless of document height, and also covers the strips that
    /// `verticalScrollElasticity = .allowed` exposes during rubber-band overscroll.
    ///
    /// Costs ZERO SwiftUI layers — that is why this seam was taken rather than a `.background` on
    /// the representable. Corners stay SQUARE: rounding would need `layer.cornerRadius +
    /// masksToBounds` (forbidden, pinned by `PromptTemplateEditorLagInvariantTests`) or
    /// `.clipShape` (forbidden by #50 — the one measured failure). The exposed wedge is
    /// `r(√2−1)` = 0.83pt at `CornerRadius.small`, tapering to zero at the tangents and less again
    /// for `.continuous`, against a neighbouring surface level whose worst per-channel contrast
    /// across all 22 palettes is 15/255 and whose best is 0.
    @MainActor
    static func stamp(scrollView: NSScrollView, textView: NSTextView, density: Density = .editor) {
        // `NSScrollView` and its `NSClipView` share ONE background — measured 2026-08-24 on
        // macOS 26, printing both flags after each mutation:
        //   contentView.drawsBackground = false  →  scrollView.drawsBackground becomes false
        //   scrollView.drawsBackground  = true   →  contentView.drawsBackground becomes true
        //   contentView.backgroundColor = X      →  scrollView.backgroundColor becomes X
        // So "the scroll view paints and the clip view does not" is not expressible, and the
        // long-standing `contentView.drawsBackground = false` in both editors was not disabling a
        // second painter — it was the ONLY way to turn the single background off.
        //
        // Which reframes the old hazard: the clip view painting was never the problem, painting
        // `NSColor.controlBackgroundColor` was. Set the colour first, then enable, and the clip
        // view fills the viewport with exactly the fill we want.
        scrollView.backgroundColor = nsFill
        scrollView.drawsBackground = true
        // The text view is then the second painter, and must not be one: its document is shorter
        // than the viewport whenever the field is under `minLineCount` lines.
        textView.drawsBackground = false
        textView.textColor = Colors.nsTextPrimary
        textView.insertionPointColor = Colors.nsTextPrimary
        textView.textContainerInset = density.nsTextInset
        textView.textContainer?.lineFragmentPadding = 0
    }
}

// MARK: - SwiftUI applier

/// Chrome for a text input.
///
/// `Leading` is the gutter glyph (`PromptMarker`) that five sites hand-rolled an `HStack` for, and
/// `Trailing` the magnifier / clear button that four search rows did. Folding both in is what lets
/// those sites apply the SAME modifier to the SAME content as every other site — which is in turn
/// what lets the pin stay construct-anchored instead of guessing at enclosing containers. A pin
/// that had to recognise "the chrome is on some ancestor HStack" is a pin that cannot say where an
/// input ends, and the ten answers this primitive replaced are what that costs.
struct InputSurfaceStyle<Leading: View, Trailing: View>: ViewModifier {
    let density: InputSurface.Density
    let minHeight: CGFloat?
    let alignment: Alignment
    let leading: Leading
    let trailing: Trailing

    func body(content: Content) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            leading
            content
                // A `TextEditor` otherwise paints the system list background over the fill. A no-op
                // on `TextField`/`SecureField`, so it lives here instead of at 15 call sites that
                // each had to remember it.
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight, alignment: alignment)
            trailing
        }
        .padding(.horizontal, density.horizontalInset)
        .padding(.vertical, density.verticalInset)
        .frame(minHeight: density.chromeMinHeight)
        .background(InputSurface.shape.fill(InputSurface.fill))
        .overlay(InputSurface.shape.strokeBorder(InputSurface.border, lineWidth: InputSurface.borderWidth))
    }
}

extension View {
    /// DS chrome for a text input. `minHeight` floors the CONTENT, so the drawn box is
    /// `minHeight + 2 * density.verticalInset`. Pair with `.textFieldStyle(.plain)` on a
    /// `TextField` so the native bezel is gone before this draws over it.
    func inputSurface(_ density: InputSurface.Density = .editor,
                      minHeight: CGFloat? = nil,
                      alignment: Alignment = .center) -> some View {
        modifier(InputSurfaceStyle(density: density, minHeight: minHeight, alignment: alignment,
                                   leading: EmptyView(), trailing: EmptyView()))
    }

    /// Same chrome, with a leading gutter glyph inside the border.
    func inputSurface<Leading: View>(_ density: InputSurface.Density = .editor,
                                     minHeight: CGFloat? = nil,
                                     alignment: Alignment = .center,
                                     @ViewBuilder leading: () -> Leading) -> some View {
        modifier(InputSurfaceStyle(density: density, minHeight: minHeight, alignment: alignment,
                                   leading: leading(), trailing: EmptyView()))
    }

    /// Same chrome, with accessories on both sides — the search-row shape (magnifier in front,
    /// clear button behind). Both labels are explicit so this cannot capture the trailing closure
    /// of the `leading:`-only spelling above.
    func inputSurface<Leading: View, Trailing: View>(_ density: InputSurface.Density = .editor,
                                                     minHeight: CGFloat? = nil,
                                                     alignment: Alignment = .center,
                                                     @ViewBuilder leading: () -> Leading,
                                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        modifier(InputSurfaceStyle(density: density, minHeight: minHeight, alignment: alignment,
                                   leading: leading(), trailing: trailing()))
    }

    /// Border ONLY — for the two `NSScrollView`-backed representables, whose fill is AppKit-drawn
    /// by `InputSurface.stamp`. Exists so their border cannot drift from the SwiftUI half's on
    /// radius, width or token.
    func inputSurfaceBorder() -> some View {
        overlay(InputSurface.shape.strokeBorder(InputSurface.border, lineWidth: InputSurface.borderWidth))
    }
}

// MARK: - Previews

/// RECESSED — the 30 positions whose host is `surfaceCard` or higher. This is the case the
/// "recessed well" language describes.
#Preview("Input surface — recessed on surfaceCard") {
    VStack(alignment: .leading, spacing: Spacing.m) {
        TextEditor(text: .constant("A multi-line editor."))
            .font(Typography.termBase)
            .inputSurface(.editor, minHeight: 60)
        TextEditor(text: .constant("With a gutter glyph."))
            .font(Typography.termBase)
            .inputSurface(.editor, minHeight: 60) { PromptMarker() }
        TextField("Single line", text: .constant(""))
            .textFieldStyle(.plain)
            .terminalField()
    }
    .padding(Spacing.standard)
    .frame(width: 380)
    .background(Colors.surfaceCard)
}

/// FLUSH — the 10 positions whose host is already `surfacePrimary` (QuickCapture, the Settings
/// detail pane). The fill contributes nothing and the hairline carries the input on its own. Seven
/// of these eight sites had no preview at all, which is part of why the class stayed invisible.
#Preview("Input surface — flush on surfacePrimary") {
    VStack(alignment: .leading, spacing: Spacing.m) {
        TextEditor(text: .constant("Flush against its host."))
            .font(Typography.termBase)
            .inputSurface(.editor, minHeight: 60)
        TextField("Single line", text: .constant(""))
            .textFieldStyle(.plain)
            .terminalField()
    }
    .padding(Spacing.standard)
    .frame(width: 380)
    .background(Colors.surfacePrimary)
}
