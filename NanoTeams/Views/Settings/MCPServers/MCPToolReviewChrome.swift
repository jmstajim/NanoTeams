import SwiftUI

/// The review sheet's buttons, as data: which actions a tool's state offers, which one Escape
/// and Return reach, and which ones ask before they write.
///
/// **Escape is always a neutral Close.** A macOS sheet has no click-outside dismissal, so
/// Escape is how a person closes it, and until 2026-09-23 it was bound to Reject — which on an
/// approved tool opened through "View" deleted the approval. No action that writes is bound to
/// Escape in any state.
///
/// **Return approves only a NEW tool.** An approved tool has no Approve at all: re-approving an
/// unchanged tool writes a fresh pin, a fresh pin starts without its Always-allow grant, and
/// Return on the old sheet reset the grant. A REWRITE of an approved tool has Approve, but not on
/// Return — that sheet exists to catch the rug pull, and one reflexive keypress must not re-arm
/// it. A text the person already refused is not approved on Return either.
///
/// **Every approval on record can be revoked where it is shown.** Refusing a rewrite keeps the
/// approval of the old text (so the tool stays "changed" against what was read), which means a
/// server that restores that text ships it again without a sheet. The rewrite's sheet therefore
/// offers the same "Revoke approval…" as an approved tool's, bound to the OLD text's hash
/// (`MCPPinState.approvedHash(liveHash:)`).
///
/// **A sheet the connection refused goes stale.** Every action is bound to the text on screen,
/// so once the connection says that text moved, every write the sheet offers would be refused
/// again. It offers Close alone and says why. It does not swap in the live text instead: the
/// person had read part of the old one, and a second click on an Approve that stayed in place
/// would approve a text they had not read.
nonisolated struct MCPToolReviewChrome: Hashable, Sendable {

    nonisolated enum Kind: Hashable, Sendable {
        case close, revoke, reject, approve
    }

    nonisolated enum Shortcut: Hashable, Sendable {
        /// Escape.
        case cancel
        /// Return.
        case primary
    }

    nonisolated struct Action: Hashable, Sendable, Identifiable {
        let kind: Kind
        let title: String
        let shortcut: Shortcut?

        var id: Kind { kind }
        /// Revoking takes an approval off the record and its grant with it — it confirms first.
        var asksFirst: Bool { kind == .revoke }
    }

    let actions: [Action]
    /// The rewrite warning above the text.
    let showsRewriteBanner: Bool
    /// The comparison against the approved text.
    let showsChanges: Bool
    /// What the revoke confirmation says — `nil` when nothing is approved, so nothing can be
    /// revoked.
    let revokeConfirmation: String?
    /// Beside the refusal, once the sheet has gone stale: what to do instead.
    let staleNote: String?

    init(pinState: MCPPinState, isRejected: Bool, isStale: Bool = false) {
        let close = Action(kind: .close, title: "Close", shortcut: .cancel)
        let revoke = Action(kind: .revoke, title: "Revoke approval…", shortcut: nil)
        let offered: [Action]
        switch pinState {
        case .approved:
            offered = [close, revoke]
            showsRewriteBanner = false
            showsChanges = false
            revokeConfirmation = "The tool leaves the prompts of every role granted it from the next "
                + "step on, and its Always allow grant goes with it. It comes back to this list as a new tool."
        case .new:
            offered = [close] + Self.decide(
                reject: "Reject", approve: "Approve", isRejected: isRejected, approveOnReturn: true)
            showsRewriteBanner = false
            showsChanges = false
            revokeConfirmation = nil
        case .changed:
            offered = [close, revoke] + Self.decide(
                reject: "Reject the new text", approve: "Approve the new text",
                isRejected: isRejected, approveOnReturn: false)
            showsRewriteBanner = true
            showsChanges = true
            revokeConfirmation = "The approval of the text you read before is deleted. If the server "
                + "restores that text, it comes back to this list as a new tool instead of reaching "
                + "the prompts again."
        }
        actions = isStale ? [close] : offered
        staleNote = isStale
            ? "Nothing was recorded. Close this sheet and open the tool again to read the text the "
                + "server offers now."
            : nil
    }

    /// A text awaiting a decision. One the person already refused offers no second refusal,
    /// and approving it takes a deliberate click — Return does not reverse a decision.
    private static func decide(
        reject: String, approve: String, isRejected: Bool, approveOnReturn: Bool
    ) -> [Action] {
        guard !isRejected else { return [Action(kind: .approve, title: approve, shortcut: nil)] }
        return [
            Action(kind: .reject, title: reject, shortcut: nil),
            Action(kind: .approve, title: approve, shortcut: approveOnReturn ? .primary : nil),
        ]
    }

    /// What a refused write tells the person: the review's own reason when the connection
    /// refused it, the disk's otherwise. Shared by the sheet and the detail view.
    static func failureMessage(for error: any Error) -> String {
        if let refusal = error as? MCPReviewError { return refusal.message }
        return "That change could not be saved. Check that the app can write to its support folder."
    }

    /// Whether a failed action leaves the sheet showing a tool the connection no longer holds.
    /// Every `MCPReviewError` does — the text moved, went away, or was decided elsewhere, so the
    /// sheet's picture is out of date. A disk failure does not: the text on screen is still the
    /// live one, and trying again is a fair thing to do.
    static func leavesSheetStale(after error: any Error) -> Bool {
        error is MCPReviewError
    }
}

/// What the review sheet prints of the server's OWN text, as opposed to what the app made of it.
///
/// Two cards print what the server sent rather than a cleaned rendering: the origin card's "its
/// name for the tool" and the raw schema. Both spell every hidden character out
/// (`MCPTextSanitizer.escapeHidden`) — the name on one line — and never remove one: this is the
/// sheet where a person approves the tool itself, and a right-to-left override in its name
/// rendered the name reversed here while the approval card's title was already cleaned (F25).
/// The canonical form escapes C0 controls as JSON does and nothing else, hence the escape on top.
///
/// The banner speaks for the whole tool (`MCPToolDescriptor.strippedHiddenCharacters`), so it
/// says where the characters went: removed from everything the model reads and every rendered
/// card, spelled out in these two. Until 2026-09-23 it said they were removed "before anything
/// below was shown", which the two cards printing the server's text contradicted.
nonisolated struct MCPToolReviewText: Hashable, Sendable {
    /// The server's name for the tool, one line, every hidden character spelled out.
    let originalName: String
    /// The whole frame as the server sent it — its canonical form laid out one member per line
    /// (`JSONValue.prettyJSONString()`), every hidden character spelled out. Laid out FIRST and
    /// escaped after: escaping first and re-formatting would read the escapes back as the
    /// characters they spell. For display only; the pin is taken over the canonical line. Until
    /// 2026-09-24 the card printed that line and wrapped it mid-token (F53).
    let rawTool: String
    /// The banner above the cards — `nil` when the server hid nothing anywhere in the tool.
    let hiddenCharactersNote: String?
    /// The arguments card's text: the list a prompt-taught tool list prints, without the blank
    /// lines between tools, or "No arguments." (`MCPToolChangeReview.readableArguments`, which
    /// the comparison of a rewrite reads too).
    let arguments: String
    /// What the Origin card's Copy puts on the pasteboard: the WHOLE pin hash — the value a
    /// person compares with another copy — never the cut the card draws. Until 2026-10-28 the
    /// payload was inline in the button, and a 12-character copy passed every test.
    let fingerprintToCopy: String

    init(descriptor: MCPToolDescriptor) {
        originalName = MCPTextSanitizer.visibleLine(descriptor.originalName)
        rawTool = MCPTextSanitizer.escapeHidden(descriptor.rawTool.prettyJSONString(), layout: .appLaidOut).display
        hiddenCharactersNote = descriptor.strippedHiddenCharacters ? Self.hiddenCharactersBanner : nil
        arguments = MCPToolChangeReview.readableArguments(descriptor.inputSchema)
        fingerprintToCopy = descriptor.pinHash
    }

    /// Where the Origin card cuts the fingerprint it draws on one line: in the MIDDLE, keeping
    /// both ends — the parts a person compares — where a tail cut would drop one of them
    /// (F53; until 2026-10-28 an inline modifier no test held).
    static let fingerprintTruncation: Text.TruncationMode = .middle

    /// The arguments card's footer, true under both tool-calling modes: which one a step uses
    /// is the provider's answer at run time (rule #330), not a fact this sheet has. It said
    /// "Rendered by the same code that writes them into the prompt", which a model calling tools
    /// natively — the default for a capable provider — never sees (F53).
    static let argumentsFooter = "How a tool list written into the prompt shows the arguments. "
        + "A model that calls tools natively is sent the same parameters as a JSON schema; "
        + "the raw schema below is everything the server sent."

    static let hiddenCharactersBanner =
        "The server sent invisible or direction-changing characters in this tool. None of them "
        + "reaches the model, and this sheet shows them only where it prints the server's own text — "
        + "its name for the tool and the raw schema — spelled out as \\u{…}."

    /// The comparison's note when a rewrite changed only hidden characters. The old text's are
    /// not kept anywhere a person can read them; the new text's are, in the raw schema.
    static let invisibleOnlyChangeNote =
        "The approved text and this one read the same once invisible characters are removed — the "
        + "server changed only characters no one can see. The raw schema below spells out the ones "
        + "it sends now as \\u{…}."
}

/// What the review sheet's Annotations card says about a tool's header parameters
/// (`x-mcp-header`) — `nil` for a tool that declares none.
///
/// Worded from the ERA of the server's session, the decision the approval card's arguments box
/// is built from (`MCPArgumentCoercion.coerce`, `MCPProtocolEra.carriesHeaderParameters`): a
/// modern session ALSO sends each value as its request header — the body carries it too — and
/// with no session known (the server is not connected) the line says what is true either way. A
/// legacy session has no header channel and sends every argument in the body alone, so there is
/// no line: since 2026-10-28 a legacy listing admits no header parameter at all
/// (`MCPToolDescriptorFactory`), and a tool it listed reaches this with none. The sheet is opened
/// from the server's page, which holds the connection and so its era. Until 2026-10-28 the
/// line read "Sent as headers: Mcp-Param-…" whatever the era — false for a legacy server, and
/// silent about the body for a modern one.
nonisolated struct MCPHeaderParamsNote: Hashable, Sendable {
    let title: String
    let value: String

    static let title = "Request headers"

    static func of(_ params: [MCPHeaderParam], era: MCPProtocolEra?) -> MCPHeaderParamsNote? {
        guard !params.isEmpty else { return nil }
        // Server strings, printed inside app text: each on its line, nothing hidden.
        let properties = params.map { MCPTextSanitizer.visibleLine($0.argumentName) }
        let headers = params.map(\.headerName)
        let value: String
        switch era.map(\.carriesHeaderParameters) {
        case true?:
            value = "Also sent as request headers: "
                + zip(headers, properties).map { "\($0) (\($1))" }.joined(separator: ", ")
                + ". The body carries the same values."
        case false?:
            return nil
        case nil:
            value = "\(properties.joined(separator: ", ")) always travel in the body; on a server speaking "
                + "\(MCPProtocolEra.modern.displayName) they are also sent as request headers "
                + "\(headers.joined(separator: ", "))."
        }
        return MCPHeaderParamsNote(title: title, value: value)
    }
}

/// How one tool's row reads in the server's tool list. A refused text reads as refused whatever
/// its pin says — a refused rewrite is still "changed" to the policy, but the person has already
/// decided it.
nonisolated enum MCPToolRowStatus: Hashable, Sendable {
    case approved, new, changed, rejected

    /// Whether a tool's row offers "Always allow": an approved tool, on a server whose mode
    /// allows a standing grant (`MCPApprovalMode.allowsStandingGrants` — the rule the approval
    /// card's button and the write itself read). Until 2026-10-28 the page decided this inline,
    /// and nothing pinned it.
    static func offersAlwaysAllow(pinState: MCPPinState, approvalMode: MCPApprovalMode) -> Bool {
        pinState.isApproved && approvalMode.allowsStandingGrants
    }

    /// Where a row sits in the Tools card: what waits for a person first — a rewrite of an
    /// approved tool before all else, since it is the one attack the review exists to catch —
    /// then new tools, then what is decided.
    var reviewRank: Int {
        switch self {
        case .changed: 0
        case .new: 1
        case .approved: 2
        case .rejected: 3
        }
    }

    /// `items` in review order, keeping the server's own order within each status.
    static func reviewOrdered<T>(_ items: [T], status: (T) -> MCPToolRowStatus) -> [T] {
        items.enumerated()
            .sorted { lhs, rhs in
                let (l, r) = (status(lhs.element).reviewRank, status(rhs.element).reviewRank)
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    init(pinState: MCPPinState, isRejected: Bool) {
        if isRejected {
            self = .rejected
            return
        }
        switch pinState {
        case .approved: self = .approved
        case .new: self = .new
        case .changed: self = .changed
        }
    }

    var label: String {
        switch self {
        case .approved: "approved"
        case .new: "new"
        case .changed: "changed"
        case .rejected: "rejected"
        }
    }

    var glyph: String {
        switch self {
        case .approved: TerminalGlyph.done
        case .new: TerminalGlyph.queued
        case .changed: TerminalGlyph.review
        case .rejected: TerminalGlyph.failed
        }
    }

    var color: Color {
        switch self {
        case .approved: Colors.success
        case .new: Colors.info
        case .changed: Colors.warning
        case .rejected: Colors.textTertiary
        }
    }
}

/// The words around a bulk approval. The pill says what it does — approve — and how many; the
/// confirmation names every tool, so nothing is approved unseen. Only NEW tools ever reach it
/// (`MCPServerConnection.newTools`): a rewrite is always reviewed on its own.
nonisolated struct MCPBulkApprovalPrompt: Hashable, Sendable {

    let names: [String]

    init(tools: [MCPToolDescriptor]) {
        names = tools.map(\.modelFacingName)
    }

    private var noun: String { names.count == 1 ? "tool" : "tools" }

    var buttonTitle: String { "Approve \(names.count) new \(noun)…" }

    var title: String { "Approve \(names.count) new \(noun) without reading each one?" }

    var confirmTitle: String { "Approve \(names.count) \(noun)" }

    var message: String {
        "Each one reaches the prompts of the roles granted it from the next step on. "
            + "A rewritten tool is never in this list — it is reviewed on its own.\n\n"
            + names.joined(separator: "\n")
    }
}
