import AppKit
import SwiftUI
import XCTest
@testable import NanoTeams

/// `TerminalChipToggleStyle` — the design system's label-as-a-chip toggle.
///
/// Its label is 10pt micro type (`Typography.term2xs`), and 10pt type never wraps
/// (`MicroTypeNeverWrapsPinTests`): a chip is one short run of characters. That pin reads
/// `Text` modifier chains in the source, and a chip's label is the caller's `Toggle` title —
/// so the style itself has to refuse the second line, and only a layout can show it does.
@MainActor
final class TerminalChipToggleStyleTests: XCTestCase {

    private var window: NSWindow?
    private var probe: ChipSizeProbe!

    override func tearDown() async throws {
        window?.close()
        window = nil
        probe = nil
        try await super.tearDown()
    }

    /// The chip's laid-out size in a row offering it `width` points, hosted offscreen.
    private func chipSize(_ label: String, offered width: CGFloat) async throws -> CGSize {
        probe = ChipSizeProbe()
        let probe = try XCTUnwrap(probe)
        let row = HStack(spacing: 0) {
            Toggle(label, isOn: .constant(false))
                .toggleStyle(.terminalChip)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { probe.size = $0 }
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
        let host = NSHostingView(rootView: row)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
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
        return try XCTUnwrap(probe.size, "the chip was laid out")
    }

    /// Offered less than its one line, the chip keeps that line — the whole label, at the height
    /// it has with room to spare — rather than folding "Always allow" into "Always / allow".
    ///
    /// RED until 2026-10-28: on the MCP server page at the Settings window's minimum width the
    /// Always allow chip beside an approved tool wrapped onto two lines.
    func testAChipKeepsItsLabelOnOneLineWhenTheRowOffersLess() async throws {
        let roomy = try await chipSize("Always allow", offered: 400)
        let squeezed = try await chipSize("Always allow", offered: 40)

        XCTAssertGreaterThan(roomy.width, 40, "premise: the label needs more than the squeezed row offers")
        XCTAssertEqual(squeezed.height, roomy.height, accuracy: 0.5, "one line, however little room")
        XCTAssertEqual(squeezed.width, roomy.width, accuracy: 0.5, "the whole label")
    }

    /// The size the style fixes keeps a label from being NARROWED onto two lines; the line
    /// limit is what keeps a label that carries its own line break on one. A chip is one line
    /// whatever its label holds — so the label is cut, not stacked.
    ///
    /// RED until 2026-10-28: the limit read as redundant under `.fixedSize()`,
    /// and dropping it passed every test — no label with a break in it had been laid out.
    func testAChipWhoseLabelCarriesALineBreakStaysOneLine() async throws {
        let plain = try await chipSize("Always allow", offered: 400)
        let broken = try await chipSize("Always\nallow", offered: 400)

        XCTAssertEqual(broken.height, plain.height, accuracy: 0.5, "one line, whatever the label carries")
    }
}

/// The size a hosted chip last reported.
@MainActor
private final class ChipSizeProbe {
    var size: CGSize?
}
