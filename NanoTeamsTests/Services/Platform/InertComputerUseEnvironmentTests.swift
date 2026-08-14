import CoreGraphics
import XCTest

@testable import NanoTeams

/// The inert half of the computer-use seam, and the reason it is the DEFAULT.
///
/// `LLMExecutionService`'s `computerUse` parameter resolves inward: omit it and you get `.inert`.
/// That choice is the only thing standing between a future test that drives a click and a suite
/// that operates the developer's machine — 159 sites construct this service, and the one that
/// forgets will not announce itself. CLAUDE.md §49 records the same shape costing 93 call sites and
/// a fleet of unintended network requests; here the blast radius is real keystrokes.
///
/// So these are not tautology tests over trivial stubs. Each one pins a property someone could
/// "simplify" away in a single line — `hasAccessibility()` to `true`, the throw to a blank
/// screenshot — with no test failing and no symptom until the day a suite starts typing into
/// whatever window happens to be frontmost.
///
/// RED: change `InertInputControl.hasAccessibility()` to return `true` →
/// `testInertInput_reportsNoAccessibility` fails, and so does the composition test below.
final class InertComputerUseEnvironmentTests: XCTestCase {

    // MARK: - Input

    /// The honest answer for a process that cannot synthesize input, and the one that ends in "no
    /// input synthesized": every action arm of the dispatcher refuses when this is false. Answering
    /// `true` instead would let a no-op click report success — the exact defect the permission guard
    /// was added to fix, reintroduced through the back door.
    func testInertInput_reportsNoAccessibility() {
        XCTAssertFalse(InertInputControl().hasAccessibility())
    }

    /// Every synthesizing method is a no-op that cannot be observed. There is nothing to assert
    /// against except "it returned without touching the machine", so the pin is that the calls
    /// exist and are reachable — if one of them ever grows a body, this is where it shows up.
    func testInertInput_synthesizesNothing() {
        let inert = InertInputControl()
        inert.requestAccessibilityIfNeeded()
        inert.click(globalPoint: CGPoint(x: 10, y: 10), button: .left, double: true)
        inert.click(globalPoint: CGPoint(x: 10, y: 10), button: .right, double: false)
        inert.scroll(globalPoint: CGPoint(x: 10, y: 10), dx: 3, dy: -3)
        inert.typeText("this must never reach a keyboard")
    }

    /// Nothing is raised, so the caller's settle wait is skipped and the action applies to whatever
    /// is frontmost — the documented behaviour of an omitted target.
    func testInertInput_resolvesNoApp() {
        XCTAssertFalse(InertInputControl().activateApp(matching: "Safari"))
    }

    /// "Inert" means the OS EFFECT is dropped, not that the decision is. `pressKeys` still parses,
    /// so an unparseable combo still raises — a fake that silently accepted `"cmd+nonsense"` would
    /// hide a real error arm from every test that runs against the default environment.
    func testInertInput_stillRejectsAnUnparseableCombo() {
        XCTAssertNoThrow(try InertInputControl().pressKeys("cmd+s"))
        XCTAssertThrowsError(try InertInputControl().pressKeys("cmd+nonsense")) { error in
            guard case InputControlError.unknownKeyCombo(let combo) = error else {
                return XCTFail("expected .unknownKeyCombo, got \(error)")
            }
            XCTAssertEqual(combo, "cmd+nonsense")
        }
    }

    // MARK: - Screen / AX / frontmost

    /// Refusing, exactly as an ungranted process does — never a blank screenshot, which the agent
    /// would try to click.
    func testInertScreenCapture_refuses() async {
        await XCTAssertThrowsErrorAsync(
            try await InertScreenCapture().capture(
                targetSpec: "screen", windowTitle: nil, ownBundleID: "x")
        ) { error in
            guard case .permissionDenied? = error as? ScreenCaptureError else {
                return XCTFail("expected .permissionDenied, got \(error)")
            }
        }
    }

    /// An empty tree, which `emptyElementsNote` turns into an honest warning rather than a silently
    /// blank element list.
    func testInertAXCollector_returnsAnEmptyTree() async {
        let result = await InertAXElementCollector().collectElements(AXCollectionRequest(
            pid: 1, regionOriginX: 0, regionOriginY: 0, regionWidthPt: 100, regionHeightPt: 100,
            pixelWidth: 100, pixelHeight: 100, matchWindowToRegion: false))

        XCTAssertEqual(result.elements, [])
        XCTAssertEqual(result.totalAfterDedup, 0)
        XCTAssertEqual(result.warnings, [])
    }

    /// A live read here would make a test's answer depend on whichever app the developer happened to
    /// have in front — and would hand the AX walk a real pid.
    func testNoFrontmostProvider_reportsNothing() {
        XCTAssertNil(NoFrontmostApplicationProvider().frontmostApplication())
    }

    // MARK: - Composition

    /// The property all of the above exists to support, asserted end to end: a service built the way
    /// a forgetful test builds it cannot synthesize input, cannot take a screenshot, and says so.
    ///
    /// RED: change the init's `computerUse ?? .inert` to `?? .system` → this test starts consulting
    /// the real Accessibility grant and taking real screenshots.
    @MainActor
    func testServiceBuiltWithoutAnEnvironment_isInert() async {
        let sut = LLMExecutionService(repository: NTMSRepository())

        XCTAssertFalse(sut.computerUse.input.hasAccessibility(),
                       "the default environment must refuse input, not consult the real grant")
        XCTAssertNil(sut.computerUse.frontmost.frontmostApplication())
        XCTAssertNil(sut.computerUse.ownBundleIdentifier)
        XCTAssertEqual(sut.computerUse.activationSettleMilliseconds, 0,
                       "no test should pay a real settle wait it did not ask for")

        var messages: [ChatMessage] = []
        await sut.appendComputerUseResult(
            result: ToolExecutionResult(
                providerID: "call-1", toolName: ToolNames.uiType, argumentsJSON: "{}",
                outputJSON: "", isError: false,
                signal: .computerUse(.typeText(text: "must not be typed", target: nil))),
            toolCallID: UUID(), stepID: "engineer", taskID: 1,
            client: UnreachableChatClient(), config: LLMConfig(), networkLogger: nil,
            conversationMessages: &messages, tracker: nil)

        let envelope = messages.first(where: { $0.role == .tool })?.content ?? ""
        XCTAssertTrue(envelope.contains("\"ok\":false"),
                      "the default environment must report the refusal, not a silent success")
        XCTAssertTrue(envelope.contains("Accessibility"))
    }

    /// And the live environment is named in exactly one production place. A second one is how a
    /// seam quietly becomes optional again.
    func testTheLiveEnvironmentIsNamedOnlyAtTheCompositionRoot() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Platform
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // NanoTeamsTests
            .deletingLastPathComponent()   // repo root
        let sources = repoRoot.appendingPathComponent("NanoTeams")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))

        var sites: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            // Comments are stripped first: the line below is explained by a doc comment that names
            // the very construction it is explaining, and a scan that counted prose would report
            // its own documentation as a second wiring site (CLAUDE.md, source-scan pins).
            let code = body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let comment = line.range(of: "//") else { return String(line) }
                    return String(line[line.startIndex..<comment.lowerBound])
                }
                .joined(separator: "\n")
            let uses = code.components(separatedBy: "computerUse: .system").count - 1
            if uses > 0 { sites.append("\(url.lastPathComponent) ×\(uses)") }
        }

        XCTAssertEqual(sites, ["NTMSOrchestrator.swift ×1"],
                       "the live computer-use environment belongs at the composition root only")
    }
}
