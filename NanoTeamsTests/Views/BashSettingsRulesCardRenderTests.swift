import AppKit
import SwiftUI
import XCTest

@testable import NanoTeams

/// What the Rules card of `BashSettingsView` DRAWS — read off the rendered view's accessibility
/// tree, not off the property it is built from (E1 review R6, 2026-11-12).
///
/// `BashSettingsVisibilityTests/testRulesHelp_isShownWithItsMarkdownRendered` reads the static
/// `rulesHelp` and stayed green under the mutation that brings back the A5 defect: the card
/// drawing `Text(Self.rulesHelpText)` — `Text(String)`, which shows the backticks and the `**`
/// literally. This test hosts the whole settings view with the custom-rules disclosure open and
/// reads the text the card put on screen.
///
/// RED under that mutation (run 2026-11-12 in the mcp-w2 worktree: the help read with its
/// backticks and asterisks), green on the card as written.
@MainActor
final class BashSettingsRulesCardRenderTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var configuration: StoreConfiguration!
    private var catalog: ModelCatalog!
    private var window: NSWindow!

    override func tearDown() async throws {
        window?.close()
        window = nil
        catalog = nil
        configuration = nil
        try await super.tearDown()
    }

    /// Every string the hosted view exposes to accessibility — labels and values, depth first.
    /// SwiftUI's nodes (`AccessibilityNode`) do not adopt `NSAccessibilityProtocol` in Swift's
    /// eyes, so each is asked by selector.
    private func accessibleTexts(of root: NSView) -> [String] {
        func ask(_ object: NSObject, _ selector: Selector) -> Any? {
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        var texts: [String] = []
        var stack: [Any] = [root]
        var visited = 0
        while let item = stack.popLast(), visited < 20_000 {
            visited += 1
            guard let object = item as? NSObject else { continue }
            for selector in [#selector(NSAccessibilityProtocol.accessibilityLabel),
                             #selector(NSAccessibilityProtocol.accessibilityValue)] {
                switch ask(object, selector) {
                case let text as String where !text.isEmpty: texts.append(text)
                case let text as NSAttributedString where text.length > 0: texts.append(text.string)
                default: break
                }
            }
            stack.append(contentsOf: ask(object, #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [Any] ?? [])
        }
        return texts
    }

    /// SwiftUI builds a hosting view's accessibility tree only once some client has asked the
    /// process anything over the AX API; until then the view has no children. Measured
    /// 2026-11-12 in this test host: the same view exposed nothing before this call and every
    /// `Text` after it. The call's own result (the attribute is not settable) does not matter.
    private func wakeAccessibility() {
        _ = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(getpid()), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private func renderedTexts(mode: BashExecutionMode, rulesExpanded: Bool) async throws -> [String] {
        configuration = StoreConfiguration(storage: InMemoryConfigurationStorage())
        configuration.bashMode = mode
        catalog = ModelCatalog()
        let view = BashSettingsView(customRulesExpanded: rulesExpanded)
            .environment(try XCTUnwrap(configuration))
            .environment(try XCTUnwrap(sut))
            .environment(try XCTUnwrap(catalog))
            .frame(width: 620, height: 2_400)
        let host = NSHostingView(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 2_400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        wakeAccessibility()
        var texts: [String] = []
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            texts = accessibleTexts(of: host)
            if texts.contains(where: { $0.contains("Each rule is a command pattern") }) { break }
        }
        return texts
    }

    /// The help the card draws has its Markdown rendered: no backtick and no `**` on screen, the
    /// code spans read as their words.
    func testRulesCard_drawsTheHelpWithItsMarkdownRendered() async throws {
        let texts = try await renderedTexts(mode: .manual, rulesExpanded: true)
        let help = try XCTUnwrap(
            texts.first { $0.contains("Each rule is a command pattern") },
            "anti-vacuum: the open Rules card puts its help on screen — \(texts.prefix(40))")
        XCTAssertFalse(help.contains("`"), help)
        XCTAssertFalse(help.contains("**"), help)
        XCTAssertTrue(help.contains("rm matches rm -rf x"), help)
        XCTAssertTrue(help.contains("Precedence: deny → ask → allow."), help)
    }

    /// The help is behind its disclosure: closed, nothing of it is drawn — so the test above reads
    /// the card it opened, not some other copy of the text.
    func testRulesCard_closed_drawsNoHelp() async throws {
        let texts = try await renderedTexts(mode: .manual, rulesExpanded: false)
        XCTAssertFalse(texts.isEmpty, "anti-vacuum: the view puts something on screen")
        XCTAssertFalse(texts.contains { $0.contains("Each rule is a command pattern") })
    }
}
