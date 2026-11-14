import SwiftUI
import XCTest

@testable import NanoTeams

/// The review sheet's buttons, as data. The sheet renders exactly these actions with exactly
/// these shortcuts, so what is pinned here is what Escape and Return do.
final class MCPToolReviewChromeTests: XCTestCase {

    private let everyState: [(MCPPinState, Bool)] = [
        (.approved, false),
        (.new, false), (.new, true),
        (.changed(approvedHash: "h1"), false), (.changed(approvedHash: "h1"), true),
    ]

    /// Every sheet the chrome can draw: each state, refused or not, fresh or gone stale.
    private var everyChrome: [MCPToolReviewChrome] {
        everyState.flatMap { state, rejected in
            [false, true].map { MCPToolReviewChrome(pinState: state, isRejected: rejected, isStale: $0) }
        }
    }

    private func kinds(_ chrome: MCPToolReviewChrome) -> [MCPToolReviewChrome.Kind] {
        chrome.actions.map(\.kind)
    }

    // MARK: - Escape

    /// A macOS sheet has no click-outside dismissal, so Escape is how a person closes it — and
    /// it must never write anything. In every state it is a neutral Close.
    func testEscapeIsANeutralCloseInEveryState() {
        for chrome in everyChrome {
            let onEscape = chrome.actions.filter { $0.shortcut == .cancel }
            XCTAssertEqual(onEscape.map(\.kind), [.close], "\(chrome)")
            XCTAssertFalse(onEscape.contains { $0.kind != .close }, "nothing that writes answers Escape")
        }
    }

    /// At most one action answers Return, and never a destructive one.
    func testReturnIsNeverBoundToAnythingButApprove() {
        for chrome in everyChrome {
            let onReturn = chrome.actions.filter { $0.shortcut == .primary }
            XCTAssertLessThanOrEqual(onReturn.count, 1, "\(chrome)")
            XCTAssertTrue(onReturn.allSatisfy { $0.kind == .approve }, "\(chrome)")
        }
    }

    /// Only a NEW tool is approved on Return. A rewrite of an approved tool is the rug pull this
    /// sheet exists to catch, and one reflexive keypress must not re-arm it — approving the new
    /// text takes a click, refused or not.
    func testARewriteIsNeverApprovedOnReturn() {
        for rejected in [false, true] {
            let chrome = MCPToolReviewChrome(pinState: .changed(approvedHash: "h1"), isRejected: rejected)
            XCTAssertNil(chrome.actions.first { $0.shortcut == .primary }, "rejected=\(rejected)")
            XCTAssertEqual(chrome.actions.first { $0.kind == .approve }?.title, "Approve the new text")
        }
    }

    // MARK: - Per state

    /// Viewing an approved tool is reading, not deciding: Close, and a revoke that asks first.
    /// No Approve — re-approving an unchanged tool would silently reset its Always-allow grant.
    func testViewingAnApprovedToolOffersANeutralExitAndNoApprove() {
        let chrome = MCPToolReviewChrome(pinState: .approved, isRejected: false)
        XCTAssertEqual(kinds(chrome), [.close, .revoke])
        XCTAssertTrue(chrome.actions.first { $0.kind == .revoke }?.asksFirst ?? false)
        XCTAssertNil(chrome.actions.first { $0.shortcut == .primary }, "Return does nothing here")
        XCTAssertFalse(chrome.showsRewriteBanner)
        XCTAssertFalse(chrome.showsChanges)
    }

    func testANewToolOffersCloseRejectAndApproveOnReturn() {
        let chrome = MCPToolReviewChrome(pinState: .new, isRejected: false)
        XCTAssertEqual(kinds(chrome), [.close, .reject, .approve])
        XCTAssertEqual(chrome.actions.first { $0.kind == .approve }?.shortcut, .primary)
        XCTAssertFalse(chrome.showsChanges)
    }

    /// A rewrite is decided on the new text, with the comparison in front of it — and the
    /// approval of the OLD text, which stays on record, can be withdrawn from the same sheet.
    func testAChangedToolOffersTheNewTextActionsAndTheComparison() {
        let chrome = MCPToolReviewChrome(pinState: .changed(approvedHash: "h1"), isRejected: false)
        XCTAssertEqual(kinds(chrome), [.close, .revoke, .reject, .approve])
        XCTAssertEqual(
            chrome.actions.map(\.title),
            ["Close", "Revoke approval…", "Reject the new text", "Approve the new text"])
        XCTAssertTrue(chrome.showsRewriteBanner)
        XCTAssertTrue(chrome.showsChanges)
    }

    /// A text the person already refused offers no second refusal, and approving it takes a
    /// deliberate click — Return does not reverse a decision.
    func testARefusedTextCanStillBeApprovedButNotOnReturn() {
        let refusedNew = MCPToolReviewChrome(pinState: .new, isRejected: true)
        XCTAssertEqual(kinds(refusedNew), [.close, .approve])
        XCTAssertNil(refusedNew.actions.first { $0.shortcut == .primary })

        let refusedRewrite = MCPToolReviewChrome(pinState: .changed(approvedHash: "h1"), isRejected: true)
        XCTAssertEqual(kinds(refusedRewrite), [.close, .revoke, .approve])
        XCTAssertNil(refusedRewrite.actions.first { $0.shortcut == .primary })
    }

    /// Refusing a rewrite keeps the old approval, so a server that restores the approved text
    /// ships it again without a sheet. A person who no longer trusts the server must be able to
    /// withdraw that approval too — from the rewrite's own sheet, refused or not, asking first,
    /// in words that say what revoking a rewrite's approval does.
    func testTheApprovalBehindARewriteCanBeRevoked() throws {
        for rejected in [false, true] {
            let chrome = MCPToolReviewChrome(pinState: .changed(approvedHash: "h1"), isRejected: rejected)
            let revoke = try XCTUnwrap(chrome.actions.first { $0.kind == .revoke }, "rejected=\(rejected)")
            XCTAssertTrue(revoke.asksFirst)
            XCTAssertNil(revoke.shortcut)
            let message = try XCTUnwrap(chrome.revokeConfirmation, "rejected=\(rejected)")
            XCTAssertTrue(message.contains("restores"), message)
            XCTAssertTrue(message.contains("as a new tool"), message)
        }
        let approved = try XCTUnwrap(MCPToolReviewChrome(pinState: .approved, isRejected: false).revokeConfirmation)
        XCTAssertTrue(approved.contains("leaves the prompts"), approved)
        XCTAssertNil(MCPToolReviewChrome(pinState: .new, isRejected: false).revokeConfirmation,
                     "nothing is approved, so nothing is revoked")
    }

    // MARK: - Stale

    /// Once the connection has refused an action because the tool moved, this sheet shows a
    /// text that is no longer the live one, and every write it offers would be refused again.
    /// It offers Close alone and says why — the person reopens the tool to read the new text.
    func testAStaleSheetOffersOnlyClose() {
        for (state, rejected) in everyState {
            let stale = MCPToolReviewChrome(pinState: state, isRejected: rejected, isStale: true)
            XCTAssertEqual(kinds(stale), [.close], "\(state) rejected=\(rejected)")
            XCTAssertEqual(stale.actions.first?.shortcut, .cancel)
            XCTAssertNotNil(stale.staleNote, "\(state)")
            XCTAssertNil(MCPToolReviewChrome(pinState: state, isRejected: rejected).staleNote, "\(state)")
        }
    }

    /// Every refusal from the connection means the sheet's picture of the tool is out of date —
    /// changed, withdrawn, already decided. A disk failure does not: the text on screen is still
    /// the live one, and trying again is a fair thing to do.
    func testARefusalFromTheConnectionLeavesTheSheetStaleAndADiskFailureDoesNot() {
        let refusals: [MCPReviewError] = [
            .changedWhileReviewing, .listChangedWhileReviewing, .withdrawn, .alreadyApproved,
        ]
        for refusal in refusals {
            XCTAssertTrue(MCPToolReviewChrome.leavesSheetStale(after: refusal), "\(refusal)")
        }
        XCTAssertFalse(MCPToolReviewChrome.leavesSheetStale(after: CocoaError(.fileWriteNoPermission)))
    }

    // MARK: - Messages

    func testAReviewRefusalIsShownInItsOwnWords() {
        XCTAssertEqual(
            MCPToolReviewChrome.failureMessage(for: MCPReviewError.changedWhileReviewing),
            "The tool changed while you were reading. Review it again.")
        XCTAssertTrue(MCPToolReviewChrome.failureMessage(for: CocoaError(.fileWriteNoPermission))
            .contains("could not be saved"))
    }

    // MARK: - Row status

    func testARefusedTextReadsAsRefusedWhateverItsPinState() {
        XCTAssertEqual(MCPToolRowStatus(pinState: .new, isRejected: true), .rejected)
        XCTAssertEqual(MCPToolRowStatus(pinState: .changed(approvedHash: "h"), isRejected: true), .rejected)
        XCTAssertEqual(MCPToolRowStatus(pinState: .changed(approvedHash: "h"), isRejected: false), .changed)
        XCTAssertEqual(MCPToolRowStatus(pinState: .approved, isRejected: false), .approved)
        XCTAssertEqual(MCPToolRowStatus(pinState: .new, isRejected: false), .new)
        XCTAssertEqual(MCPToolRowStatus.rejected.label, "rejected")
    }

    // MARK: - Bulk approval

    /// The pill says what it does — approve — and how many; the confirmation lists every name
    /// so nothing is approved unseen.
    func testTheBulkApprovalNamesEveryToolItWillApprove() {
        let tools = ["a", "b", "c"].map {
            MCPToolDescriptorTests.makeDescriptor(originalName: $0, modelFacingName: "mcp__folio__\($0)")
        }
        let prompt = MCPBulkApprovalPrompt(tools: tools)
        XCTAssertEqual(prompt.buttonTitle, "Approve 3 new tools…")
        XCTAssertEqual(prompt.confirmTitle, "Approve 3 tools")
        for tool in tools {
            XCTAssertTrue(prompt.message.contains(tool.modelFacingName), prompt.message)
        }
    }

    func testOneToolIsNotPlural() {
        let prompt = MCPBulkApprovalPrompt(tools: [MCPToolDescriptorTests.makeDescriptor()])
        XCTAssertEqual(prompt.buttonTitle, "Approve 1 new tool…")
        XCTAssertEqual(prompt.confirmTitle, "Approve 1 tool")
    }

    // MARK: - The server's own text

    /// One tool, as the factory builds it from what the server sent.
    private func descriptor(_ raw: [String: JSONValue]) throws -> MCPToolDescriptor {
        var object = raw
        if object["inputSchema"] == nil { object["inputSchema"] = .object(["type": .string("object")]) }
        let outcome = try MCPToolDescriptorFactory.build(
            rawTools: [.object(object)], slug: try XCTUnwrap(MCPServerSlug("folio")), era: .modern)
        return try XCTUnwrap(outcome.descriptors.first, "\(outcome.rejections)")
    }

    /// The origin card prints the server's own name for the tool. A right-to-left override in
    /// it rendered the name reversed on the very sheet where a person approves the tool — the
    /// disguise the approval card's title was cleaned of. It is spelled out instead, on one
    /// line.
    func testAHiddenCharacterInTheToolsNameReachesTheSheetAsAVisibleEscape() throws {
        let hostile = try descriptor(["name": .string("read\u{202E}elif\nnow")])
        let text = MCPToolReviewText(descriptor: hostile)
        XCTAssertEqual(text.originalName, "read\\u{202E}elif\\u{000A}now")
        XCTAssertEqual(hostile.originalName, "read\u{202E}elif\nnow", "the wire name is never rewritten")
    }

    /// The raw schema card prints the whole frame. Its canonical form escapes a C0 control as
    /// JSON does, and nothing else — so zero-width, bidi, tag and C1 characters are spelled
    /// out on top of it, wherever they sit.
    func testTheRawSchemaSpellsOutEveryHiddenCharacter() throws {
        let hostile = try descriptor([
            "name": .string("read"),
            "description": .string("Reads.\u{200B} Then\u{1B}[2J"),
            "annotations": .object(["title": .string("Read\u{202E}")]),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(["mode": .object([
                    "type": .string("string"), "enum": .array([.string("fast\u{E0041}\u{85}\u{7F}")]),
                ])]),
            ]),
        ])
        let raw = MCPToolReviewText(descriptor: hostile).rawTool
        for escape in ["\\u{200B}", "\\u{202E}", "\\u{E0041}", "\\u{0085}", "\\u{007F}", "\\u001b[2J"] {
            XCTAssertTrue(raw.contains(escape), "\(escape) in \(raw)")
        }
        XCTAssertFalse(MCPTextSanitizer.containsStrippedCharacters(raw), raw)
    }

    /// The raw schema is pretty-printed BY THE APP, which writes every newline in it: a line or
    /// paragraph separator a server string carries is spelled out, never drawn as a line of the
    /// frame nobody can tell from the printer's own.
    ///
    /// Pinned 2026-10-28, when the raw schema began to be escaped as app-laid-out text.
    func testTheRawSchemaSpellsOutALineSeparatorAServerStringCarries() throws {
        let hostile = try descriptor([
            "name": .string("read"),
            "description": .string("Reads.\u{2028}\"inputSchema\": {}\u{2029}done"),
        ])
        let raw = MCPToolReviewText(descriptor: hostile).rawTool
        XCTAssertTrue(raw.contains("Reads.\\u{2028}"), raw)
        XCTAssertTrue(raw.contains("\\u{2029}done"), raw)
        XCTAssertFalse(raw.contains("\u{2028}") || raw.contains("\u{2029}"), "drawn as a line break")
    }

    /// A tool with nothing hidden is printed exactly as the server sent it, with no banner.
    func testACleanToolIsPrintedAsTheServerSentIt() throws {
        let clean = try descriptor(["name": .string("get-design context"), "description": .string("Reads.\nTwice.")])
        let text = MCPToolReviewText(descriptor: clean)
        XCTAssertEqual(text.originalName, "get-design context")
        XCTAssertEqual(text.rawTool, clean.rawTool.prettyJSONString())
        XCTAssertNil(text.hiddenCharactersNote)
    }

    // MARK: - The arguments and the raw schema, readable (F53)

    /// A tool with no parameters says so in words. `renderParameters` never returns "" — it
    /// prints "Args: none" and two blank lines — so the card's own "No arguments." was
    /// unreachable, and a person read the prompt renderer's placeholder instead.
    ///
    /// RED until 2026-09-24.
    func testAToolWithNoArgumentsSaysSo() throws {
        XCTAssertEqual(MCPToolReviewText(descriptor: try descriptor(["name": .string("ping")])).arguments, "No arguments.")
        let emptyProperties = try descriptor([
            "name": .string("ping"),
            "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
        ])
        XCTAssertEqual(MCPToolReviewText(descriptor: emptyProperties).arguments, "No arguments.")
    }

    /// The list ends where its last argument does: every Arguments card used to end in two
    /// blank lines — the prompt renderer's separator between tools.
    ///
    /// RED until 2026-09-24.
    func testTheArgumentsEndWithTheirLastLine() throws {
        let tool = try descriptor([
            "name": .string("send"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string"), "description": .string("What to send.")]),
                    "chat_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("text")]),
            ]),
        ])
        XCTAssertEqual(
            MCPToolReviewText(descriptor: tool).arguments,
            "Args:\n- chat_id (string)\n- text (string, required) — What to send.")
    }

    /// The footer is one sentence true under BOTH tool-calling modes — which one a step uses is
    /// the provider's answer at run time (rule #330), not a fact the sheet has. It makes three
    /// claims, and each is held against the code it describes, so a rewrite that drops one, or
    /// code that stops making one true, fails here:
    ///  1. the list is what a tool list written into the prompt prints — the prompt-taught body
    ///     carries the card's text verbatim;
    ///  2. a model calling tools natively is sent the same parameters as a JSON schema — the
    ///     native `tools` field carries every one of them, and the native body no list;
    ///  3. the raw schema below is everything the server sent — including what the projection
    ///     drops.
    /// "Rendered by the same code that writes them into the prompt" was false under native tool
    /// calling, the default for a capable provider.
    ///
    /// RED until 2026-09-24 (the old sentence); renamed from "…MatchesTheActiveToolCallingMode",
    /// which no mode was read to check, and its three substring checks let a rewrite drop the
    /// first claim.
    func testArgumentsFooterIsTrueUnderBothToolCallingModes() throws {
        let footer = MCPToolReviewText.argumentsFooter
        let tool = try descriptor([
            "name": .string("send_message"),
            "description": .string("Sends a message."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "chat_id": .object(["type": .string("string")]),
                    "text": .object(["type": .string("string"), "description": .string("What to send.")]),
                ]),
                "required": .array([.string("text")]),
            ]),
            "x-vendor-extension": .string("kept in the raw schema"),
        ])
        let text = MCPToolReviewText(descriptor: tool)
        let schema = ToolSchema(
            name: tool.modelFacingName, description: tool.displayDescription, parameters: tool.inputSchema)

        // 1. What a tool list written into the prompt prints.
        XCTAssertTrue(footer.hasPrefix("How a tool list written into the prompt shows the arguments. "), footer)
        XCTAssertTrue(
            NativeLMStudioClient.buildToolSchemaBody(tools: [schema], mode: .promptTaught).contains(text.arguments),
            "the card's list is the prompt-taught rendering, verbatim")

        // 2. Natively, the same parameters as a JSON schema.
        XCTAssertTrue(footer.contains(
            "A model that calls tools natively is sent the same parameters as a JSON schema;"), footer)
        XCTAssertFalse(
            NativeLMStudioClient.buildToolSchemaBody(tools: [schema], mode: .native).contains(text.arguments),
            "a native request carries no written list")
        let native = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(NativeLMStudioClient.nativeToolsText(tools: [schema]).utf8)) as? [Any])
        let function = try XCTUnwrap((native.first as? [String: Any])?["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertEqual(Set(try XCTUnwrap(parameters["properties"] as? [String: Any]).keys), ["chat_id", "text"])
        XCTAssertEqual(parameters["required"] as? [String], ["text"])

        // 3. The raw schema is everything the server sent.
        XCTAssertTrue(footer.hasSuffix("the raw schema below is everything the server sent."), footer)
        XCTAssertTrue(text.rawTool.contains(#""x-vendor-extension": "kept in the raw schema""#), text.rawTool)
        XCTAssertEqual(text.rawTool, MCPTextSanitizer.escapeHidden(tool.rawTool.prettyJSONString(), layout: .appLaidOut).display)

        XCTAssertFalse(footer.contains("Rendered by the same code"), footer)
    }

    /// The raw schema is pretty-printed to be READ — one member per line, where the canonical
    /// line wrapped mid-token — and escaped AFTER printing, so every escape survives. The pin is
    /// still taken over the canonical form: display changed, the hash did not. The hash is held
    /// to the exact bytes it covers and to a golden value, so moving it off the canonical line
    /// cannot pass with both sides of the comparison moving together (before 2026-10-28,
    /// `pinHash == MCPPinHasher.hash(rawTool:)` was the only hash check here, and it was true
    /// of any hash).
    ///
    /// RED until 2026-09-24: one canonical line.
    func testTheRawSchemaIsPrettyPrintedForReadingAndTheHashIsNot() throws {
        let tool = try descriptor([
            "name": .string("read"),
            "description": .string("Reads.\u{200B}"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(["mode": .object(["type": .string("string"), "enum": .array([.string("fast\u{202E}")])])]),
            ]),
        ])
        let raw = MCPToolReviewText(descriptor: tool).rawTool
        XCTAssertEqual(raw, MCPTextSanitizer.escapeHidden(tool.rawTool.prettyJSONString(), layout: .appLaidOut).display)
        XCTAssertTrue(raw.contains("\n  \"description\": "), raw)
        XCTAssertTrue(raw.contains("\\u{200B}"), raw)
        XCTAssertTrue(raw.contains("\\u{202E}"), raw)
        // The bytes the pin covers: the canonical line, hidden characters as sent.
        let canonical = "{\"description\":\"Reads.\u{200B}\",\"inputSchema\":{\"properties\":{\"mode\":"
            + "{\"enum\":[\"fast\u{202E}\"],\"type\":\"string\"}},\"type\":\"object\"},\"name\":\"read\"}"
        XCTAssertEqual(Array(MCPPinHasher.canonicalForm(rawTool: tool.rawTool).unicodeScalars), Array(canonical.unicodeScalars))
        XCTAssertEqual(tool.pinHash, "f88882028847e8c61712d4ce2665eb48eff27c6ed52c5b3f2dabcfaeb83b23c6",
                       "SHA-256 of the canonical line's UTF-8 bytes")
        XCTAssertNotEqual(raw, MCPTextSanitizer.escapeHidden(tool.rawTool.canonicalJSONString(), layout: .appLaidOut).display)
    }

    // MARK: - The fingerprint (2026-10-28)

    /// Copy puts the WHOLE pin hash on the pasteboard — the one value a person compares with
    /// another copy — and the Origin card cuts what it draws in the MIDDLE, keeping both ends.
    /// Both are the sheet's text, not the view's choice.
    ///
    /// RED until 2026-10-28: the cut and the copy
    /// were inline in the view, and a tail cut or a 12-character copy passed every test.
    func testTheFingerprintIsCopiedWholeAndCutInTheMiddle() throws {
        let tool = try descriptor(["name": .string("read"), "description": .string("Reads.")])
        let text = MCPToolReviewText(descriptor: tool)
        XCTAssertEqual(text.fingerprintToCopy, tool.pinHash)
        XCTAssertEqual(text.fingerprintToCopy.count, 64, "premise: a whole SHA-256 in hex")
        XCTAssertEqual(MCPToolReviewText.fingerprintTruncation, .middle)
    }

    /// The banner speaks for the WHOLE tool (F23), and the sheet now spells hidden characters
    /// out in the two places it prints the server's own text — so the banner no longer says
    /// they were removed from everything below, which those two cards would contradict.
    func testTheHiddenCharactersBannerSaysWhereTheyAreShown() throws {
        let note = try XCTUnwrap(MCPToolReviewText(descriptor: try descriptor(["name": .string("read\u{202E}")]))
            .hiddenCharactersNote)
        XCTAssertFalse(note.contains("removed before anything below was shown"), note)
        XCTAssertTrue(note.contains("\\u{…}"), note)
        XCTAssertTrue(MCPToolReviewText.invisibleOnlyChangeNote.contains("\\u{…}"), MCPToolReviewText.invisibleOnlyChangeNote)
        XCTAssertFalse(MCPToolReviewText.invisibleOnlyChangeNote.contains("does not show"),
                       MCPToolReviewText.invisibleOnlyChangeNote)
    }
}
