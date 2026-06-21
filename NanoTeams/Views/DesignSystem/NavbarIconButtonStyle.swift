import SwiftUI

// MARK: - Navbar Icon Button Style

/// Flat, mono, hover-only icon button — the canonical chrome for icon-only
/// affordances in the terminal-style in-view navbars (`TeamBoardTopBar`,
/// `TeamEditorTopBar`, etc.). No bezel at rest; the squircle `surfaceHover`
/// fill is the only visible chrome. Pairs naturally with
/// `.labelStyle(.iconOnly)` + `.menuStyle(.borderlessButton)` +
/// `.menuIndicator(.hidden)` at the env layer so a parent's
/// `Label("name", systemImage: "…")` constructions decay to bare SF Symbols.
///
/// 1:1 with `DesignSystemByClaude/components/core/IconButton.jsx`:
/// `.nt-iconbtn { background: transparent; color: var(--nt-text-2);
///   border-radius: var(--nt-radius-sm); }`
/// `.nt-iconbtn:hover { background: var(--nt-hover); color: var(--nt-text); }`
///
/// Square 28×28pt cell — matches the `.terminalSecondary` button's
/// `minHeight: Spacing.l + Spacing.s` (28pt) so the navbar's pause / resume
/// affordance and the action cluster sit on the same baseline. DS specifies
/// `control-h-sm = 24px`, `control-h = 30px` — 28pt slots between the two,
/// chosen to lock baseline alignment with the existing secondary button.
/// Width = height enforces the "terminal cell" rule.
struct NavbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .modifier(NavbarIconCellChrome(isHovered: isHovered))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .trackHover($isHovered)
        }
    }
}

// MARK: - Shared cell chrome

/// The terminal-cell chrome both `NavbarIconButtonStyle` (Button labels) and
/// `NavbarIconCellModifier` (Menu triggers) paint — 28×28pt cell, hover-only
/// `surfaceHover` fill, 1px hairline frame, content shape, hover animation.
/// Factored out so the two paths can never visually diverge; the owner supplies
/// the live `isHovered` and applies `.trackHover` (a binding can't cross into a
/// value-typed modifier) plus any pressed/disabled opacity.
///
/// The 1px hairline (vs the pure DS `border: 1px solid transparent` rest state)
/// keeps each icon reading as a terminal cell in line with the bracket button +
/// bordered badge in the same row, instead of "floating" next to that chrome.
private struct NavbarIconCellChrome: ViewModifier {
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .font(Typography.termBase)
            // DS color binding — `color: var(--nt-text-2)` at rest, brightens to
            // `var(--nt-text)` on hover (IconButton.jsx).
            .foregroundStyle(isHovered ? Colors.textPrimary : Colors.textSecondary)
            // 28pt cell = `Spacing.l + Spacing.s` — the `.terminalSecondary`
            // button's minHeight, so the navbar icon cells and the pause/resume
            // secondary button share one baseline and can't drift if the grid retunes.
            .frame(width: Spacing.l + Spacing.s, height: Spacing.l + Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(isHovered ? Colors.surfaceHover : .clear)
            )
            .overlay(
                RoundedRectangle.squircle(CornerRadius.small)
                    .strokeBorder(isHovered ? Colors.borderStrong : Colors.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle.squircle(CornerRadius.small))
            .animationWithReduceMotion(Animations.quick, value: isHovered)
    }
}

extension ButtonStyle where Self == NavbarIconButtonStyle {
    static var navbarIcon: NavbarIconButtonStyle { NavbarIconButtonStyle() }
}

// MARK: - Navbar Icon Cell Modifier

/// Applies the same chrome `NavbarIconButtonStyle` paints (28×28pt cell,
/// 1px hairline frame, hover surface fill) to ANY view — not just Button
/// labels. Needed for `Menu` triggers, which use their own private button
/// rendering and ignore the env-level `.buttonStyle(.navbarIcon)` so the
/// trigger would otherwise render as a bare glyph next to bordered icon
/// cells.
///
/// Usage:
/// ```swift
/// Menu { … } label: {
///     Label("More", systemImage: "ellipsis")
/// }
/// .menuStyle(.borderlessButton)
/// .menuIndicator(.hidden)
/// .labelStyle(.iconOnly)
/// .navbarIconCell()
/// ```
private struct NavbarIconCellModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .modifier(NavbarIconCellChrome(isHovered: isHovered))
            .trackHover($isHovered)
    }
}

extension View {
    /// Wraps the view in `NavbarIconButtonStyle`-equivalent chrome. Use on
    /// `Menu` labels where env-level `.buttonStyle(.navbarIcon)` doesn't
    /// reach.
    func navbarIconCell() -> some View {
        modifier(NavbarIconCellModifier())
    }
}

// MARK: - Navbar Actions Cluster

/// The shared right-side action cluster for the terminal in-view navbars
/// (`TeamBoardTopBar`, `TeamEditorTopBar`): tight `xxs` spacing + icon-only
/// flat-mono ghost styling applied at the env layer so a parent's
/// `Label("name", systemImage: "…")` / `Menu` actions decay to bare SF-Symbol
/// cells. Keeps the cluster chrome in ONE place so the two navbars can't drift.
struct NavbarActionsCluster<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            content
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.navbarIcon)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

// MARK: - Terminal Top Bar Chrome

extension View {
    /// The shared strip chrome for the terminal in-view navbars
    /// (`TeamBoardTopBar`, `TeamEditorTopBar`): `m`/`s` padding, full-width fill,
    /// `surfaceBackground`, and a 1px `borderSubtle` bottom hairline. Factored out
    /// so the bar height / border token live in ONE place and the two bars can't
    /// drift — a future third work-surface navbar applies this same modifier.
    func terminalTopBarChrome() -> some View {
        self
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(maxWidth: .infinity)
            .background(Colors.surfaceBackground)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Colors.borderSubtle).frame(height: 1)
            }
    }
}
