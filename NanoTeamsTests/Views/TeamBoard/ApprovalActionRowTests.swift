import AppKit
import SwiftUI
import XCTest
@testable import NanoTeams

/// The Allow / Deny / Always row of the three approval cards the feed draws — `bash`, computer
/// use and MCP — in the chat column, which can be 200 points wide. The MCP card's own test is
/// `MCPApprovalSurfaceTests.testTheCardsButtonsFitTheColumnWithoutBreakingALabel`; these are the
/// same test for the other two cards, which drew the same fixed row.
@MainActor
final class ApprovalActionRowTests: XCTestCase {

    private typealias Row = ApprovalActionRow<EmptyView>

    private var store: NTMSOrchestrator!
    private var recorder: LayoutProbeRecorder!

    override func tearDown() async throws {
        store = nil
        recorder = nil
        LayoutProbe.record = nil
        try await super.tearDown()
    }

    /// The column widths a card is laid out in: 320 points, and the chat column's minimum less
    /// the card's padding.
    private static let widths: [CGFloat] = [320, WindowLayout.teamBoardActivityMinWidth - 2 * Spacing.s]

    /// Lays `cards` out in a column `width` wide and returns every probed frame: the card's
    /// (`"card"`) and each button's.
    private func layOut<Cards: View>(_ cards: Cards, width: CGFloat) async -> [String: CGRect] {
        recorder = LayoutProbeRecorder()
        let feed = VStack(alignment: .leading, spacing: 0) {
            cards.layoutProbe("card")
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
        .environment(store)
        return await recorder.layOut(feed, windowWidth: width + 200, awaiting: ["card", "approval-action:Allow"])
    }

    /// Every button inside the card, and no taller than it is alone — a label that broke inside
    /// its brackets is about twice as tall. `mayTruncate` names the labels allowed to be cut short
    /// rather than broken when they are wider than the column on their own line.
    private func assertButtons(
        _ frames: [String: CGRect], alone: [String: CGSize], width: CGFloat, mayTruncate: Set<String> = [],
        extra: [String] = [], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let card = try XCTUnwrap(frames["card"], "the card was laid out at \(width)", file: file, line: line)
        XCTAssertLessThanOrEqual(card.width, width + 0.5, "the card is \(card.width) pt in \(width)", file: file, line: line)
        for (label, own) in alone {
            let button = try XCTUnwrap(frames["approval-action:\(label)"], "\(label) at \(width)", file: file, line: line)
            XCTAssertLessThanOrEqual(button.height, own.height + 0.5,
                                     "\(label) at \(width): \(button.height) pt tall, \(own.height) alone — its label broke",
                                     file: file, line: line)
            if !mayTruncate.contains(label) {
                XCTAssertGreaterThanOrEqual(button.width, own.width - 0.5,
                                            "\(label) at \(width): \(button.width) pt wide, \(own.width) alone",
                                            file: file, line: line)
            }
            XCTAssertGreaterThanOrEqual(button.minX, card.minX - 0.5, "\(label) at \(width) starts outside the card",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(button.maxX, card.maxX + 0.5, "\(label) at \(width) ends outside the card",
                                     file: file, line: line)
        }
        for id in extra {
            let frame = try XCTUnwrap(frames["approval-action:\(id)"], "\(id) at \(width)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, card.minX - 0.5, "\(id) at \(width) starts outside the card",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, card.maxX + 0.5, "\(id) at \(width) ends outside the card",
                                     file: file, line: line)
        }
    }

    /// The `bash` card — Allow, Deny, Always allow, and the "Ask AI" second opinion — fits the
    /// column: no button's label breaks, none is cut, and none is drawn outside the card.
    ///
    /// RED until 2026-10-28: the row was one `HStack` beside a fixed-size "Ask AI".
    func testTheBashCardsButtonsFitTheColumn() async throws {
        store = TestOrchestrator.make()
        store.bashApprovalDidBegin(BashApprovalRequest(
            taskID: 1, stepID: "step_1", commandKey: "k", command: "git status", workingDirectory: nil,
            offerAlways: true, createdAt: Date(timeIntervalSince1970: 100)))
        let alone: [String: CGSize] = [
            "Allow": try await idealSize(of: Row.button("Allow", kind: .allow) {}),
            "Deny": try await idealSize(of: Row.button("Deny", kind: .deny) {}),
            "Always allow": try await idealSize(of: Row.button("Always allow", kind: .always) {}),
        ]
        for width in Self.widths {
            let frames = await layOut(BashApprovalCardList(taskID: 1, roleDefinitions: []), width: width)
            try assertButtons(frames, alone: alone, width: width, extra: ["Ask AI"])
        }
    }

    /// The computer-use card — Allow, Deny, "Always allow in <app>" — fits the column: no label
    /// breaks and no button is drawn outside the card. An app's name can make the third label
    /// wider than the narrowest column on a line of its own; it is then cut short, never broken.
    ///
    /// RED until 2026-10-28: the row was one `HStack`.
    func testTheComputerUseCardsButtonsFitTheColumn() async throws {
        store = TestOrchestrator.make()
        store.computerUseApprovalDidBegin(ComputerUseApprovalRequest(
            taskID: 1, stepID: "step_1", actionKey: "k", actionSummary: "click at (10, 20)", targetApp: "Finder",
            offerAlways: true, screenshotBase64: nil, targetX: nil, targetY: nil,
            createdAt: Date(timeIntervalSince1970: 100)))
        let always = "Always allow in Finder"
        let alone: [String: CGSize] = [
            "Allow": try await idealSize(of: Row.button("Allow", kind: .allow) {}),
            "Deny": try await idealSize(of: Row.button("Deny", kind: .deny) {}),
            always: try await idealSize(of: Row.button(always, kind: .always) {}),
        ]
        for width in Self.widths {
            let frames = await layOut(ComputerUseApprovalCardList(taskID: 1, roleDefinitions: []), width: width)
            try assertButtons(frames, alone: alone, width: width, mayTruncate: [always])
        }
    }

    /// A decision button's tooltip is what it grants when the card says so, and its own label
    /// otherwise — the tested value `button(_:kind:help:)` reads, since a hosted view exposes no
    /// tooltip to a test.
    ///
    /// Pins that `help ?? label` does not collapse to `label`.
    func testATooltipIsTheHelpWhenGivenAndTheLabelOtherwise() {
        XCTAssertEqual(Row.tooltip(label: "Allow", help: nil), "Allow")
        XCTAssertEqual(Row.tooltip(label: "Always allow", help: "Always allow this tool"), "Always allow this tool")
        XCTAssertEqual(ApprovalGrant(label: "Always allow in Finder").help, nil, "a grant with no help reads its label")
    }

    /// A tooltip as the row DRAWS it, beside the label of the button it is drawn on.
    private struct DrawnTooltip: Hashable {
        let label: String
        let tooltip: String
    }

    /// Every string stored anywhere in `value`.
    private static func strings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        return Mirror(reflecting: value).children.flatMap { strings(in: $0.value) }
    }

    /// Every tooltip `view` draws, read off the view value: `.help` wraps its button in SwiftUI's
    /// `HelpView`, whose `content` holds the button — and so its label — and whose other stored
    /// value is the tooltip. The value is where a drawn tooltip can be read: a hosted view exposes
    /// no accessibility child and no tooltip to a test (probed 2026-10-28: an `NSHostingView`'s
    /// accessibility children are empty), and `MCPServersSettingsViewTests` reads a pane's
    /// `content` the same way.
    private static func drawnTooltips(in view: Any) -> Set<DrawnTooltip> {
        let mirror = Mirror(reflecting: view)
        guard String(describing: mirror.subjectType).hasPrefix("HelpView<") else {
            return mirror.children.reduce(into: []) { $0.formUnion(drawnTooltips(in: $1.value)) }
        }
        let content = mirror.children.first { $0.label == "content" }?.value
        let tooltip = mirror.children.filter { $0.label != "content" }.flatMap { strings(in: $0.value) }
        var found: Set<DrawnTooltip> = [DrawnTooltip(
            label: content.map { strings(in: $0).joined(separator: " ") } ?? "",
            tooltip: tooltip.joined(separator: " "))]
        if let content { found.formUnion(drawnTooltips(in: content)) }
        return found
    }

    /// Each button of the row DRAWS the tooltip the tested value gives: the grant's help on the
    /// grant's button, its own label on each other one — in every arrangement the row may take.
    ///
    /// RED until 2026-10-28: only the value was pinned (the test above), and a button
    /// drawing `.help(label)` passed every class, as would a row
    /// handing the grant's button no help.
    func testEachButtonDrawsTheTooltipTheValueGives() {
        let row = Row(grant: ApprovalGrant(label: "Always allow", help: "Always allow this tool"),
                      onAllow: {}, onDeny: {}, onAlways: {})
        XCTAssertEqual(Self.drawnTooltips(in: row.body), [
            DrawnTooltip(label: "Allow", tooltip: "Allow"),
            DrawnTooltip(label: "Deny", tooltip: "Deny"),
            DrawnTooltip(label: "Always allow", tooltip: "Always allow this tool"),
        ])
        let noGrant = Row(grant: nil, onAllow: {}, onDeny: {}, onAlways: {})
        XCTAssertEqual(Self.drawnTooltips(in: noGrant.body), [
            DrawnTooltip(label: "Allow", tooltip: "Allow"),
            DrawnTooltip(label: "Deny", tooltip: "Deny"),
        ])
    }
}
