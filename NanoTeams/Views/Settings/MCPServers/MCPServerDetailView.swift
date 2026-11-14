import SwiftUI

/// One server: where it stands, what it says about itself, and every tool it publishes.
///
/// The tool list is the review queue. A tool reaches no prompt until it is approved here, and
/// an approved tool the server later rewrites comes back to this list rather than staying
/// approved — which is why the row's badge is the load-bearing element, not decoration.
struct MCPServerDetailView: View {

    let row: MCPServerRow
    let connection: MCPServerConnection?
    /// A work folder is open, so "Allowed in this work folder" has a file to write — without
    /// one the row is not shown: every server is allowed, and the switch could only fail.
    let folderRuleAvailable: Bool
    var judgeConfig: StoreConfiguration? = nil
    let onEdit: @MainActor () -> Void
    let onDelete: @MainActor () -> Void
    /// The power switch: writes `isEnabled` and nothing else (`MCPServerManager.setServerEnabled`).
    /// Throws when the save is refused — the switch then shows what the disk holds, and the
    /// banner says why.
    let onSetEnabled: @MainActor (Bool) async throws -> Void
    /// Throws when the folder's file refuses the write, or no folder is open: the switch
    /// snaps back to what the disk holds, and the banner says why.
    let onSetEnabledHere: @MainActor (Bool) async throws -> Void

    @State private var reviewing: MCPToolDescriptor?
    /// The new tools a bulk approval would take, frozen when the pill was pressed — the
    /// confirmation names exactly these, and the connection approves exactly these or none.
    @State private var pendingBulkApproval: [MCPToolDescriptor]?
    @State private var actionFailure: ActionFailure?
    @State private var isRefreshing = false

    /// The last action on this page that failed, and which kind of action it was.
    ///
    /// A success clears only a failure of its OWN kind: a folder switch that saved says nothing
    /// about an approval the trust store refused a moment ago, and clearing that banner would
    /// leave the row showing a decision that was never recorded (review of group D, 2026-09-24).
    ///
    /// Every transition lives here and every action runs through `attempt`, so a call site
    /// names its kind once and passes nothing else — which banner a success clears and what a
    /// failure says are facts a test can hold, not lines of `body` no test can press.
    struct ActionFailure: Equatable {
        /// Nonisolated, so a switch row of the page's presentation can carry the one it attempts.
        nonisolated enum Action: Hashable, Sendable {
            /// A review decision: approve, reject, revoke, a bulk approval, Always allow.
            case review
            /// "Allowed in this work folder".
            case folderRule
            /// "Refresh tools".
            case refresh
            /// The power switch, "Connect to this server".
            case power

            /// What the banner says when this action threw.
            func message(for error: any Error) -> String {
                switch self {
                case .review:
                    MCPToolReviewChrome.failureMessage(for: error)
                case .folderRule, .power:
                    (error as? MCPServerEditError)?.message ?? MCPToolReviewChrome.failureMessage(for: error)
                case .refresh:
                    "The tool list could not be refreshed — the server did not answer."
                }
            }

            /// Whether an attempt clears this action's own failure BEFORE it runs, not only once
            /// it has succeeded. The two switches do: each shows what the disk holds, and a
            /// retry that failed the same way wrote a failure EQUAL to the one on screen — no
            /// state moved, SwiftUI skipped the redraw, and the switch could stay flipped over a
            /// rule that was never saved (review of group D, 2026-09-24). Cleared first, every
            /// attempt moves the state twice. A review or a refresh keeps its banner until it
            /// has an answer, so it does not flicker.
            var clearsBeforeRunning: Bool { self == .folderRule || self == .power }
        }

        let action: Action
        let message: String

        /// What the banner holds once `action` has succeeded.
        static func after(success action: Action, over current: ActionFailure?) -> ActionFailure? {
            current?.action == action ? nil : current
        }

        /// What the banner holds once `action` has thrown `error`.
        static func after(failure error: any Error, of action: Action) -> ActionFailure {
            ActionFailure(action: action, message: action.message(for: error))
        }

        /// Runs one attempt of `action` and moves `banner` through every state the page shows
        /// for it.
        static func attempt(
            _ action: Action, banner: Binding<ActionFailure?>, _ work: () async throws -> Void
        ) async {
            if action.clearsBeforeRunning {
                banner.wrappedValue = after(success: action, over: banner.wrappedValue)
            }
            do {
                try await work()
                banner.wrappedValue = after(success: action, over: banner.wrappedValue)
            } catch {
                banner.wrappedValue = after(failure: error, of: action)
            }
        }

        /// `attempt`, for an action that runs in place — a review decision a button or a switch
        /// makes without waiting.
        static func attemptInPlace(
            _ action: Action, banner: Binding<ActionFailure?>, _ work: () throws -> Void
        ) {
            do {
                try work()
                banner.wrappedValue = after(success: action, over: banner.wrappedValue)
            } catch {
                banner.wrappedValue = after(failure: error, of: action)
            }
        }
    }

    /// Every decision the page makes, from what it was handed — the row, the server's own
    /// connection, whether a folder is open — and whether a refresh is running. Not private, so a
    /// test holding the page `MCPServersSettingsView.detail(for:manager:)` built reads the same
    /// value the body draws: the "Not offered to roles" lines come from the connection here, and
    /// until 2026-10-28 that input was wired only inside `body`, where handing the presentation
    /// no rejections passed every test.
    func presentation(isRefreshing: Bool) -> MCPServerDetailPresentation {
        MCPServerDetailPresentation(
            row: row,
            hasConnection: connection != nil,
            serverInfoLabel: connection?.serverInfo.displayLabel,
            folderRuleAvailable: folderRuleAvailable,
            isRefreshing: isRefreshing,
            rejections: connection?.rejections ?? [])
    }

    /// The gutter between the pane's edge and every card on the page.
    static let pageGutter: CGFloat = Spacing.xl

    /// The page a server's cards sit in: one scroll view, the cards stacked inside the page's
    /// gutter. Static, so a layout test measures a card inside the page's own margins.
    static func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                content()
            }
            .padding(pageGutter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }

    var body: some View {
        // Built once per render: every decision below reads the same answer.
        let presentation = presentation(isRefreshing: isRefreshing)
        Self.page {
            MCPServerStatusCard(
                row: row,
                presentation: presentation,
                isRefreshing: isRefreshing,
                onFlip: { switchRow, on in Task { await flip(switchRow, to: on) } },
                onEdit: onEdit,
                onReconnect: { connection?.reconnectNow() },
                onRefresh: { Task { await refresh() } },
                onDelete: onDelete)
            if let actionFailure { errorBanner(actionFailure.message) }
            toolsCard(presentation)
            if let prompts = connection?.promptDescriptors, !prompts.isEmpty {
                promptsCard(prompts)
            }
            // Only where it applies: the judge decides calls of a server in Auto mode, and the
            // model it runs on is shared by every such server — the card's footer says so.
            if let judgeConfig, row.config.approvalMode == .auto {
                MCPAutoJudgeModelCard(config: judgeConfig)
            }
        }
        .sheet(item: $reviewing) { descriptor in
            Self.reviewSheet(for: descriptor, serverName: row.config.effectiveDisplayName, connection: connection)
        }
        .confirmationDialog(
            MCPBulkApprovalPrompt(tools: pendingBulkApproval ?? []).title,
            isPresented: Binding(
                get: { pendingBulkApproval != nil },
                set: { if !$0 { pendingBulkApproval = nil } }),
            titleVisibility: .visible,
            presenting: pendingBulkApproval
        ) { tools in
            Button(MCPBulkApprovalPrompt(tools: tools).confirmTitle) {
                perform { try reviewConnection().approveNewTools(tools) }
                pendingBulkApproval = nil
            }
            Button("Cancel", role: .cancel) { pendingBulkApproval = nil }
        } message: { tools in
            Text(MCPBulkApprovalPrompt(tools: tools).message)
        }
    }

    /// The connection a review action writes through. Gone means the server was switched off
    /// or removed while the sheet was open — refused, rather than a sheet that closes as if
    /// the decision had landed.
    private func reviewConnection() throws -> MCPServerConnection {
        try Self.reviewConnection(connection)
    }

    private static func reviewConnection(_ connection: MCPServerConnection?) throws -> MCPServerConnection {
        guard let connection else { throw MCPReviewError.withdrawn }
        return connection
    }

    /// The review sheet for `descriptor`, as the page opens it: every action carries the
    /// descriptor the sheet RENDERED, not a name — the connection refuses it when the server has
    /// rewritten the tool since — and the sheet is handed the protocol revision the server's
    /// session speaks, which the line about header parameters is worded from
    /// (`MCPHeaderParamsNote`). Static, so what the page hands the sheet is a test's to read.
    static func reviewSheet(
        for descriptor: MCPToolDescriptor, serverName: String, connection: MCPServerConnection?
    ) -> MCPToolReviewSheet {
        MCPToolReviewSheet(
            serverName: serverName,
            descriptor: descriptor,
            pinState: connection?.pinState(of: descriptor) ?? .new,
            isRejected: connection?.isRejected(descriptor) ?? false,
            approvedPin: connection?.pin(of: descriptor.originalName),
            era: connection?.status.connectedEra,
            onApprove: { try reviewConnection(connection).approve(reviewed: descriptor) },
            onReject: { try reviewConnection(connection).reject(reviewed: descriptor) },
            onRevoke: { approvedHash in
                try reviewConnection(connection).revoke(tool: descriptor.originalName, reviewedHash: approvedHash)
            })
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Colors.textTertiary)
    }

    // MARK: - Tools

    private func toolsCard(_ presentation: MCPServerDetailPresentation) -> some View {
        SettingsCard(
            header: "Tools",
            footer: "Approve a tool before it reaches a prompt. A tool the server rewrites comes back here for review."
        ) {
            let descriptors = connection?.descriptors ?? []
            if descriptors.isEmpty {
                caption(presentation.emptyToolsText)
            } else {
                // New tools only: a rewritten one is never approved in bulk — it goes through
                // its own sheet, with the comparison in front of it.
                let newTools = connection?.newTools ?? []
                if newTools.count > 1 {
                    HStack {
                        Spacer()
                        SettingsPillButton(
                            title: MCPBulkApprovalPrompt(tools: newTools).buttonTitle, icon: "checkmark.seal"
                        ) {
                            pendingBulkApproval = newTools
                        }
                    }
                }
                ForEach(MCPToolRowStatus.reviewOrdered(descriptors, status: rowStatus)) { descriptor in
                    toolRow(descriptor)
                }
            }
            // Below the empty line, which points down at it when nothing can be offered.
            if let error = connection?.catalogueError {
                Text(error)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.error)
            }
            if !presentation.rejectionLines.isEmpty {
                rejectionsBlock(presentation.rejectionLines)
            }
        }
    }

    private func promptsCard(_ prompts: [MCPPromptDescriptor]) -> some View {
        SettingsCard(
            header: "Prompts",
            footer: "An MCP prompt appears in the composer's / picker only after it is approved here."
        ) {
            ForEach(prompts) { prompt in
                toolRow(prompt.asReviewDescriptor(slug: row.config.slug))
            }
        }
    }

    private func rowStatus(_ descriptor: MCPToolDescriptor) -> MCPToolRowStatus {
        MCPToolRowStatus(
            pinState: connection?.pinState(of: descriptor) ?? .new,
            isRejected: connection?.isRejected(descriptor) ?? false)
    }

    private func toolRow(_ descriptor: MCPToolDescriptor) -> some View {
        let state = connection?.pinState(of: descriptor) ?? .new
        let status = rowStatus(descriptor)
        // Read here, in `body`, from the connection's OBSERVED trust record — so the chip
        // redraws when a grant lands, and nothing asks the store from inside a Binding.
        let alwaysAllowed = connection?.isAlwaysAllowed(tool: descriptor.originalName) ?? false
        return MCPServerToolRowLayout(
            badge: TerminalStatusBadge(glyph: status.glyph, label: status.label, color: status.color),
            name: Self.toolNameColumn(descriptor)
                .layoutProbe("tool-row-name:\(descriptor.modelFacingName)"),
            controls: MCPServerToolControls(
                isApproved: state.isApproved,
                offersAlwaysAllow: MCPToolRowStatus.offersAlwaysAllow(
                    pinState: state, approvalMode: row.config.approvalMode),
                alwaysAllowed: alwaysAllowed,
                onAlwaysAllow: { allowed in
                    Self.setAlwaysAllow(allowed, of: descriptor, through: connection, banner: $actionFailure)
                },
                onReview: { reviewing = descriptor }))
            .layoutProbe("tool-row:\(descriptor.modelFacingName)")
            .padding(.vertical, Spacing.xxs)
    }

    /// A tool row's "Always allow" switch flipped: the grant — or its withdrawal — is written
    /// through the server's connection, bound to the text the row shows, and a refusal puts the
    /// connection's OWN reason on the banner — the text moved, the mode allows none, the
    /// connection was stopped (`MCPServerConnection.setAlwaysAllow`). Static, so what the page
    /// does with the answer is a test's to hold.
    static func setAlwaysAllow(
        _ allowed: Bool, of descriptor: MCPToolDescriptor, through connection: MCPServerConnection?,
        banner: Binding<ActionFailure?>
    ) {
        ActionFailure.attemptInPlace(.review, banner: banner) {
            try reviewConnection(connection).setAlwaysAllow(
                tool: descriptor.originalName, allowed: allowed, expectedHash: descriptor.pinHash)
        }
    }

    /// The tool's model-facing name, and its summary on one line under it. The summary's ideal
    /// width is zero — it truncates to whatever the row leaves it — so it never decides whether
    /// the controls fit beside the name; the name does. Flexible, so on the one-line row it takes
    /// what the badge and the controls leave and pushes them to the edges. Static, so a layout
    /// test lays out the column the page draws.
    static func toolNameColumn(_ descriptor: MCPToolDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(descriptor.modelFacingName)
                .font(Typography.termBase)
                .foregroundStyle(Colors.textPrimary)
            Text(descriptor.summaryLine)
                .font(Typography.term2xs)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rejectionsBlock(_ lines: [MCPServerDetailPresentation.RejectionLine]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Not offered to roles")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            // Keyed by the refusal: the factory never reports two equal ones (`Outcome.rejections`),
            // while two can print alike.
            // Caption size, not micro: a line is a sentence — the name and why — and it wraps
            // (10pt type never wraps; at the default pane width these took two lines each).
            ForEach(lines) { line in
                caption(line.text)
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            StatusGlyph(glyph: TerminalGlyph.failed, color: Colors.error)
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.errorTint))
    }

    // MARK: - Actions

    /// Trust-store writes throw on a real disk failure, and a review action throws when the
    /// tool moved since it was shown. Swallowing either would leave the row showing a decision
    /// that was never recorded — the next run would withhold the tool and nothing would say why.
    private func perform(_ work: () throws -> Void) {
        ActionFailure.attemptInPlace(.review, banner: $actionFailure, work)
    }

    private func flip(_ switchRow: MCPServerDetailPresentation.SwitchRow, to on: Bool) async {
        await Self.flip(
            switchRow, to: on, banner: $actionFailure, setEnabled: onSetEnabled, setEnabledHere: onSetEnabledHere)
    }

    /// A switch row flipped: its own action is attempted — the words a failure puts on the
    /// banner and which banner a success clears are the row's (`SwitchRow.action`), and the
    /// write is the one its kind names: the power switch's `setEnabled`, the folder rule's
    /// `setEnabledHere`, never the other. Until the review of 2026-09-23 a refused folder-rule
    /// write was dropped (`try?`) and the switch simply snapped back, with nothing on screen to
    /// say it had not taken. Static, so which write a flip makes and which action its failure is
    /// filed under are a test's to hold: until 2026-10-28 both were decided inside the view, and
    /// the power switch writing the folder rule, or every flip filed as the
    /// folder rule's, passed every test.
    static func flip(
        _ switchRow: MCPServerDetailPresentation.SwitchRow,
        to on: Bool,
        banner: Binding<ActionFailure?>,
        setEnabled: @MainActor (Bool) async throws -> Void,
        setEnabledHere: @MainActor (Bool) async throws -> Void
    ) async {
        await ActionFailure.attempt(switchRow.action, banner: banner) {
            switch switchRow.kind {
            case .power: try await setEnabled(on)
            case .folderRule: try await setEnabledHere(on)
            }
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await ActionFailure.attempt(.refresh, banner: $actionFailure) { _ = try await connection?.refreshCatalogue() }
    }
}
