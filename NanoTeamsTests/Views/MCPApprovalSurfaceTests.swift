import AppKit
import SwiftUI
import XCTest
@testable import NanoTeams

/// The two places a held MCP call becomes visible: the card list in the task's feed, and the
/// Watchtower banner that points at it.
///
/// The division is the design: the CARD carries the whole arguments document, because that is
/// what has to be read before an outbound call is allowed; the BANNER names the tool and the
/// server and opens the task. A banner that tried to show arguments would be a decision
/// surface nobody can read on.
@MainActor
final class MCPApprovalSurfaceTests: XCTestCase {

    /// The entry a card's call is checked against: a tool whose schema declares nothing, so
    /// every object document is sent as the runtime reads it.
    private static func entry(toolName: String = "mcp__folio__get_screenshot") -> MCPToolsSnapshot.Entry {
        MCPToolsSnapshot.Entry(
            serverID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!,
            slug: MCPServerSlug("folio")!,
            serverDisplayName: "Folio Desktop",
            approvalMode: .manual,
            serverTrusted: false,
            alwaysAllowed: false,
            runsUnattended: false,
            descriptor: MCPToolDescriptorTests.makeDescriptor(originalName: "get_screenshot", modelFacingName: toolName), era: .modern)
    }

    /// What the gate would compute for `document` — `nil` when the send path refuses it, and no
    /// card is ever built.
    private static func preflight(_ document: String) -> MCPDynamicTool.OutgoingCall? {
        guard case .sends(let outgoing) = MCPDynamicTool.preflight(
            argumentsJSON: document, toolName: "mcp__folio__get_screenshot", entry: entry())
        else { return nil }
        return outgoing
    }

    private func request(
        taskID: Int = 1,
        stepID: String = "step_1",
        toolName: String = "mcp__folio__get_screenshot",
        toolTitle: String = "Get screenshot",
        serverName: String = "Folio Desktop",
        arguments: String = #"{"nodeId":"1:2"}"#,
        offerAlways: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 100)
    ) -> MCPApprovalRequest {
        request(
            taskID: taskID, stepID: stepID, toolName: toolName, toolTitle: toolTitle, serverName: serverName,
            document: arguments,
            outgoing: Self.preflight(arguments)
                ?? MCPDynamicTool.OutgoingCall(arguments: .string("the fixture's document was refused"), headerParameters: [:]),
            offerAlways: offerAlways, createdAt: createdAt)
    }

    private func request(
        taskID: Int = 1,
        stepID: String = "step_1",
        toolName: String = "mcp__folio__get_screenshot",
        toolTitle: String = "Get screenshot",
        serverName: String = "Folio Desktop",
        document: String,
        outgoing: MCPDynamicTool.OutgoingCall,
        offerAlways: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 100)
    ) -> MCPApprovalRequest {
        MCPApprovalRequest(
            taskID: taskID,
            stepID: stepID,
            callKey: LLMExecutionService.mcpCallKey(toolName: toolName, argumentsJSON: document),
            toolName: toolName,
            serverSlug: "folio",
            serverDisplayName: serverName,
            toolTitle: toolTitle,
            toolDescription: "Renders the selection.",
            outgoing: outgoing,
            annotations: MCPToolAnnotations(title: nil, stated: [
                .readOnly: true, .destructive: false, .idempotent: false, .openWorld: false,
            ]),
            serverTrusted: false,
            pinHash: "hash",
            offerAlways: offerAlways,
            createdAt: createdAt)
    }

    private func key(_ request: MCPApprovalRequest) -> TaskStepKey {
        TaskStepKey(taskID: request.taskID, stepID: request.stepID)
    }

    // MARK: - The card list

    func testTheListShowsOnlyTheCardsOfItsOwnTask() {
        let mine = request(taskID: 1)
        let theirs = request(taskID: 2, stepID: "step_2")

        let shown = MCPApprovalCardList.sortedRequests(
            for: 1, from: [key(mine): mine, key(theirs): theirs])

        XCTAssertEqual(shown.map(\.taskID), [1])
    }

    /// Oldest first: a person works down a queue, and a card that jumps position under the
    /// cursor is a card that gets the wrong button.
    func testCardsAreOrderedOldestFirst() {
        let older = request(stepID: "a", createdAt: Date(timeIntervalSince1970: 10))
        let newer = request(stepID: "b", createdAt: Date(timeIntervalSince1970: 20))

        let shown = MCPApprovalCardList.sortedRequests(
            for: 1, from: [key(newer): newer, key(older): older])

        XCTAssertEqual(shown.map(\.stepID), ["a", "b"])
    }

    func testAnUnknownTaskShowsNothing() {
        let held = request()

        XCTAssertTrue(MCPApprovalCardList.sortedRequests(for: 99, from: [key(held): held]).isEmpty)
        XCTAssertTrue(MCPApprovalCardList.sortedRequests(for: 1, from: [:]).isEmpty)
    }

    /// Two calls of one tool with different arguments are two decisions, so two cards.
    func testTwoCallsOfOneToolWithDifferentArgumentsAreTwoCards() {
        let first = request(stepID: "a", arguments: #"{"nodeId":"1:2"}"#)
        let second = request(stepID: "b", arguments: #"{"nodeId":"9:9"}"#)

        XCTAssertEqual(
            MCPApprovalCardList.sortedRequests(
                for: 1, from: [key(first): first, key(second): second]).count,
            2)
    }

    // MARK: - What the card shows of the arguments (F25)

    /// The card is where a person reads what is about to leave the machine. A tag-character
    /// payload after a harmless word is invisible in plain text, so the card shows every hidden
    /// character as an escape and says that it did.
    func testInvisibleCharactersInArgumentsAreFlagged() {
        let hostile = request(arguments: #"{"text":"ok"#+"\u{E0074}\u{E006F}\u{E006B}\u{200B}"+#""}"#)
        XCTAssertTrue(hostile.argumentsDisplay.hadHidden)
        XCTAssertEqual(hostile.argumentsDisplay.display, "{\n  \"text\": \"ok\\u{E0074}\\u{E006F}\\u{E006B}\\u{200B}\"\n}")
        XCTAssertEqual(hostile.outgoing.arguments, .object(["text": .string("ok\u{E0074}\u{E006F}\u{E006B}\u{200B}")]),
                       "what goes out is untouched — only what is SHOWN changes")
    }

    /// Clean arguments are shown as the server receives them — no banner, every member on a line
    /// of its own in the canonical order — whatever spacing the model's document used.
    ///
    /// Until 2026-10-28 the card showed the document as written.
    func testCleanArgumentsAreShownAsTheServerReceivesThem() {
        let clean = request(arguments: "{\"b\" :1,\n  \"text\" : \"Привет 👋\"}")
        XCTAssertFalse(clean.argumentsDisplay.hadHidden)
        XCTAssertEqual(clean.argumentsDisplay.display, "{\n  \"b\": 1,\n  \"text\": \"Привет 👋\"\n}")
        XCTAssertEqual(clean.argumentsDisplay.display, clean.outgoing.arguments.prettyJSONString())
    }

    /// Shown whole: the display is never a summary of a long document.
    func testALongArgumentDocumentIsShownWhole() {
        let long = #"{"text":""# + String(repeating: "a", count: 50_000) + "\u{202E}" + #""}"#
        let shown = request(arguments: long).argumentsDisplay
        XCTAssertTrue(shown.hadHidden)
        XCTAssertEqual(shown.display, "{\n  \"text\": \"" + String(repeating: "a", count: 50_000) + "\\u{202E}\"\n}")
    }

    /// The arguments box reads the body the server receives, laid out, and then — only when the
    /// call carries a header parameter, which a modern-era server's schema mirrors out of the
    /// body — the headers it is ALSO sent with, under their own heading, one per line, by name.
    func testTheArgumentsBoxShowsTheBodyThenTheHeadersItIsAlsoSentWith() {
        typealias Call = MCPDynamicTool.OutgoingCall
        XCTAssertEqual(
            MCPApprovalRequest.argumentsText(of: Call(arguments: .object(["b": .int(1), "a": .string("x")]), headerParameters: [:])),
            "{\n  \"a\": \"x\",\n  \"b\": 1\n}")
        XCTAssertEqual(
            MCPApprovalRequest.argumentsText(of: Call(
                arguments: .object(["account": .string("X1"), "node": .string("1"), "zone": .string("eu")]),
                headerParameters: ["Mcp-Param-Zone": "eu", "Mcp-Param-Account": "X1"])),
            "{\n  \"account\": \"X1\",\n  \"node\": \"1\",\n  \"zone\": \"eu\"\n}"
                + "\n\nAlso sent as request headers:\nMcp-Param-Account: \"X1\"\nMcp-Param-Zone: \"eu\"")
        XCTAssertEqual(MCPApprovalRequest.headerParametersHeading, "Also sent as request headers:")

        // A call whose only argument is a header parameter sends it in the body and as a header.
        let headerOnly = request(
            document: #"{"account":"X1"}"#,
            outgoing: Call(arguments: .object(["account": .string("X1")]), headerParameters: ["Mcp-Param-Account": "X1"]))
        XCTAssertFalse(headerOnly.hasNoArguments)
        XCTAssertEqual(headerOnly.argumentsDisplay.display,
                       "{\n  \"account\": \"X1\"\n}\n\nAlso sent as request headers:\nMcp-Param-Account: \"X1\"")
    }

    // MARK: - The arguments box (F34, rule #18)

    private var store: NTMSOrchestrator!
    private var window: NSWindow?
    private var probe: CardHeightProbe!

    override func tearDown() async throws {
        window?.close()
        window = nil
        store = nil
        probe = nil
        chipsProbe = nil
        recorder = nil
        LayoutProbe.record = nil
        try await super.tearDown()
    }

    /// The card list's height as the feed lays it out: under a flexible timeline that takes
    /// whatever the cards leave (`TeamActivityFeedView`).
    private func cardHeight(arguments: String) async throws -> CGFloat {
        store = TestOrchestrator.make()
        store.mcpApprovalDidBegin(request(arguments: arguments))
        probe = CardHeightProbe()
        let probe = try XCTUnwrap(probe)
        let feed = VStack(spacing: 0) {
            Color.clear.frame(maxHeight: .infinity)
            MCPApprovalCardList(taskID: 1, roleDefinitions: [])
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.height = $0 }
        }
        .environment(store)
        let host = NSHostingView(rootView: feed)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        for _ in 0..<15 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        window.close()
        self.window = nil
        return probe.height
    }

    /// A small argument document gets a small card. In the feed a greedy `ScrollView` capped at
    /// 220 points took all 220 for "{}", pushing Allow and Deny down the page; a long document
    /// still stops at the cap and scrolls.
    ///
    /// RED until 2026-09-24: both cards measured the same (F34).
    func testTheArgumentsBoxSizesToWhatIsInIt() async throws {
        let empty = try await cardHeight(arguments: "{}")
        let short = try await cardHeight(arguments: #"{"chat_id":"123"}"#)
        let long = try await cardHeight(
            arguments: "{\n" + (0..<60).map { "  \"line\($0)\": \($0)," }.joined(separator: "\n") + "\n}")

        XCTAssertGreaterThan(empty, 0, "premise: the card rendered")
        XCTAssertLessThan(empty, 200, "a call with no arguments must not draw an empty 220-point box")
        XCTAssertLessThan(short, 220, "one short line must not draw the whole cap")
        XCTAssertGreaterThan(long, short + 150, "a long document grows the box to its cap")
        XCTAssertLessThan(long, short + MCPApprovalCardText.argumentsMaxHeight, "and no further — it scrolls")
    }

    /// The height rule, pure: the measured height up to the cap, and the cap before anything
    /// has been measured.
    func testTheArgumentsHeightIsTheMeasuredOneUpToTheCap() {
        XCTAssertEqual(MCPApprovalCardText.argumentsHeight(measured: 30), 30)
        XCTAssertEqual(MCPApprovalCardText.argumentsHeight(measured: 500), MCPApprovalCardText.argumentsMaxHeight)
        XCTAssertEqual(MCPApprovalCardText.argumentsHeight(measured: .infinity), MCPApprovalCardText.argumentsMaxHeight)
        XCTAssertEqual(MCPApprovalCardText.argumentsMaxHeight, 220)
    }

    /// The box starts UNMEASURED, and the policy's height for that is the cap: the first frame
    /// draws the cap, never a zero-height box that jumps (rule #18). The starting value is the
    /// policy's own, so the view cannot start from anything else.
    ///
    /// RED until 2026-10-28: the first-frame guard lived only in
    /// the view's `@State` initializer, and starting it at 0 passed every test.
    func testTheArgumentsBoxStartsUnmeasuredAtTheCap() {
        XCTAssertEqual(
            MCPApprovalCardText.argumentsHeight(measured: MCPApprovalCardText.unmeasuredArgumentsHeight),
            MCPApprovalCardText.argumentsMaxHeight)
        XCTAssertGreaterThan(MCPApprovalCardText.unmeasuredArgumentsHeight, MCPApprovalCardText.argumentsMaxHeight)
    }

    /// A call that sends nothing says so in words rather than drawing "{}" in a box — and
    /// "nothing" is what the SERVER receives: the card is built from the call the send path
    /// assembles (`MCPDynamicTool.preflight`, which reads the document through
    /// `ToolRuntime.dispatchedArguments`). So a `null` document — no arguments, as an empty one
    /// is — and a document whose only key the runtime drops both read "No arguments"; a call
    /// wrapped in its own envelope reads as the arguments inside it. A document the send path
    /// refuses gets no card at all.
    ///
    /// RED until 2026-10-28 for `null` (shown as "null" while the server was sent
    /// `{"__raw_input__":"null"}`), for `{"":""}` and for the envelope.
    func testACallThatSendsNothingSaysSo() {
        XCTAssertTrue(request(arguments: "{}").hasNoArguments)
        XCTAssertTrue(request(arguments: " { \n } ").hasNoArguments)
        XCTAssertTrue(request(arguments: "").hasNoArguments)
        XCTAssertTrue(request(arguments: " \n ").hasNoArguments)
        XCTAssertTrue(request(arguments: "null").hasNoArguments, "a null document sends no arguments")
        XCTAssertTrue(request(arguments: " null\n").hasNoArguments)
        XCTAssertTrue(request(arguments: #"{"":""}"#).hasNoArguments, "the runtime drops an empty key")
        XCTAssertTrue(request(arguments: #"{"name":"mcp__folio__get_screenshot","arguments":{}}"#).hasNoArguments,
                      "the envelope is unwrapped before the tool sees it")
        XCTAssertFalse(request(arguments: #"{"a":1}"#).hasNoArguments)
        XCTAssertFalse(request(arguments: #"{"a":null}"#).hasNoArguments, "a key that reaches the server is an argument")
        for refused in ["{", "[]", "Null", "hello"] {
            XCTAssertNil(Self.preflight(refused), "\(refused): refused before anything is sent — no card is built")
        }
    }

    /// "The server's own claim" beside the chips is said only where it is true: on a server
    /// not marked trusted that claimed something. A tool the server said nothing about already
    /// reads "The server claimed nothing — treated as: …".
    func testTheClaimNoteAppearsOnlyBesideAClaim() {
        func held(trusted: Bool, annotations: MCPToolAnnotations) -> MCPApprovalRequest {
            MCPApprovalRequest(
                taskID: 1, stepID: "s", callKey: "k", toolName: "mcp__folio__x", serverSlug: "folio",
                serverDisplayName: "Folio", toolTitle: "x", toolDescription: "d",
                outgoing: MCPDynamicTool.OutgoingCall(arguments: .object([:]), headerParameters: [:]),
                annotations: annotations, serverTrusted: trusted, pinHash: "h", offerAlways: false,
                createdAt: Date())
        }
        let claimed = MCPToolAnnotations(raw: .object(["readOnlyHint": .bool(true)]))
        XCTAssertTrue(held(trusted: false, annotations: claimed).marksClaimsAsTheServers)
        XCTAssertFalse(held(trusted: true, annotations: claimed).marksClaimsAsTheServers)
        XCTAssertFalse(held(trusted: false, annotations: .specDefaults).marksClaimsAsTheServers)

        // The note the card hands the chips row is that same decision, in words.
        XCTAssertEqual(held(trusted: false, annotations: claimed).claimNote, MCPApprovalRequest.serversOwnClaimNote)
        XCTAssertNil(held(trusted: true, annotations: claimed).claimNote)
        XCTAssertNil(held(trusted: false, annotations: .specDefaults).claimNote)
        // A hint stated false is a claim too, so it carries the note.
        let notDestructive = MCPToolAnnotations(raw: .object(["destructiveHint": .bool(false)]))
        XCTAssertEqual(held(trusted: false, annotations: notDestructive).claimNote, MCPApprovalRequest.serversOwnClaimNote)
        XCTAssertEqual(MCPApprovalRequest.serversOwnClaimNote, "the server's own claim")
    }

    // MARK: - Where the note sits (2026-10-28)

    private var chipsProbe: ChipsSizeProbe!

    /// The chips view's own size, laid out at its ideal size in a window.
    private func chipsSize(_ sent: [String: JSONValue], note: String?) async throws -> CGSize {
        chipsProbe = ChipsSizeProbe()
        let probe = try XCTUnwrap(chipsProbe)
        let view = MCPAnnotationChipsView(chips: MCPToolAnnotations(raw: .object(sent)).chips, claimNote: note)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { probe.size = $0 }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        for _ in 0..<20 where probe.size == nil {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        window.close()
        self.window = nil
        return try XCTUnwrap(probe.size, "the chips view never reported its size")
    }

    /// "the server's own claim" sits in the claimed-chips row, right after the last chip: it
    /// takes no line of its own, and beside a wider line below it takes no width either. Where
    /// the chips row is the widest line, the note widens it — it is drawn, on that row.
    ///
    /// RED until 2026-10-28: the card drew the note beside the WHOLE block, so beside a long
    /// "treated as" line it floated at the far right, widening the block by its own width.
    func testTheClaimNoteSitsInTheChipsRow() async throws {
        let note = MCPApprovalRequest.serversOwnClaimNote
        // One short chip over a long "treated as" line: the row has room for the note.
        let roomy: [String: JSONValue] = ["idempotentHint": .bool(true)]
        let roomyBare = try await chipsSize(roomy, note: nil)
        let roomyNoted = try await chipsSize(roomy, note: note)
        XCTAssertEqual(roomyNoted.width, roomyBare.width, accuracy: 0.5, "the note fits in the chips row")
        XCTAssertEqual(roomyNoted.height, roomyBare.height, accuracy: 0.5, "the note takes no line of its own")

        // Four chips and nothing assumed: the chips row is the widest line.
        let full: [String: JSONValue] = [
            "readOnlyHint": .bool(false), "destructiveHint": .bool(false),
            "idempotentHint": .bool(true), "openWorldHint": .bool(false),
        ]
        let fullBare = try await chipsSize(full, note: nil)
        let fullNoted = try await chipsSize(full, note: note)
        XCTAssertGreaterThan(fullNoted.width, fullBare.width + 20, "the note is drawn, beside the chips")
        XCTAssertEqual(fullNoted.height, fullBare.height, accuracy: 0.5, "on the chips' own line")

        // Nothing claimed: no row, so no note.
        let silentBare = try await chipsSize([:], note: nil)
        let silentNoted = try await chipsSize([:], note: note)
        XCTAssertEqual(silentNoted.width, silentBare.width, accuracy: 0.5)
        XCTAssertEqual(silentNoted.height, silentBare.height, accuracy: 0.5)
    }

    /// The chips view's size when a row offers it `width` points, as the card's column does.
    private func chipsSize(_ sent: [String: JSONValue], note: String?, offered width: CGFloat) async throws -> CGSize {
        chipsProbe = ChipsSizeProbe()
        let probe = try XCTUnwrap(chipsProbe)
        let view = HStack(spacing: 0) {
            MCPAnnotationChipsView(chips: MCPToolAnnotations(raw: .object(sent)).chips, claimNote: note)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { probe.size = $0 }
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(width, 400) + 100, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        for _ in 0..<20 where probe.size == nil {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        window.close()
        self.window = nil
        return try XCTUnwrap(probe.size, "the chips view never reported its size")
    }

    /// A tool that states all four hints false draws four fixed-size chips — about 410 points
    /// in one row. The chat column can be 200 points wide, so the row breaks onto more lines
    /// rather than growing past its column: at 320 points and at the column's minimum less the
    /// card's padding the chips view is no wider than it was offered, and every line is one
    /// chip tall — no chip's label broke inside it. With room the chips stay on one line; the
    /// claim note still follows the last chip — on its line where it fits there, as at 320
    /// points, and at the start of the next where it does not.
    ///
    /// RED until 2026-10-28: one `HStack` with no fallback — the row kept its 410 points in
    /// any column and pushed the card past it.
    func testTheClaimedChipsBreakOntoMoreLinesInANarrowColumn() async throws {
        let fourFalse: [String: JSONValue] = [
            "readOnlyHint": .bool(false), "destructiveHint": .bool(false),
            "idempotentHint": .bool(false), "openWorldHint": .bool(false),
        ]
        let note = MCPApprovalRequest.serversOwnClaimNote
        let roomy = try await chipsSize(fourFalse, note: nil, offered: 2000)
        XCTAssertGreaterThan(roomy.width, 320, "premise: the four chips need more than 320 points on one line")
        let oneLine = roomy.height

        let chips = MCPToolAnnotations(raw: .object(fourFalse)).chips.claimed
        let sizes = try await badgeSizes(chips)
        XCTAssertEqual(oneLine, try XCTUnwrap(sizes.map(\.height).max()), accuracy: 1, "premise: one line is one chip tall")

        for width in [320, WindowLayout.teamBoardActivityMinWidth - 2 * Spacing.s] {
            let bare = try await chipsSize(fourFalse, note: nil, offered: width)
            let noted = try await chipsSize(fourFalse, note: note, offered: width)
            XCTAssertLessThanOrEqual(bare.width, width + 0.5, "the chips row is \(bare.width) pt in \(width)")
            XCTAssertLessThanOrEqual(noted.width, width + 0.5, "with the note, \(noted.width) pt in \(width)")
            XCTAssertGreaterThan(bare.height, oneLine * 1.5, "at \(width) the row breaks onto more lines")
            XCTAssertGreaterThanOrEqual(noted.height, bare.height - 0.5, "the note is drawn at \(width)")
            if width == 320 {
                XCTAssertEqual(noted.height, bare.height, accuracy: 0.5, "at 320 the note fits after the last chip, on its line")
            }
            // Each line as tall as its tallest chip ALONE — a chip whose label broke inside it
            // would be taller — with the lines the chips' own widths make, left to right.
            var lines: [[CGSize]] = [[]]
            var x: CGFloat = 0
            for size in sizes {
                if x > 0, x + size.width > width {
                    lines.append([])
                    x = 0
                }
                lines[lines.count - 1].append(size)
                x += size.width + MCPAnnotationChipsView.chipSpacing
            }
            let tallest = lines.map { $0.map(\.height).max() ?? 0 }.reduce(0, +)
            let gaps = CGFloat(lines.count - 1) * MCPAnnotationChipsView.lineSpacing
            // A line's height is its tallest chip's, plus at most a point where baselines differ.
            XCTAssertLessThanOrEqual(bare.height, tallest + gaps + CGFloat(lines.count),
                                     "at \(width): \(bare.height) pt for \(lines.count) lines of \(sizes)")
            XCTAssertGreaterThanOrEqual(bare.height, tallest + gaps - 0.5, "at \(width): every line is drawn")
        }
    }

    /// Each chip's own size, laid out alone at its ideal size.
    private func badgeSizes(_ chips: [MCPAnnotationChips.Chip]) async throws -> [CGSize] {
        chipsProbe = ChipsSizeProbe()
        let probe = try XCTUnwrap(chipsProbe)
        let view = HStack(alignment: .top, spacing: 0) {
            ForEach(chips) { chip in
                MCPAnnotationChipsView.badge(for: chip)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { probe.badges[chip.id] = $0 }
            }
        }
        .fixedSize()
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        for _ in 0..<20 where probe.badges.count < chips.count {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        window.close()
        self.window = nil
        return try chips.map { try XCTUnwrap(probe.badges[$0.id], "the chip \($0.label) was laid out") }
    }

    // MARK: - The layout the app writes, the era, the buttons, the baseline (2026-10-28)

    /// The arguments box is laid out by the app, so the only line break in it is the "\n" the app
    /// writes. Every other line or paragraph separator a value carries — U+2028, U+2029, NEL, a
    /// carriage return, a tab: the pretty printer never emits one — is spelled out as `\u{…}`
    /// and flagged, header lines included, in one scan with one warning.
    ///
    /// RED until 2026-10-28: U+2028, U+2029, "\r" and "\t" were kept as layout and drew as
    /// line breaks (or a tab stop), unflagged.
    func testTheOnlyLineBreakInTheArgumentsBoxIsTheOneTheAppWrites() {
        typealias Call = MCPDynamicTool.OutgoingCall
        func held(_ outgoing: Call) -> MCPApprovalRequest {
            MCPApprovalRequest(
                taskID: 1, stepID: "s", callKey: "k", toolName: "mcp__folio__x", serverSlug: "folio",
                serverDisplayName: "Folio", toolTitle: "x", toolDescription: "d",
                outgoing: outgoing, annotations: .specDefaults, serverTrusted: false, pinHash: "h",
                offerAlways: false, createdAt: Date())
        }
        // In the body a value's own "\r" and "\t" reach the box as the printer's escapes, visible
        // as written; the separators it does not escape reach it raw, and are spelled out.
        for separator in ["\u{2028}", "\u{2029}", "\u{0085}"] {
            let code = String(format: "%04X", separator.unicodeScalars.first!.value)
            let body = held(Call(arguments: .object(["text": .string("ok\(separator)x")]), headerParameters: [:]))
            XCTAssertTrue(body.argumentsDisplay.hadHidden, "U+\(code) in the body is flagged")
            XCTAssertEqual(body.argumentsDisplay.display, "{\n  \"text\": \"ok\\u{\(code)}x\"\n}", "U+\(code)")
        }
        for (separator, escape) in [("\r", "\\r"), ("\t", "\\t")] {
            let body = held(Call(arguments: .object(["text": .string("ok\(separator)x")]), headerParameters: [:]))
            XCTAssertEqual(body.argumentsDisplay.display, "{\n  \"text\": \"ok\(escape)x\"\n}")
            XCTAssertFalse(body.argumentsDisplay.hadHidden, "the printer's own escape hides nothing")
        }
        // A header line prints its value as a JSON string — the body's own quoting — so it reads
        // exactly as the body does: the separators the printer does not escape are spelled out
        // and flagged, and its own escapes of "\r" and "\t" are visible as written.
        for separator in ["\u{2028}", "\u{2029}", "\u{0085}"] {
            let code = String(format: "%04X", separator.unicodeScalars.first!.value)
            let header = held(Call(arguments: .object([:]), headerParameters: ["Mcp-Param-A": "a\(separator)b"]))
            XCTAssertTrue(header.argumentsDisplay.hadHidden, "U+\(code) on a header line is flagged")
            XCTAssertTrue(header.argumentsDisplay.display.hasSuffix("\nMcp-Param-A: \"a\\u{\(code)}b\""),
                          "U+\(code): \(header.argumentsDisplay.display)")
        }
        for (separator, escape) in [("\r", "\\r"), ("\t", "\\t"), ("\n", "\\n"), ("\"", "\\\"")] {
            let header = held(Call(arguments: .object([:]), headerParameters: ["Mcp-Param-A": "a\(separator)b"]))
            XCTAssertTrue(header.argumentsDisplay.display.hasSuffix("\nMcp-Param-A: \"a\(escape)b\""),
                          "\(escape): \(header.argumentsDisplay.display)")
            XCTAssertFalse(header.argumentsDisplay.hadHidden, "\(escape): the printer's own escape hides nothing")
        }
        // What the app writes stays layout, and alone flags nothing.
        let clean = request(arguments: #"{"a":1,"b":"two"}"#).argumentsDisplay
        XCTAssertFalse(clean.hadHidden)
        XCTAssertEqual(clean.display, "{\n  \"a\": 1,\n  \"b\": \"two\"\n}")
    }

    /// Characters that hide in a HEADER value — a variation selector from the supplement, which
    /// carries a byte of payload each, and a Hangul filler — are spelled out on the header's own
    /// line, and flagged. Pins that the header lines are not appended to the box
    /// unescaped.
    func testAHeaderLineSpellsOutWhatHides() {
        let held = request(
            document: #"{"account":"X1"}"#,
            outgoing: MCPDynamicTool.OutgoingCall(
                arguments: .object([:]), headerParameters: ["Mcp-Param-Account": "X1\u{E0101}\u{3164}"]))
        XCTAssertTrue(held.argumentsDisplay.hadHidden)
        XCTAssertTrue(held.argumentsDisplay.display.hasSuffix("\nMcp-Param-Account: \"X1\\u{E0101}\\u{3164}\""),
                      held.argumentsDisplay.display)
    }

    /// A header line cannot be faked by a soft wrap: its value is a JSON string, so a value of
    /// "alex", forty spaces and "Mcp-Param-Locale: en" is ONE line starting `Mcp-Param-` — and a
    /// wrap of it lands visibly inside the quotes. The header NAME is ASCII by construction and
    /// stays bare.
    ///
    /// RED until 2026-10-28: `Name: value` unquoted in a wrapping `Text` drew the value's
    /// tail as a second header line, with no warning.
    func testAHeaderLineCannotBeForgedByAWrap() {
        let value = "alex" + String(repeating: " ", count: 40) + "Mcp-Param-Locale: en"
        let outgoing = MCPDynamicTool.OutgoingCall(
            arguments: .object(["account": .string(value)]), headerParameters: ["Mcp-Param-Account": value])
        let text = MCPApprovalRequest.argumentsText(of: outgoing)
        let headerLines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("Mcp-Param-") }
        XCTAssertEqual(headerLines.count, 1, text)
        XCTAssertEqual(headerLines.first.map(String.init), "Mcp-Param-Account: \"\(value)\"", "its value quoted")
        XCTAssertFalse(request(document: "{}", outgoing: outgoing).argumentsDisplay.hadHidden, "spaces hide nothing")
    }

    /// The MCP card's standing grant carries what it covers as its tooltip — read through the
    /// value the card builds its button row from — and offers none when the request offers none.
    ///
    /// Pins that the grant carries its tooltip with its neighbours in `ApprovalActionRowTests`.
    func testTheMCPCardsGrantCarriesWhatItCoversAsItsTooltip() {
        let grant = MCPApprovalCardText.grant(offerAlways: true)
        XCTAssertEqual(grant, ApprovalGrant(label: "Always allow", help: MCPApprovalCardText.alwaysAllowHelp))
        XCTAssertEqual(grant.map { ApprovalActionRow<EmptyView>.tooltip(label: $0.label, help: $0.help) },
                       MCPApprovalCardText.alwaysAllowHelp)
        XCTAssertNil(MCPApprovalCardText.grant(offerAlways: false))
    }

    /// A tool of a LEGACY-era server that declares a header parameter: that era has no header
    /// channel, so the argument travels in the body — and the card shows it there, with no
    /// headers section. A call whose only argument is that parameter still sends something.
    ///
    /// RED until 2026-10-28: the card said the value went as a request header, and a
    /// header-only call's body read `{}` — while the legacy transport sent the value nowhere.
    func testALegacyEraCardShowsAHeaderParameterInTheBody() throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let entry = MCPToolsSnapshot.Entry(
            serverID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!,
            slug: MCPServerSlug("folio")!, serverDisplayName: "Folio Desktop", approvalMode: .manual,
            serverTrusted: false, alwaysAllowed: false, runsUnattended: false,
            descriptor: MCPToolDescriptor(
                originalName: "get_screenshot", modelFacingName: "mcp__folio__get_screenshot",
                displayDescription: "d", inputSchema: JSONSchema.object(properties: ["account": JSONSchema.string()]),
                outputSchema: nil, annotations: .specDefaults, headerParams: [account], callShapeDependsOnEra: true, pinHash: "hash",
                rawTool: .object([:]), strippedHiddenCharacters: false),
            era: .legacy)
        for (document, body) in [
            (#"{"account":"X1","node":"1:2"}"#, "{\n  \"account\": \"X1\",\n  \"node\": \"1:2\"\n}"),
            (#"{"account":"X1"}"#, "{\n  \"account\": \"X1\"\n}"),
        ] {
            guard case .sends(let outgoing) = MCPDynamicTool.preflight(
                argumentsJSON: document, toolName: "mcp__folio__get_screenshot", entry: entry)
            else { XCTFail(document); continue }
            let held = request(document: document, outgoing: outgoing)
            XCTAssertEqual(held.argumentsDisplay.display, body, document)
            XCTAssertFalse(held.argumentsDisplay.display.contains(MCPApprovalRequest.headerParametersHeading), document)
            XCTAssertFalse(held.hasNoArguments, document)
        }
    }

    private var recorder: LayoutProbeRecorder!

    /// The card's own frame and each of its buttons', as the feed lays the card out in a column
    /// `width` points wide.
    private func cardLayout(_ held: MCPApprovalRequest, width: CGFloat) async -> [String: CGRect] {
        store = TestOrchestrator.make()
        store.mcpApprovalDidBegin(held)
        recorder = LayoutProbeRecorder()
        let feed = VStack(alignment: .leading, spacing: 0) {
            MCPApprovalCardList(taskID: 1, roleDefinitions: [])
                .layoutProbe("card")
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
        .environment(store)
        return await recorder.layOut(feed, windowWidth: width + 200, awaiting: ["card", "approval-action:Allow"])
    }

    /// The whole card — Manual (Allow, Deny) and Semi-automatic (and Always allow) — at 320 points
    /// and at 184, the 200-point column less the card's padding: the card is no wider than the
    /// column, every button is inside it, and every button is laid out at its own size — no
    /// taller than alone (a label that broke inside its brackets is about twice as tall) and no
    /// narrower (a label cut short).
    ///
    /// RED until 2026-10-28: one `HStack` with no fallback — the buttons were squeezed, and
    /// at 216 points "[ Allow ]" broke into "Allo / w". The grant's label is
    /// "Always allow" since: "Always allow this tool" needs 234 points alone, wider than the 168
    /// a 184-point card has for it.
    func testTheCardsButtonsFitTheColumnWithoutBreakingALabel() async throws {
        let always = MCPApprovalCardText.alwaysAllowLabel
        XCTAssertEqual(always, "Always allow")
        for (offerAlways, labels) in [(false, ["Allow", "Deny"]), (true, ["Allow", "Deny", always])] {
            let alone = try await aloneButtonSizes(labels)
            for width: CGFloat in [320, WindowLayout.teamBoardActivityMinWidth - 2 * Spacing.s] {
                let frames = await cardLayout(request(offerAlways: offerAlways), width: width)
                let card = try XCTUnwrap(frames["card"], "the card was laid out at \(width)")
                XCTAssertLessThanOrEqual(card.width, width + 0.5, "the card is \(card.width) pt in \(width)")
                for label in labels {
                    let button = try XCTUnwrap(frames["approval-action:\(label)"], "\(label) at \(width)")
                    let own = try XCTUnwrap(alone[label])
                    XCTAssertLessThanOrEqual(button.height, own.height + 0.5,
                                             "\(label) at \(width): \(button.height) pt tall, \(own.height) alone — its label broke")
                    XCTAssertGreaterThanOrEqual(button.width, own.width - 0.5,
                                                "\(label) at \(width): \(button.width) pt wide, \(own.width) alone — its label was cut")
                    XCTAssertGreaterThanOrEqual(button.minX, card.minX - 0.5, "\(label) at \(width) starts outside the card")
                    XCTAssertLessThanOrEqual(button.maxX, card.maxX + 0.5, "\(label) at \(width) ends outside the card")
                }
            }
        }
    }

    /// The row falls back one arrangement at a time, as the column narrows: all three on one row
    /// where they fit (600 points); Allow and Deny on one row and the grant below (320); one
    /// button per line (184).
    func testTheButtonRowFallsBackOneArrangementAtATime() async throws {
        let always = "approval-action:\(MCPApprovalCardText.alwaysAllowLabel)"
        func rows(at width: CGFloat) async throws -> (allow: CGRect, deny: CGRect, always: CGRect) {
            let frames = await cardLayout(request(offerAlways: true), width: width)
            return (try XCTUnwrap(frames["approval-action:Allow"]), try XCTUnwrap(frames["approval-action:Deny"]),
                    try XCTUnwrap(frames[always]))
        }
        let wide = try await rows(at: 600)
        XCTAssertEqual(wide.allow.minY, wide.deny.minY, accuracy: 0.5)
        XCTAssertEqual(wide.allow.minY, wide.always.minY, accuracy: 0.5, "at 600 all three share a row")

        let mid = try await rows(at: 320)
        XCTAssertEqual(mid.allow.minY, mid.deny.minY, accuracy: 0.5, "at 320 Allow and Deny share a row")
        XCTAssertGreaterThanOrEqual(mid.always.minY, mid.allow.maxY, "and the grant goes below them")

        let narrow = try await rows(at: WindowLayout.teamBoardActivityMinWidth - 2 * Spacing.s)
        XCTAssertGreaterThanOrEqual(narrow.deny.minY, narrow.allow.maxY, "at 184 one button per line")
        XCTAssertGreaterThanOrEqual(narrow.always.minY, narrow.deny.maxY)
    }

    /// Each approval button laid out alone, at its own size — the very button the row draws.
    private func aloneButtonSizes(_ labels: [String]) async throws -> [String: CGSize] {
        typealias Row = ApprovalActionRow<EmptyView>
        var sizes: [String: CGSize] = [:]
        for label in labels {
            let kind: Row.Kind = label == Row.allowLabel ? .allow : label == Row.denyLabel ? .deny : .always
            sizes[label] = try await idealSize(of: Row.button(label, kind: kind) {})
        }
        return sizes
    }

    /// The claimed row's items sit on one text baseline, as the `HStack(alignment:
    /// .firstTextBaseline)` it replaced had them: the note's baseline is the last chip's, and a
    /// caution badge — with its glyph — shares a line's baseline with a neutral tag. Hosted at
    /// 320 points, each baseline read as where the view was placed plus its own baseline laid
    /// out alone.
    ///
    /// Pins that the lines are not top-aligned, which the size-only tests could
    /// not see: only renders showed it.
    func testTheClaimedChipsAndTheNoteShareOneBaseline() async throws {
        let chips = MCPToolAnnotations(raw: .object([
            "readOnlyHint": .bool(false), "idempotentHint": .bool(true),
        ])).chips
        let claimed = chips.claimed
        XCTAssertEqual(Set(claimed.map(\.tone)), [.caution, .neutral], "premise: a caution badge beside a neutral tag")
        let note = MCPApprovalRequest.serversOwnClaimNote
        recorder = LayoutProbeRecorder()
        let row = HStack(spacing: 0) {
            MCPAnnotationChipsView(chips: chips, claimNote: note)
            Spacer(minLength: 0)
        }
        .frame(width: 320, alignment: .leading)
        let ids = claimed.map { "chip:\($0.id)" } + ["chip-note"]
        let frames = await recorder.layOut(row, windowWidth: 420, height: 300, awaiting: ids)

        var baselines: [String: CGFloat] = [:]
        for chip in claimed {
            let frame = try XCTUnwrap(frames["chip:\(chip.id)"], chip.label)
            baselines["chip:\(chip.id)"] = frame.minY + (try await firstBaselineOffset(of: MCPAnnotationChipsView.badge(for: chip)))
        }
        let noteFrame = try XCTUnwrap(frames["chip-note"], "the note was laid out")
        baselines["chip-note"] = noteFrame.minY + (try await firstBaselineOffset(of: MCPAnnotationChipsView.noteText(note)))

        let chipFrames = try claimed.map { try XCTUnwrap(frames["chip:\($0.id)"]) }
        XCTAssertLessThan(abs(chipFrames[0].midY - chipFrames[1].midY), max(chipFrames[0].height, chipFrames[1].height),
                          "premise: the two chips share a line at 320")
        let lastID = "chip:\(try XCTUnwrap(claimed.last).id)"
        XCTAssertEqual(try XCTUnwrap(baselines["chip-note"]), try XCTUnwrap(baselines[lastID]), accuracy: 0.5,
                       "the note sits on the last chip's baseline")
        let caution = try XCTUnwrap(claimed.first { $0.tone == .caution })
        let neutral = try XCTUnwrap(claimed.first { $0.tone == .neutral })
        XCTAssertEqual(try XCTUnwrap(baselines["chip:\(caution.id)"]), try XCTUnwrap(baselines["chip:\(neutral.id)"]),
                       accuracy: 0.5, "a caution badge and a neutral tag on one line share its baseline")
    }

    /// The header names the tool once, by the server's own title for it; the model-facing
    /// `mcp__…` name is not repeated in the chips row.
    func testTheHeadlineNamesTheToolOnce() {
        let held = request(toolName: "mcp__folio__get_screenshot", toolTitle: "Get screenshot")
        let headline = MCPApprovalCardText.headline(roleName: "Engineer", request: held)
        XCTAssertEqual(headline, "Engineer wants to call Get screenshot on Folio Desktop")
        XCTAssertFalse(headline.contains("mcp__"))
    }

    // MARK: - The banner

    private func run(stepID: String = "step_1") -> (Run, NTMSTask) {
        var run = Run(id: 0, teamID: "test_team")
        run.steps = [StepExecution(
            id: stepID, role: .softwareEngineer, title: "Test Step", status: .running,
            needsSupervisorInput: false)]
        return (run, NTMSTask(id: 1, title: "T", supervisorTask: "do", runs: [run]))
    }

    /// The hold keeps the step `.running`, so nothing else in the producer surfaces it — the
    /// parameter is the only path.
    func testAHeldCallSurfacesAsItsOwnNotification() {
        let (run, task) = run()

        let notifications = run.allWatchtowerNotifications(
            task: task, teamRoles: [], mcpApprovals: [request()])

        guard case .mcpApprovalNeeded(let stepID, let taskID, let tool, let server, let role, _)
            = notifications.first
        else { return XCTFail("expected an mcpApprovalNeeded notification") }
        XCTAssertEqual(stepID, "step_1")
        XCTAssertEqual(taskID, 1)
        XCTAssertEqual(tool, "Get screenshot")
        XCTAssertEqual(server, "Folio Desktop")
        XCTAssertEqual(role, .softwareEngineer, "role resolved from the holding step")
    }

    func testARequestForAnotherTaskDoesNotSurfaceHere() {
        let (run, task) = run()

        XCTAssertTrue(run.allWatchtowerNotifications(
            task: task, teamRoles: [], mcpApprovals: [request(taskID: 999)]).isEmpty)
    }

    func testWithNoHeldCallsNothingIsProduced() {
        let (run, task) = run()

        XCTAssertTrue(run.allWatchtowerNotifications(task: task, teamRoles: []).isEmpty)
    }

    /// The banner points; it does not decide. An inline action would be a decision taken
    /// without the arguments on screen.
    func testTheBannerIsAPointerNotAnActionSurface() {
        let notification = WatchtowerNotificationType.mcpApprovalNeeded(
            stepID: "step_1", taskID: 1, toolName: "Get screenshot",
            serverName: "Folio Desktop", role: .softwareEngineer,
            createdAt: Date(timeIntervalSince1970: 100))

        XCTAssertFalse(notification.requiresAction)
        XCTAssertTrue(notification.needsAttention)
        XCTAssertEqual(
            notification.title(isChatMode: false),
            "Software Engineer wants to call Get screenshot on Folio Desktop")
    }

    /// `createdAt` discriminates hold instances, so a dismissal of one hold cannot suppress
    /// the next one. The call key is deliberately NOT used: it carries the raw arguments
    /// document and a control character.
    func testTheDismissIDIsPerHoldAndCarriesNoArguments() {
        func dismissID(at seconds: TimeInterval) -> String {
            WatchtowerNotificationType.mcpApprovalNeeded(
                stepID: "step_1", taskID: 1, toolName: "t", serverName: "s",
                role: .softwareEngineer, createdAt: Date(timeIntervalSince1970: seconds)
            ).dismissID
        }

        XCTAssertNotEqual(dismissID(at: 100), dismissID(at: 200))
        XCTAssertTrue(dismissID(at: 100).hasPrefix("mcp::1::step_1::"))
        XCTAssertFalse(dismissID(at: 100).contains("{"))
        XCTAssertFalse(dismissID(at: 100).contains("\u{1}"))
    }

    /// Both families are produced by one pass, so a task holding a command and a tool call
    /// shows both banners rather than one hiding the other.
    func testAHeldCommandAndAHeldCallBothSurface() {
        let (run, task) = run()
        let command = BashApprovalRequest(
            taskID: 1, stepID: "step_1", commandKey: "k", command: "ls",
            workingDirectory: nil, offerAlways: false,
            createdAt: Date(timeIntervalSince1970: 50))

        let notifications = run.allWatchtowerNotifications(
            task: task, teamRoles: [], bashApprovals: [command], mcpApprovals: [request()])

        XCTAssertEqual(notifications.count, 2)
    }

    // MARK: - Cross-server transfer banner on the approval card (D-M4)

    /// When a call is held because the step already contacted another MCP server, the request
    /// carries the cross-server transfer note naming both servers and never offers "Always allow".
    func testACrossServerHoldCarriesTheTransferNoteAndOffersNoStandingGrant() throws {
        let outgoing = try XCTUnwrap(Self.preflight(#"{"nodeId":"1:2"}"#))
        let crossServer = MCPApprovalRequest(
            taskID: 1,
            stepID: "step_1",
            callKey: LLMExecutionService.mcpCallKey(
                toolName: "mcp__github__create_issue", argumentsJSON: #"{"nodeId":"1:2"}"#),
            toolName: "mcp__github__create_issue",
            serverSlug: "github",
            serverDisplayName: "GitHub",
            toolTitle: "Create issue",
            toolDescription: "Opens an issue.",
            outgoing: outgoing,
            annotations: .specDefaults,
            serverTrusted: true,
            pinHash: "hash",
            offerAlways: false,
            priorServerNames: ["Folio Desktop"],
            createdAt: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(
            crossServer.crossServerTransferNote,
            "This step already read from Folio Desktop. Approving sends the arguments below to GitHub.")
        XCTAssertFalse(crossServer.offerAlways)
        XCTAssertNil(request().crossServerTransferNote)
    }

    // MARK: - On-demand "Ask AI" button on the MCP approval card (D-M14)

    /// The MCP approval card draws the "Ask AI" button inside the card at both 320 pt and 184 pt.
    func testTheMCPCardDrawsAskAIBesideAllowAndDeny() async throws {
        for offerAlways in [false, true] {
            for width: CGFloat in [320, WindowLayout.teamBoardActivityMinWidth - 2 * Spacing.s] {
                let frames = await cardLayout(request(offerAlways: offerAlways), width: width)
                let card = try XCTUnwrap(frames["card"], "the card was laid out at \(width)")
                let askAI = try XCTUnwrap(
                    frames["approval-action:Ask AI"],
                    "Ask AI button must be drawn on MCPApprovalCard (offerAlways=\(offerAlways), width=\(width))")
                XCTAssertGreaterThanOrEqual(askAI.minX, card.minX - 0.5)
                XCTAssertLessThanOrEqual(askAI.maxX, card.maxX + 0.5)
            }
        }
    }
}

/// Where the feed-layout fixture reports the card list's height.
@MainActor
private final class CardHeightProbe {
    var height: CGFloat = 0
}

/// Where the chips-layout fixture reports the chips view's size.
@MainActor
private final class ChipsSizeProbe {
    var size: CGSize?
    var badges: [MCPAnnotationChips.Chip.ID: CGSize] = [:]
}
