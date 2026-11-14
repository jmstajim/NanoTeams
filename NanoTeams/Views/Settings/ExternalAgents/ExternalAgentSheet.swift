import SwiftUI

/// The token moment of Settings → External Agents: adding an agent, or reissuing a token, and the
/// one-time hand-over that follows — in one sheet, because a secret shown once is a modal fact.
/// The same sheet shows an existing agent's connection facts again (`Stage.connection`), without
/// the token.
///
/// Until 2026-11-08 the page held it inline: a field and an Add button at the top of the Agents
/// card, a warning-tinted block under them with the token, and the client's snippet in a card
/// further down — so connecting an agent meant assembling two copies from two cards. Until
/// 2026-11-09 the form began with a client picker, and the hand-over gave each agent a
/// configuration in its client's format; now every agent gets the same thing — its token written
/// to its file for the bridge, the token to copy once for a client that sends it in a header,
/// and the connection facts with its id filled in (`ExternalAgentsConnectionFacts`) — and the
/// client's format is the person's or their assistant's business.
///
/// **This sheet is the one place a client is connected from** (2026-11-12). The Settings page
/// held the same facts and the same prompt in two cards of its own, for nobody — `<agent-id>`
/// where the id goes — and they went. What they carried is here in the order a person uses it
/// (`BlockPart`): the simple way first — hand an assistant the setup prompt — then the token,
/// then the facts for setting a client up by hand, folded, under their two routes. A reissue
/// hands over the token alone.
///
/// It is presented by the Settings WINDOW (`SettingsView`), not by the External Agents tab: a
/// button in the main window can retarget the tab while the sheet is up
/// (`SettingsNavigation.open(tab:)`), and a sheet owned by the tab goes down with it, token and
/// all. `ExternalAgentSheetHost` is its store-facing half.
///
/// Four stages. `add` is the form: a name. `reissue` is the confirmation a rotation needs (the
/// old token stops working the moment it runs). `issued` is the hand-over, reached from either,
/// one block per agent. `connection` is the facts for an agent already on the list. Done closes
/// the hand-over at once unless a token is on the sheet and nowhere else — its file could not be
/// written — and was not copied; then it asks first.
struct ExternalAgentSheet: View {
    typealias IssuedAgentTokenItem = ExternalAgentsSettingsView.IssuedAgentTokenItem
    typealias Facts = ExternalAgentsConnectionFacts

    /// A reissue waiting for its confirmation: the old token stops working the moment it runs,
    /// so a connected agent is cut off until its client has the new one.
    enum ReissueTarget {
        case one(ExternalAgentRow)
        case all

        var title: String {
            switch self {
            case .one(let row): "Reissue the token for “\(row.label)”?"
            case .all: "Reissue every agent token?"
            }
        }

        var message: String {
            switch self {
            case .one:
                "The current token stops working at once. A client that runs the bridge picks the new one up at its next start; one that sends the token in a header stays disconnected until it has the new one."
            case .all:
                "Every current token stops working at once. Clients that run the bridge pick the new ones up at their next start; those that send the token in a header stay disconnected until they have theirs."
            }
        }
    }

    /// Where the sheet opens — what the page presents it with (`.sheet(item:)`).
    enum Entry: Identifiable {
        case add
        case reissue(ReissueTarget)
        case connection(ExternalAgentRow)

        var id: String {
            switch self {
            case .add: "add"
            case .reissue(.one(let row)): row.id.uuidString
            case .reissue(.all): "reissue-all"
            case .connection(let row): "connection-\(row.id.uuidString)"
            }
        }

        var initialStage: Stage {
            switch self {
            case .add: .add
            case .reissue(let target): .reissue(target)
            case .connection(let row): .connection(row)
            }
        }
    }

    enum Stage {
        case add
        case reissue(ReissueTarget)
        /// `isReissue`: the clients are configured already — a reissue says what picks the new
        /// token up, where a first issue says what to set up.
        case issued([IssuedAgentTokenItem], isReissue: Bool)
        /// An agent already on the list: its facts again, with its id filled in, and no token.
        case connection(ExternalAgentRow)
    }

    /// The three actions that produce a token, each returning what it issued for the hand-over.
    /// Reissuing every token does not throw: it reports the agents it left out beside the
    /// tokens it issued (`HostedMCPBulkRotation`).
    struct TokenIssuers {
        var addAgent: @MainActor (String) throws -> [IssuedAgentTokenItem]
        var rotateToken: @MainActor (UUID) throws -> [IssuedAgentTokenItem]
        var rotateAllTokens: @MainActor () -> IssueResult

        /// Every issuer a no-op returning nothing: for a preview, and for a test of the drawing.
        static let inert = TokenIssuers(
            addAgent: { _ in [] }, rotateToken: { _ in [] }, rotateAllTokens: { IssueResult(tokens: [], note: nil) })
    }

    /// What an issuing action produced: the tokens, and a line about what it could not do.
    struct IssueResult {
        let tokens: [IssuedAgentTokenItem]
        let note: String?

        /// A bulk reissue, said as the sheet says it: the agents left out by name, and that
        /// their current tokens still work — a rotation that fails changes nothing.
        init(bulk: HostedMCPBulkRotation) {
            tokens = bulk.issued.map(IssuedAgentTokenItem.init)
            switch bulk.failures.count {
            case 0:
                note = bulk.issued.isEmpty ? "There are no agents to reissue." : nil
            case 1:
                let failure = bulk.failures[0]
                note = "Not reissued: “\(failure.label)” (\(failure.message)). Its current token still works."
            default:
                let names = bulk.failures.map { "“\($0.label)” (\($0.message))" }.joined(separator: ", ")
                note = "Not reissued: \(names). Their current tokens still work."
            }
        }

        init(tokens: [IssuedAgentTokenItem], note: String?) {
            self.tokens = tokens
            self.note = note
        }
    }

    /// Where an issuing action leaves the sheet, and the line it shows. A throw stays on the
    /// stage it came from, with everything typed still in place; tokens move to the hand-over,
    /// carrying any note about agents left out; nothing issued at all stays, and says so.
    static func afterIssuing(
        _ result: Result<IssueResult, Error>, at stage: Stage, isReissue: Bool
    ) -> (stage: Stage, message: String?) {
        switch result {
        case .failure(let error):
            return (stage, error.localizedDescription)
        case .success(let issued) where issued.tokens.isEmpty:
            return (stage, issued.note ?? "No token was issued.")
        case .success(let issued):
            return (.issued(issued.tokens, isReissue: isReissue), issued.note)
        }
    }

    /// One agent's block in the hand-over, from its facts alone.
    struct HandoffBlock: Identifiable {
        let item: IssuedAgentTokenItem
        /// Where the token went and what is left to do.
        let line: String
        /// The connection facts with this agent's id in them. Empty where its token file could
        /// not be written: the bridge arguments would name a file that is not there.
        let fields: [Facts.Field]
        /// Writing the token file failed: the line is an error, and the token on the sheet is the
        /// only copy.
        let isFailure: Bool

        var id: UUID { item.id }

        /// The token is on the sheet and nowhere else, so it must be copied before the sheet
        /// closes. A token in its file can be read by the bridge, or reissued.
        var mustBeCopied: Bool { isFailure }

        /// The setup prompt is offered for this agent. Not where writing its token file failed:
        /// there is nothing to set up until the token is reissued, and the prompt would send an
        /// assistant to a file that is not there.
        var offersSetupPrompt: Bool { !isFailure }
    }

    /// What an agent's block is made of, top to bottom.
    enum BlockPart: Hashable {
        /// Whose block it is — the hand-over can hold several agents.
        case name
        /// The simple way: the setup prompt for an assistant, with what Copy takes on show.
        case setupPrompt
        /// Where the token went, and the one chance to copy it.
        case token
        /// The connection facts under their two routes, folded.
        case byHand
    }

    /// A hand-over block: the simple way leads, the token follows on show — it is handed over
    /// once, so it is never folded away — and the facts for a client set up by hand come last.
    /// Two blocks are the token alone. One whose token file failed: nothing can be set up until
    /// a reissue. And every block of a REISSUE: it changes the token and nothing else, the
    /// clients are set up already, and a bulk reissue would otherwise repeat the same card and
    /// fold once per agent; a client still to be set up has How to connect on the agent's row.
    static func parts(of block: HandoffBlock, isReissue: Bool) -> [BlockPart] {
        guard !isReissue, block.offersSetupPrompt else { return [.name, .token] }
        return [.name, .setupPrompt, .token, .byHand]
    }

    /// An existing agent's sheet: the same two ways, without the name (the title says it) and
    /// without the token (copied once, long ago).
    static let connectionParts: [BlockPart] = [.setupPrompt, .byHand]

    /// What the hand-over says and shows.
    struct IssuedPresentation {
        let blocks: [HandoffBlock]
        /// The one-time fact, said as a warning — only where a token is on the sheet and nowhere
        /// else (its file failed).
        let banner: String?
        /// Who copies the token and who does not: said wherever a token is in its file.
        let tokenNote: String?
        /// A copied token leaves the clipboard: said where something can be copied as a secret.
        let clipboardNote: String?
        /// A role that runs now can read the clipboard while a token is on it (#375): said where
        /// a token can be copied and a task, or a background command of one, is running.
        let clipboardWarning: String?
    }

    static let tokenNote =
        "Copy the token only for a client that sends it in a header; a client that runs the bridge reads it from the file. It cannot be shown again: a client that needs it later needs a reissue."
    static let clipboardNote = "A copied token leaves the clipboard after 60 seconds, or when NanoTeams quits."
    /// The simple way's title, and the words under it (`ExternalAgentsSetupPrompt`): what the
    /// prompt is for and that no token is in it. A bottom-of-the-sheet caption about a pill
    /// named Copy prompt until 2026-11-12; the block's own words since it leads.
    static let setupPromptTitle = "Set it up with your assistant"
    static let setupPromptNote =
        "Paste the prompt into any assistant — the agent running here, or a chat that cannot touch this Mac. It carries this agent's connection facts and the token rules, and has the assistant work out which client is yours, write its configuration and walk you through the rest. It carries no token."
    /// The fold over the connection facts.
    static let byHandTitle = "Set it up by hand"
    static let clipboardWarning =
        "Something of yours is still live — a running task, a parked one whose other roles keep working, or a background command — and a role reads the clipboard with pbpaste. Paste a copied token at once, or copy it when nothing is running."
    /// Under an existing agent's facts: where its token is, and how to get it again.
    static let connectionNote =
        "The token was copied when the agent was added or its token reissued, and cannot be shown again; a client that sends it in a header needs a reissue to get it. A client that runs the bridge reads it from the file."

    /// The name an agent gets when the field is left alone.
    static let defaultAgentName = "External agent"

    static func handoffBlock(
        _ item: IssuedAgentTokenItem, isReissue: Bool, port: UInt16, executablePath: String, home: URL
    ) -> HandoffBlock {
        let line = Facts.handoffLine(delivery: item.delivery, isReissue: isReissue, home: home)
        switch item.delivery {
        case .written:
            return HandoffBlock(
                item: item, line: line,
                fields: Facts.fields(port: port, executablePath: executablePath, home: home, shortID: item.shortID),
                isFailure: false)
        case .notWritten:
            return HandoffBlock(item: item, line: line, fields: [], isFailure: true)
        }
    }

    static func issuedPresentation(
        tokens: [IssuedAgentTokenItem], isReissue: Bool, port: UInt16, executablePath: String, home: URL,
        rolesAreRunning: Bool = false
    ) -> IssuedPresentation {
        let blocks = tokens.map {
            handoffBlock($0, isReissue: isReissue, port: port, executablePath: executablePath, home: home)
        }
        let toCopy = blocks.count(where: \.mustBeCopied)
        return IssuedPresentation(
            blocks: blocks,
            banner: toCopy == 0 ? nil
                : toCopy == 1 ? "Copy the token now: its file could not be written, and it cannot be shown again."
                : "Copy the tokens now: their files could not be written, and they cannot be shown again.",
            // Who copies the token and who reads it from its file — not said where no token
            // is in a file: there the banner and the block's own line say all there is.
            tokenNote: blocks.contains { !$0.isFailure } ? tokenNote : nil,
            clipboardNote: blocks.isEmpty ? nil : clipboardNote,
            clipboardWarning: !blocks.isEmpty && rolesAreRunning ? clipboardWarning : nil)
    }

    /// The name an agent gets: what was typed, trimmed — or, with the field left alone, the
    /// default the placeholder showed.
    static func effectiveName(draft: String) -> String {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? defaultAgentName : typed
    }

    /// Done closes at once unless a token that exists nowhere but on the sheet was not copied.
    /// Judged against THESE tokens' ids, so an id copied at an earlier hand-over counts for
    /// nothing.
    static func mayCloseWithoutAsking(blocks: [HandoffBlock], copied: Set<UUID>) -> Bool {
        blocks.allSatisfy { !$0.mustBeCopied || copied.contains($0.id) }
    }

    let existingAgents: [ExternalAgentRow]
    /// The port the server listens on — what the endpoint names.
    let port: UInt16
    /// The stdio bridge is this running binary; the bridge command names it.
    let executablePath: String
    /// The home folder the token folder is under.
    let clientHome: URL
    /// A task, or a background command of one, is running: its roles can read the clipboard.
    let rolesAreRunning: Bool
    let issuers: TokenIssuers

    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage
    @State private var nameDraft: String = ""
    @State private var copiedTokenIDs: Set<UUID> = []
    /// Fields copied, by agent and field: never a token, so only for the button's "Copied".
    @State private var copiedFieldIDs: Set<String> = []
    /// Setup prompts copied, by agent — the same, and never a token either.
    @State private var copiedPromptIDs: Set<UUID> = []
    /// Agents whose prompt text is on show, and agents whose facts are: both start folded — the
    /// simple way is one button, and the facts are for the person who would rather not use it.
    @State private var shownPromptIDs: Set<UUID> = []
    @State private var shownFactIDs: Set<UUID>
    @State private var isConfirmingClose = false
    @State private var errorMessage: String?

    /// `message` is the line the sheet opens with: `nil` wherever a person opens it, since only
    /// an issuing action sets one. The previews pass one, so the hand-over of a reissue that left
    /// an agent out can be looked at without a Keychain that refuses a write. `factsUnfolded`
    /// opens the stage with its agents' facts on show — for a preview and the render test, which
    /// have no hand to open a fold with; a person always finds them folded.
    init(
        opening stage: Stage, existingAgents: [ExternalAgentRow], port: UInt16, executablePath: String,
        clientHome: URL, rolesAreRunning: Bool = false, issuers: TokenIssuers, message: String? = nil,
        factsUnfolded: Bool = false
    ) {
        self.existingAgents = existingAgents
        self.port = port
        self.executablePath = executablePath
        self.clientHome = clientHome
        self.rolesAreRunning = rolesAreRunning
        self.issuers = issuers
        _stage = State(initialValue: stage)
        _errorMessage = State(initialValue: message)
        _shownFactIDs = State(initialValue: factsUnfolded ? Self.agentIDs(in: stage) : [])
    }

    /// The agents a stage shows facts for.
    static func agentIDs(in stage: Stage) -> Set<UUID> {
        switch stage {
        case .add, .reissue: []
        case .issued(let tokens, _): Set(tokens.map(\.id))
        case .connection(let row): [row.id]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            TerminalDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if let errorMessage { errorBanner(errorMessage) }
                    switch stage {
                    case .add: addForm
                    case .reissue(let target): reissueConfirmation(target)
                    case .issued(let tokens, let isReissue): handover(tokens: tokens, isReissue: isReissue)
                    case .connection(let row): connection(row)
                    }
                }
                .padding(Spacing.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Colors.surfacePrimary)
        }
        .frame(minWidth: 620, minHeight: 360)
        // In the hand-over, no system dismissal may bypass `closeGuarded`: Escape is taken by the
        // hidden button below, and this keeps the sheet's own Escape handling out of it.
        .interactiveDismissDisabled(isRevealing)
        .background {
            // Escape in the hand-over goes through the same question as Done (#28: a sheet whose
            // cancel is not a visible button needs one for the key).
            if case .issued = stage {
                Button("", action: closeGuarded).keyboardShortcut(.cancelAction).hidden()
            }
        }
        .confirmationDialog(
            "Close without copying the token?", isPresented: $isConfirmingClose, titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It cannot be shown again. You can reissue it later.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Spacing.m) {
            MonoLabel(text: title, marker: true)
            Spacer()
            switch stage {
            case .add:
                Button("Cancel") { dismiss() }
                    .buttonStyle(.terminalSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { addAgent() }
                    .buttonStyle(.terminalPrimary)
                    .keyboardShortcut(.defaultAction)
            case .reissue(let target):
                Button("Cancel") { dismiss() }
                    .buttonStyle(.terminalSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Reissue") { reissue(target) }
                    .buttonStyle(.terminalDanger)
                    .keyboardShortcut(.defaultAction)
            case .issued:
                Button("Done") { closeGuarded() }
                    .buttonStyle(.terminalPrimary)
                    .keyboardShortcut(.defaultAction)
            case .connection:
                Button("Done") { dismiss() }
                    .buttonStyle(.terminalPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.m)
    }

    private var isRevealing: Bool {
        if case .issued = stage { true } else { false }
    }

    private var title: String {
        switch stage {
        case .add: "Add agent"
        case .reissue: "Reissue token"
        case .issued(let tokens, _): tokens.count == 1 ? "Token issued" : "Tokens issued"
        case .connection(let row): "How to connect “\(row.label)”"
        }
    }

    // MARK: - Add

    private var addForm: some View {
        let duplicate = ExternalAgentsSettingsPresentation.duplicateLabel(
            Self.effectiveName(draft: nameDraft), among: existingAgents)
        return VStack(alignment: .leading, spacing: Spacing.m) {
            labelled("Name") {
                // The placeholder is the name Add will use when the field is left alone. No
                // `onSubmit`: Return reaches the header's default button (as in
                // `MCPServerEditorSheet`) — one path, so one press cannot issue two tokens.
                TextField(Self.defaultAgentName, text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(Typography.termBase)
                    .terminalField()
                if let duplicate {
                    Text("An agent named “\(duplicate)” already exists.")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            caption(Self.addCaption)
        }
    }

    /// What the next step does with the token.
    static let addCaption =
        "The next step writes the token to a file for the bridge, lets you copy it once for a client that sends it in a header, and gives you a prompt that has your assistant set the client up."

    // MARK: - Reissue

    private func reissueConfirmation(_ target: ReissueTarget) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(target.title)
                .font(Typography.subheadlineSemibold)
                .foregroundStyle(Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            banner(target.message, glyph: TerminalGlyph.review, tint: Colors.warningTint, ink: Colors.warning)
        }
    }

    // MARK: - Hand-over

    private func handover(tokens: [IssuedAgentTokenItem], isReissue: Bool) -> some View {
        let presentation = Self.issuedPresentation(
            tokens: tokens, isReissue: isReissue, port: port, executablePath: executablePath, home: clientHome,
            rolesAreRunning: rolesAreRunning)
        return VStack(alignment: .leading, spacing: Spacing.l) {
            if let text = presentation.banner {
                banner(text, glyph: TerminalGlyph.review, tint: Colors.warningTint, ink: Colors.warning)
            }
            if let text = presentation.clipboardWarning {
                banner(text, glyph: TerminalGlyph.review, tint: Colors.warningTint, ink: Colors.warning)
            }
            ForEach(presentation.blocks) { block in
                handoffView(block, isReissue: isReissue)
            }
            if let note = presentation.tokenNote {
                caption(note)
            }
            if let note = presentation.clipboardNote {
                caption(note)
            }
        }
    }

    private func handoffView(_ block: HandoffBlock, isReissue: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            ForEach(Self.parts(of: block, isReissue: isReissue), id: \.self) { part in
                switch part {
                case .name:
                    Text(block.item.label)
                        .font(Typography.subheadlineSemibold)
                        .foregroundStyle(Colors.textPrimary)
                        .lineLimit(1)
                case .setupPrompt:
                    setupPromptBlock(for: block.id, shortID: block.item.shortID)
                case .token:
                    tokenRow(block)
                case .byHand:
                    byHandBlock(block.fields, owner: block.id)
                }
            }
        }
    }

    /// Where the token went and what is left to do, with the one chance to copy it beside the
    /// words that say who needs to.
    private func tokenRow(_ block: HandoffBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            if block.isFailure {
                StatusGlyph(glyph: TerminalGlyph.failed, color: Colors.error)
            }
            Text(block.line)
                .font(Typography.caption)
                .foregroundStyle(block.isFailure ? Colors.error : Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            SettingsPillButton(
                title: copiedTokenIDs.contains(block.id) ? "Copied" : "Copy token",
                icon: copiedTokenIDs.contains(block.id) ? "checkmark" : "key"
            ) {
                ExternalAgentsPasteboard.copySecret(block.item.token)
                copiedTokenIDs.insert(block.id)
            }
        }
    }

    // MARK: - Connection

    private func connection(_ row: ExternalAgentRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ForEach(Self.connectionParts, id: \.self) { part in
                switch part {
                case .setupPrompt:
                    setupPromptBlock(for: row.id, shortID: row.shortID)
                case .byHand:
                    byHandBlock(
                        Facts.fields(port: port, executablePath: executablePath, home: clientHome, shortID: row.shortID),
                        owner: row.id)
                case .name, .token:
                    // Not parts of this stage: the title names the agent, and its token was
                    // handed over when it was issued.
                    EmptyView()
                }
            }
            caption(Self.connectionNote)
        }
    }

    // MARK: - Pieces

    /// The simple way: the prompt for an assistant, built for this agent, with Copy as the
    /// block's own button and what it takes folded under it. Plain text, not `copySecret`: the
    /// prompt holds no token, so nothing here has to be taken back off the clipboard — and it
    /// counts for nothing in `mayCloseWithoutAsking`.
    private func setupPromptBlock(for id: UUID, shortID: String) -> some View {
        let prompt = ExternalAgentsSetupPrompt.text(
            port: port, executablePath: executablePath, home: clientHome, agentShortID: shortID)
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(Self.setupPromptTitle)
                    .font(Typography.subheadlineSemibold)
                    .foregroundStyle(Colors.textPrimary)
                Spacer(minLength: 0)
                SettingsPillButton(
                    title: copiedPromptIDs.contains(id) ? "Copied" : "Copy prompt",
                    icon: copiedPromptIDs.contains(id) ? "checkmark" : "doc.on.doc"
                ) {
                    ExternalAgentsPasteboard.copyText(prompt)
                    copiedPromptIDs.insert(id)
                }
            }
            caption(Self.setupPromptNote)
            SettingsDisclosureRow(
                title: "Show the prompt", icon: "text.alignleft", isExpanded: isPromptShown(id)
            ) {
                Text(prompt)
                    .font(Typography.termSm)
                    .foregroundStyle(Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceElevated))
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceCard))
    }

    /// The facts for a client set up by hand, folded: its two routes each under its own line,
    /// what both need, and where the configuration and the token may live — said where the
    /// configuration is written.
    private func byHandBlock(_ fields: [Facts.Field], owner: UUID) -> some View {
        SettingsDisclosureRow(
            title: Self.byHandTitle, icon: "wrench.and.screwdriver", isExpanded: areFactsShown(owner)
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                ForEach(Facts.groups(fields)) { group in
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        MonoLabel(text: group.title, rule: true)
                        ForEach(group.fields) { field in
                            let key = "\(owner.uuidString)/\(field.id)"
                            ExternalAgentsConnectionFactRow(field: field, isCopied: copiedFieldIDs.contains(key)) {
                                ExternalAgentsPasteboard.copyText(field.value)
                                copiedFieldIDs.insert(key)
                            }
                        }
                    }
                }
                caption(Facts.placementRules)
            }
            .padding(.top, Spacing.xs)
        }
    }

    /// One agent's fold as a binding into the set that holds the open ones. Read and written
    /// through the property itself, not `$shownPromptIDs`: a `@State` reached only through its
    /// projection reads as unused to the dead-code scan (DEBTS D-B29).
    private func isPromptShown(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { shownPromptIDs.contains(id) },
            set: { shown in
                if shown { shownPromptIDs.insert(id) } else { shownPromptIDs.remove(id) }
            })
    }

    private func areFactsShown(_ owner: UUID) -> Binding<Bool> {
        Binding(
            get: { shownFactIDs.contains(owner) },
            set: { shown in
                if shown { shownFactIDs.insert(owner) } else { shownFactIDs.remove(owner) }
            })
    }

    private func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func errorBanner(_ text: String) -> some View {
        banner(text, glyph: TerminalGlyph.failed, tint: Colors.errorTint, ink: Colors.error)
    }

    private func banner(_ text: String, glyph: String, tint: Color, ink: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            StatusGlyph(glyph: glyph, color: ink)
            Text(text)
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(tint))
    }

    // MARK: - Actions

    private func addAgent() {
        issue(isReissue: false) {
            IssueResult(tokens: try issuers.addAgent(Self.effectiveName(draft: nameDraft)), note: nil)
        }
    }

    private func reissue(_ target: ReissueTarget) {
        issue(isReissue: true) {
            switch target {
            case .one(let row): return IssueResult(tokens: try issuers.rotateToken(row.id), note: nil)
            case .all: return issuers.rotateAllTokens()
            }
        }
    }

    /// `afterIssuing` decides; this applies. A sheet hands over once — `.issued` has no way out
    /// but closing — so the copied set it starts with is the one the hand-over judges.
    private func issue(isReissue: Bool, _ produce: () throws -> IssueResult) {
        let next = Self.afterIssuing(Result(catching: produce), at: stage, isReissue: isReissue)
        stage = next.stage
        errorMessage = next.message
    }

    private func closeGuarded() {
        guard case .issued(let tokens, let isReissue) = stage else { return dismiss() }
        let blocks = Self.issuedPresentation(
            tokens: tokens, isReissue: isReissue, port: port, executablePath: executablePath, home: clientHome
        ).blocks
        if Self.mayCloseWithoutAsking(blocks: blocks, copied: copiedTokenIDs) {
            dismiss()
        } else {
            isConfirmingClose = true
        }
    }
}
