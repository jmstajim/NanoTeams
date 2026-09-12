import SwiftUI

/// `[ Ask as form ]` — the secondary action beside a plain supervisor question.
///
/// Hosted by all three surfaces that render an active question — the docked composer, the
/// Watchtower banner, and the Quick Capture answer panel — so the wording and the affordance
/// cannot drift apart between them. Where each host PUTS it follows that host's own shape: the
/// composer has a row that names the question ("<Role> asks:") and the button belongs on it;
/// the other two have no such row and keep it directly under the question text.
///
/// Text, not a glyph: `TerminalButtonStyle` wraps the label in `[ … ]` itself, and a symbol
/// inside the brackets breaks the TUI idiom the design language is built on. The style also
/// owns the font, padding, min height, corner, hover fill and press state — the neighbouring
/// `[ Other… ]` in the questionnaire card carries the note about what hand-rolling those costs
/// — so nothing here restates any of them, the SIZE included: `.compact` is a value the style
/// defines, not a font and a padding re-decided here.
struct QuestionnaireRequestButton: View {

    /// Sends the directive. Hosts differ in how they snapshot and restore their own fields
    /// around it, which is why the call, not the button, belongs to them.
    let action: () -> Void

    /// One spelling for every surface.
    static let label = "Ask as form"

    var body: some View {
        Button(Self.label, action: action)
            .buttonStyle(.terminalGhostCompact)
            .help("Ask this role to break the question into a form with options to pick from")
            .accessibilityLabel("Ask this question as a form")
    }
}
