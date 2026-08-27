import SwiftUI

// MARK: - Team Editor Top Bar

/// Terminal-style sub-toolbar for the Team Editor, modelled on
/// `DesignSystemByClaude/ui_kits/desktop/TeamEditor.jsx` (lines 408–420):
///
///   ┌──────────────────────────────────────────────────────────────────────┐
///   │ ▌ TEAM EDITOR  <team picker>      <validation status>          ⋯     │
///   └──────────────────────────────────────────────────────────────────────┘
///
/// Replaces the native macOS `.toolbar` block on the Team Editor pane so the
/// chrome above the content is a single, fully-DS-aligned strip — no round
/// AppKit toolbar bezel. The right cluster is supplied by the parent via the
/// `actions` slot (currently the More menu) and styled flat via
/// `.buttonStyle(.navbarIcon)`.
struct TeamEditorTopBar<Picker: View, Actions: View>: View {
    let issues: [TeamEditorValidation.Issue]
    @ViewBuilder let picker: Picker
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            MonoLabel(text: "Team Editor", size: .xs, marker: true)
            picker
            Spacer(minLength: Spacing.m)
            validationStatus
            NavbarActionsCluster { actions }
        }
        .terminalTopBarChrome()
    }

    // MARK: - Validation status

    private var validationStatus: some View {
        let content = validationContent
        // Un-bordered — the validation badge stands alone (no adjacent outline
        // button), so it omits the hairline the run-state badge carries.
        return TerminalStatusBadge(glyph: content.glyph, label: content.label, color: content.color, bordered: false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Validation: \(content.label)")
    }

    /// `✓ graph valid` (success) / `▲ N issues` (warning) / `✗ N issues` (error)
    /// per JSX spec — matches `TeamEditor.jsx` lines 414–417.
    private var validationContent: (glyph: String, label: String, color: Color) {
        let errors = issues.count(where: \.isError)
        let warnings = issues.count - errors
        if errors > 0 {
            let n = issues.count
            return (TerminalGlyph.failed, "\(n) issue\(n == 1 ? "" : "s")", Colors.error)
        }
        if warnings > 0 {
            return (TerminalGlyph.review, "\(warnings) issue\(warnings == 1 ? "" : "s")", Colors.warning)
        }
        return (TerminalGlyph.done, "graph valid", Colors.success)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Team Editor Top Bar Variants") {
    VStack(spacing: 0) {
        TeamEditorTopBar(
            issues: []
        ) {
            Text("FAANG Team ⌄")
                .font(Typography.subheadlineMedium)
                .foregroundStyle(Colors.textPrimary)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xxs)
                .background(
                    RoundedRectangle.squircle(CornerRadius.micro)
                        .fill(Colors.surfaceElevated)
                )
        } actions: {
            Menu {
                Button("Import Team…") {}
                Button("Export Team…") {}
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .navbarIconCell()
        }

        TeamEditorTopBar(
            issues: [
                TeamEditorValidation.Issue(isError: false, message: "Whitelist contains an unknown team."),
            ]
        ) {
            Text("Engineering Team ⌄")
                .font(Typography.subheadlineMedium)
                .foregroundStyle(Colors.textPrimary)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xxs)
                .background(
                    RoundedRectangle.squircle(CornerRadius.micro)
                        .fill(Colors.surfaceElevated)
                )
        } actions: {
            Menu {
                Button("Import Team…") {}
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .navbarIconCell()
        }

        TeamEditorTopBar(
            issues: [
                TeamEditorValidation.Issue(isError: true, message: "Role 'Software Engineer' is missing a name."),
                TeamEditorValidation.Issue(isError: true, message: "Delegation cycle: A → B → A."),
            ]
        ) {
            Text("Custom Team ⌄")
                .font(Typography.subheadlineMedium)
                .foregroundStyle(Colors.textPrimary)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xxs)
                .background(
                    RoundedRectangle.squircle(CornerRadius.micro)
                        .fill(Colors.surfaceElevated)
                )
        } actions: {
            Menu {
                Button("Restore Defaults") {}
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .navbarIconCell()
        }
    }
    .frame(width: 800)
    .background(Colors.surfacePrimary)
}
#endif
