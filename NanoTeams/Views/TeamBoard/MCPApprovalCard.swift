import SwiftUI

// MARK: - MCP approval card list

/// The held MCP tool calls for `taskID`. Rendered at the activity-feed level, beside the bash
/// and computer-use cards, so the gate's in-loop await always has reachable buttons.
struct MCPApprovalCardList: View {
    let taskID: Int
    let roleDefinitions: [TeamRoleDefinition]

    @Environment(NTMSOrchestrator.self) private var store

    nonisolated static func sortedRequests(
        for taskID: Int, from all: [TaskStepKey: MCPApprovalRequest]
    ) -> [MCPApprovalRequest] {
        all.filter { $0.key.taskID == taskID }
            .map(\.value)
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ForEach(Self.sortedRequests(for: taskID, from: store.mcpApprovalRequests)) { request in
            MCPApprovalCard(
                taskID: taskID,
                request: request,
                roleName: roleDefinitions.first(where: { $0.id == request.stepID })?.name ?? request.stepID)
        }
    }
}

// MARK: - What the card says

/// The card's words and its one layout rule, as data a test can hold without a window.
nonisolated enum MCPApprovalCardText {

    /// The tallest the arguments box grows before it scrolls.
    static let argumentsMaxHeight: CGFloat = 220

    /// What the arguments box reads as before its text has been measured — unbounded, so the
    /// first frame is `argumentsHeight(measured:)` of it: the cap, never a zero-height box that
    /// jumps (rule #18). The card's `@State` starts from this value and nothing else. Until
    /// 2026-10-28 the guard was the view's own literal, and starting it at 0 passed every test.
    static let unmeasuredArgumentsHeight: CGFloat = .infinity

    /// The arguments box's height for text measured at `measured`: its own height, up to the
    /// cap. A `ScrollView` is greedy, and capped with `maxHeight` alone it took all 220 points
    /// for "{}" in the feed, where a flexible timeline sits above the card (rule #18, F34).
    /// Before the first measurement the text reads as `unmeasuredArgumentsHeight`, so the first
    /// frame is the cap — never a zero-height box that jumps.
    static func argumentsHeight(measured: CGFloat) -> CGFloat {
        min(measured, argumentsMaxHeight)
    }

    /// The standing grant's button. "Always allow" rather than "Always allow this tool": the
    /// longer label needs 234 points alone, wider than the 168 a card has in the 200-point
    /// column, so no arrangement of the row could keep it on one line; the short one needs 154.
    /// The card's headline names the tool, and the tooltip says what the grant covers
    /// (the same words the server page's tool row uses for the same grant).
    static let alwaysAllowLabel = "Always allow"
    static let alwaysAllowHelp = "Always allow this tool, at the text the server publishes now"

    /// The grant the card's button row offers: "Always allow", with what it covers as its
    /// tooltip — `nil` where the request offers none (Manual, a planning phase). The value the
    /// card builds its row from, so which words and which tooltip the grant carries are a
    /// test's to read.
    static func grant(offerAlways: Bool) -> ApprovalGrant? {
        offerAlways ? ApprovalGrant(label: alwaysAllowLabel, help: alwaysAllowHelp) : nil
    }

    /// The card's one line naming the call: who, which tool — by the server's own title for it,
    /// once — and where. The model-facing `mcp__…` name is the header's tooltip.
    static func headline(roleName: String, request: MCPApprovalRequest) -> String {
        "\(roleName) wants to call \(request.toolTitle) on \(request.serverDisplayName)"
    }
}

// MARK: - MCP approval card

/// One MCP call HELD awaiting a person's decision.
///
/// **The arguments ride whole, and that is the card's reason to exist.** Everything else here
/// describes the tool; this field is what is about to leave the machine, and the documented
/// exfiltration route for an external tool is an argument carrying more than the task needs.
/// Summarising it would make this a decision about a call the decider could not read.
///
/// The annotation chips are the SERVER's claims, shown as such — and the spec's defaults, where
/// it said nothing, shown as what the app assumes (`MCPAnnotationChipsView`, the review sheet's
/// own rendering): `read-only` here means the server described the tool that way, and the
/// arguments beside it are how a person weighs it.
private struct MCPApprovalCard: View {
    let taskID: Int
    let request: MCPApprovalRequest
    let roleName: String

    @Environment(NTMSOrchestrator.self) private var store
    /// The arguments text's own height, measured. Starts as the policy's unmeasured value, so
    /// the first frame draws the cap rather than a zero-height box (rule #18).
    @State private var argumentsHeight: CGFloat = MCPApprovalCardText.unmeasuredArgumentsHeight

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            header

            if !request.toolDescription.isEmpty {
                Text(request.toolDescription)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let transferNote = request.crossServerTransferNote {
                crossServerTransferWarning(transferNote)
            }

            argumentsBlock
            chips

            MCPApprovalAdviceView(
                taskID: taskID,
                stepID: request.stepID,
                callKey: request.callKey,
                grant: MCPApprovalCardText.grant(offerAlways: request.offerAlways),
                onAllow: { resolve(.allow) },
                onDeny: { resolve(.deny) },
                onAlways: { resolve(.alwaysAllow) })
                .id(request.createdAt)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceElevated))
    }

    /// The tool is named once, by the server's own title for it; the `mcp__…` name the model
    /// wrote is the tooltip. The chips row used to repeat it.
    private var header: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "server.rack")
                .accessibilityHidden(true)
            Text(MCPApprovalCardText.headline(roleName: roleName, request: request))
        }
        .font(Typography.caption.weight(.medium))
        .foregroundStyle(Colors.textSecondary)
        .help(request.toolName)
    }

    /// Never truncated, and scrollable rather than clipped: a long argument document is
    /// exactly the case worth reading closely. Shown through `argumentsDisplay`, so a hidden
    /// character reads as `\u{XXXX}` rather than as nothing — with a warning above it.
    ///
    /// Sized to its text up to the cap (`MCPApprovalCardText.argumentsHeight`): a `ScrollView`
    /// capped with `maxHeight` alone is greedy, and in the feed it drew "{}" in a 220-point box
    /// (F34). A call that sends nothing says so in words.
    @ViewBuilder
    private var argumentsBlock: some View {
        if request.hasNoArguments {
            Text("No arguments")
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
                .padding(Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle.squircle(CornerRadius.micro).fill(Colors.surfaceOverlay))
        } else {
            let shown = request.argumentsDisplay
            if shown.hadHidden { hiddenCharactersWarning }
            ScrollView {
                Text(shown.display)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Colors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { argumentsHeight = $0 }
            }
            .frame(height: MCPApprovalCardText.argumentsHeight(measured: argumentsHeight))
            .padding(Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle.squircle(CornerRadius.micro).fill(Colors.surfaceOverlay))
        }
    }

    private func crossServerTransferWarning(_ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            StatusGlyph(glyph: TerminalGlyph.review, color: Colors.warning)
            Text(note)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.micro).fill(Colors.warningTint))
    }

    private var hiddenCharactersWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            StatusGlyph(glyph: TerminalGlyph.review, color: Colors.warning)
            Text("These arguments contain invisible or direction-changing characters. "
                + "They are shown below as \\u{…} and will be sent as written.")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.micro).fill(Colors.warningTint))
    }

    /// The same reading the review sheet shows for the tool, and on a server the person has
    /// not marked trusted, a note that the claims are the server's own — drawn in the claims'
    /// own row, right after the last of them. Until 2026-10-28 it sat beside the whole block,
    /// mid-card or at its far right.
    private var chips: some View {
        MCPAnnotationChipsView(chips: request.annotationChips, claimNote: request.claimNote)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Async, unlike its two sibling gates: `.alwaysAllow` records the standing grant through
    /// the server's own connection BEFORE the call is released.
    private func resolve(_ choice: MCPApprovalChoice) {
        Task {
            await store.resolveMCPApproval(
                taskID: taskID, stepID: request.stepID, callKey: request.callKey, choice: choice)
        }
    }
}

// MARK: - On-demand "Ask AI" advice on held MCP calls

/// Action row + read-only "Ask AI" advisor for a held MCP tool call. Hosted with
/// `.id(request.createdAt)` so in-flight advice requests and verdicts are scoped to a single
/// held-call instance and cancelled when Allow / Deny / Always allow removes the card.
private struct MCPApprovalAdviceView: View {
    let taskID: Int
    let stepID: String
    let callKey: String
    let grant: ApprovalGrant?
    let onAllow: @MainActor () -> Void
    let onDeny: @MainActor () -> Void
    let onAlways: @MainActor () -> Void

    @Environment(NTMSOrchestrator.self) private var store
    @State private var verdict: MCPJudgeService.Decision? = nil
    @State private var adviceResolvedEmpty = false
    @State private var adviceTask: Task<Void, Never>? = nil

    private var isLoading: Bool { adviceTask != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ApprovalActionRow(
                grant: grant,
                onAllow: onAllow,
                onDeny: onDeny,
                onAlways: onAlways
            ) {
                askAIButton
            }

            if adviceResolvedEmpty {
                Text("Nothing to review — the call was already resolved.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let verdict {
                verdictRow(verdict)
            }
        }
        .onDisappear { cancelAdvice() }
    }

    private var askAIButton: some View {
        Button { toggle() } label: {
            HStack(spacing: Spacing.xxs) {
                if isLoading {
                    NTMSLoader(font: Typography.termXs, color: Colors.accent)
                } else {
                    Image(systemName: "sparkles").accessibilityHidden(true)
                }
                Text(isLoading ? "Stop" : "Ask AI")
            }
        }
        .buttonStyle(.terminalSecondary)
        .fixedSize()
        .layoutProbe("approval-action:Ask AI")
    }

    private func verdictRow(_ verdict: MCPJudgeService.Decision) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            StatusGlyph(
                glyph: verdict.allowed ? TerminalGlyph.done : TerminalGlyph.failed,
                color: verdict.allowed ? Colors.success : Colors.error)
            HStack(alignment: .top, spacing: Spacing.xxs) {
                Image(systemName: "sparkles")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.accent)
                    .accessibilityHidden(true)
                Text(verdict.reason)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle() {
        if isLoading {
            cancelAdvice()
            return
        }
        adviceTask = Task {
            let result = await store.requestMCPJudgeAdvice(
                taskID: taskID, stepID: stepID, callKey: callKey)
            if Task.isCancelled { return }
            if let result {
                verdict = result
                adviceResolvedEmpty = false
            } else {
                verdict = nil
                adviceResolvedEmpty = true
            }
            adviceTask = nil
        }
    }

    private func cancelAdvice() {
        adviceTask?.cancel()
        adviceTask = nil
    }
}
