import AppKit
import SwiftUI

/// The review a tool must pass before it can reach any prompt.
///
/// Everything the server said, in full and unabridged — the description the model would read,
/// the parameters as a prompt-taught tool list renders them (a model calling tools natively is
/// sent them as a JSON schema, and the card's footer says so), the annotations — the server's
/// claims apart from the defaults it left in place — and the raw schema. Truncating any of it would make the approval
/// a decision about text the approver never saw, which is precisely the tool-poisoning route
/// the pinning exists to close. For the same reason nothing the server sent is shown hiding a
/// character: where the sheet prints the server's own text, each hidden one is spelled out
/// (`MCPToolReviewText`).
///
/// The buttons come from `MCPToolReviewChrome`, and each action is bound to the text this sheet
/// shows: when the server rewrites the tool while it is open, the connection refuses the action
/// and the sheet stays up saying so, rather than recording a decision about text nobody read.
/// From then on it offers Close alone — every write would be refused again.
struct MCPToolReviewSheet: View {

    let serverName: String
    let descriptor: MCPToolDescriptor
    let pinState: MCPPinState
    let isRejected: Bool
    /// The approval on record for this tool — what a rewrite is compared against.
    let approvedPin: MCPToolPin?
    /// The protocol revision the server's session speaks — `nil` when it is not connected. What
    /// the header parameters' line says rests on it (`MCPHeaderParamsNote`).
    let era: MCPProtocolEra?
    let onApprove: @MainActor () throws -> Void
    let onReject: @MainActor () throws -> Void
    /// Revokes the approval on record at the given hash — the approved tool's own, or for a
    /// rewrite the OLD text's (`MCPPinState.approvedHash(liveHash:)`).
    let onRevoke: @MainActor (_ approvedHash: String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var actionError: String?
    /// Set once the connection refused an action: the text on screen is no longer the one it
    /// holds, so the sheet stops offering writes.
    @State private var isStale = false
    @State private var isConfirmingRevoke = false

    private var chrome: MCPToolReviewChrome {
        MCPToolReviewChrome(pinState: pinState, isRejected: isRejected, isStale: isStale)
    }

    /// The line the Annotations card draws about the tool's header parameters, decided from the
    /// era the page handed the sheet (`MCPHeaderParamsNote`) — a value, so what the sheet draws is
    /// a test's to read (`MCPServerDetailView.reviewSheet`), and `body` only shows it. Until
    /// 2026-10-28 `body` worded it inline, and a note worded with no era survived every test.
    var headerNote: MCPHeaderParamsNote? {
        MCPHeaderParamsNote.of(descriptor.headerParams, era: era)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            TerminalDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    // Built once per render: the raw schema's escape is a pass over the frame.
                    let serverText = MCPToolReviewText(descriptor: descriptor)
                    if let actionError {
                        banner(
                            [actionError, chrome.staleNote].compactMap { $0 }.joined(separator: " "),
                            tint: Colors.errorTint, ink: Colors.error)
                    }
                    if chrome.showsRewriteBanner { rewriteBanner }
                    if isRejected { rejectedBanner }
                    if chrome.showsChanges { changesCard }
                    if let note = serverText.hiddenCharactersNote {
                        banner(note, tint: Colors.warningTint, ink: Colors.warning)
                    }
                    originCard(serverText)
                    descriptionCard
                    parametersCard(serverText)
                    annotationsCard
                    rawSchemaCard(serverText)
                }
                .padding(Spacing.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Colors.surfacePrimary)
        }
        .frame(minWidth: 680, minHeight: 560)
        .confirmationDialog(
            "Revoke approval of \(descriptor.modelFacingName)?",
            isPresented: $isConfirmingRevoke,
            titleVisibility: .visible
        ) {
            Button("Revoke approval", role: .destructive) { revoke() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(chrome.revokeConfirmation ?? "")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Spacing.m) {
            MonoLabel(text: "Review tool", marker: true)
            // Which tool, in the bar that holds the decision: the name the model would call.
            Text(descriptor.modelFacingName)
                .font(Typography.monoCaption)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(descriptor.modelFacingName)
            Spacer(minLength: Spacing.s)
            ForEach(chrome.actions) { action in
                Button(action.title) { press(action) }
                    .buttonStyle(buttonStyle(for: action.kind))
                    .keyboardShortcut(keyboardShortcut(for: action.shortcut))
            }
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.m)
    }

    private func press(_ action: MCPToolReviewChrome.Action) {
        guard !action.asksFirst else {
            isConfirmingRevoke = true
            return
        }
        switch action.kind {
        case .close: dismiss()
        case .revoke: revoke()
        case .reject: run(onReject)
        case .approve: run(onApprove)
        }
    }

    /// Revokes the approval this sheet shows — for a rewrite, the old text's.
    private func revoke() {
        guard let approvedHash = pinState.approvedHash(liveHash: descriptor.pinHash) else { return }
        run { try onRevoke(approvedHash) }
    }

    /// Closes on success. A refusal keeps the sheet open with the reason, so the person reads
    /// the tool again instead of believing a decision landed; a refusal from the connection
    /// also takes the writes away, since each would be refused again.
    private func run(_ work: @MainActor () throws -> Void) {
        do {
            try work()
            dismiss()
        } catch {
            actionError = MCPToolReviewChrome.failureMessage(for: error)
            if MCPToolReviewChrome.leavesSheetStale(after: error) { isStale = true }
        }
    }

    private func buttonStyle(for kind: MCPToolReviewChrome.Kind) -> TerminalButtonStyle {
        switch kind {
        case .approve: .terminalPrimary
        case .revoke: .terminalDanger
        case .close, .reject: .terminalSecondary
        }
    }

    private func keyboardShortcut(for shortcut: MCPToolReviewChrome.Shortcut?) -> KeyboardShortcut? {
        switch shortcut {
        case .cancel: .cancelAction
        case .primary: .defaultAction
        case nil: nil
        }
    }

    // MARK: - Banners

    private var rewriteBanner: some View {
        banner(
            "This tool was approved before and the server has since changed its text or its "
                + "schema. Read it again — an approved tool that quietly rewrites itself is the "
                + "one attack this review exists to catch.",
            tint: Colors.warningTint, ink: Colors.warning)
    }

    private var rejectedBanner: some View {
        banner(
            "You rejected this text. It reaches no prompt and stays out of bulk approval; "
                + "approving it here still works if you change your mind.",
            tint: Colors.neutralTint, ink: Colors.textTertiary)
    }

    private func banner(_ text: String, tint: Color, ink: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            StatusGlyph(glyph: TerminalGlyph.review, color: ink)
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(tint))
    }

    // MARK: - Cards

    /// The rewrite against the approved text, section by section.
    private var changesCard: some View {
        SettingsCard(
            header: "What changed since it was approved",
            footer: "Removed lines are marked −, added lines +. Compared against the text you approved."
        ) {
            switch approvedPin.map({ MCPToolChangeReview.between(approved: $0, live: descriptor) }) ?? .notRecorded {
            case .notRecorded:
                note("The previously approved text was not recorded.")
            case .changed(let sections) where sections.isEmpty:
                note(MCPToolReviewText.invisibleOnlyChangeNote)
            case .changed(let sections):
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(section.title)
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textSecondary)
                        Text(Self.rendered(section.lines))
                            .font(Typography.monoCaption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// One text for a whole section, each line marked and inked by what happened to it — one
    /// `Text`, so the comparison selects and copies as a block and repeated lines need no
    /// identity of their own.
    private static func rendered(_ lines: [LineDiff.Line]) -> AttributedString {
        var text = AttributedString()
        for (index, line) in lines.enumerated() {
            var run: AttributedString
            switch line.kind {
            case .unchanged:
                run = AttributedString("  " + line.text)
                run.foregroundColor = Colors.textTertiary
            case .removed:
                run = AttributedString("− " + line.text)
                run.foregroundColor = Colors.error
            case .added:
                run = AttributedString("+ " + line.text)
                run.foregroundColor = Colors.success
            }
            if index > 0 { text.append(AttributedString("\n")) }
            text.append(run)
        }
        return text
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Colors.textTertiary)
    }

    private func originCard(_ serverText: MCPToolReviewText) -> some View {
        SettingsCard(
            header: "Origin",
            footer: "Everything below is what the server said about itself. None of it is verified."
        ) {
            field("Server", serverName)
            field("Its name for the tool", serverText.originalName)
            field("Name the model sees", descriptor.modelFacingName)
            fingerprintField(serverText)
        }
    }

    /// Sixty-four hex characters do not fit beside the label, and wrapping them strands two
    /// characters on a line of their own. One line, cut where `MCPToolReviewText` says — in the
    /// middle, since the two ends are what a person compares — with the whole value in the
    /// tooltip, selectable, and one press away (the text's `fingerprintToCopy`).
    private func fingerprintField(_ serverText: MCPToolReviewText) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text("Fingerprint")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .frame(width: 160, alignment: .leading)
            Text(descriptor.pinHash)
                .font(Typography.monoCaption)
                .foregroundStyle(Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(MCPToolReviewText.fingerprintTruncation)
                .textSelection(.enabled)
                .help(descriptor.pinHash)
            Spacer(minLength: 0)
            SettingsPillButton(title: "Copy", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(serverText.fingerprintToCopy, forType: .string)
            }
            .help("Copy the whole fingerprint")
        }
    }

    private var descriptionCard: some View {
        SettingsCard(header: "Description the model reads") {
            Text(descriptor.displayDescription.isEmpty
                 ? "The server sent no description."
                 : descriptor.displayDescription)
                .font(Typography.monoCaption)
                .foregroundStyle(Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func parametersCard(_ serverText: MCPToolReviewText) -> some View {
        SettingsCard(header: "Arguments", footer: MCPToolReviewText.argumentsFooter) {
            Text(serverText.arguments)
                .font(Typography.monoCaption)
                .foregroundStyle(Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var annotationsCard: some View {
        SettingsCard(
            header: "Annotations",
            footer: "Claims, not facts. They can raise friction on a call and never lower it, "
                + "unless you mark the whole server trusted."
        ) {
            MCPAnnotationChipsView(chips: descriptor.annotations.chips)
            if let note = headerNote {
                field(note.title, note.value)
            }
        }
    }

    private func rawSchemaCard(_ serverText: MCPToolReviewText) -> some View {
        SettingsCard(header: "Raw schema") {
            Text(serverText.rawTool)
                .font(Typography.monoCaption)
                .foregroundStyle(Colors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .frame(width: 160, alignment: .leading)
            Text(value)
                .font(Typography.monoCaption)
                .foregroundStyle(Colors.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
