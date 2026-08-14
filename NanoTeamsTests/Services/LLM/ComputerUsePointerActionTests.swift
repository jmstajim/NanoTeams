import CoreGraphics
import XCTest

@testable import NanoTeams

/// The shared click/scroll path of the computer-use finalizer — `runPointerAction`.
///
/// This is the code that decides what the agent is told after it touches the user's machine, and
/// it lived at 23% coverage. Every branch here is a decision about how much the model should
/// TRUST what it just did: whether the click landed on a real element, whether the screenshot
/// those coordinates came from still describes the screen, and whether a miss is worth flagging.
/// Getting any of them wrong doesn't crash — it produces a confident wrong answer and a loop.
///
/// Every test drives the real production path through `_testRunPointerAction`, which injects
/// `perform`. The production closure calls `InputControlService.click` / `.scroll`, which post
/// CGEvents at the developer's actual cursor; a suite that exercised the real closure would move
/// the mouse and click for real, dozens of times. The captures below carry no `appName` /
/// `bundleID` and every `target` is nil, so the activation branch resolves no app: no window
/// raise, no settle sleep, no OS side effect of any kind.
@MainActor
final class ComputerUsePointerActionTests: XCTestCase, @unchecked Sendable {

    private var sut: LLMExecutionService!

    override func setUp() {
        super.setUp()
        // No delegate is wired, so the persistence half of `finalizeToolResult` is inert and only
        // `conversationMessages` records the append. Repository injection is required outright
        // (CLAUDE.md §Strict DIP), and `NTMSRepository()` is the house double for these suites.
        sut = LLMExecutionService(repository: NTMSRepository())
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A 100×100 pt region captured at 100×100 px with its origin at the global top-left, so an
    /// image pixel maps to the identical global point and the coordinate math never obscures
    /// which branch a test is actually exercising.
    /// `nonisolated` is load-bearing — see the note on the same fixture in
    /// `ComputerUseCaptureDeliveryTests`: a default argument inherits the enclosing declaration's
    /// isolation only under Swift 6 language mode (SE-0411), and the mirror's CI builds this
    /// target with `-swift-version 5`.
    nonisolated private static func makeCapture() -> CapturedScreen {
        CapturedScreen(
            pngBase64: "", pixelWidth: 100, pixelHeight: 100,
            regionWidthPt: 100, regionHeightPt: 100, originX: 0, originY: 0,
            targetKind: "display", appName: nil, bundleID: nil,
            windowTitle: nil, displayID: nil, pid: nil)
    }

    /// Not currently used in a default argument, so `nonisolated` is not yet required here — it is
    /// stated so the whole fixtures block obeys one rule and the next `elements: [...] = [element(…)]`
    /// default cannot reintroduce the Swift-5 break.
    nonisolated private static func element(
        role: String = "AXButton", label: String,
        x: Int, y: Int, w: Int, h: Int, web: Bool = false
    ) -> AXElementInfo {
        AXElementInfo(role: role, label: label, x: x, y: y, w: w, h: h,
                      cx: x + w / 2, cy: y + h / 2, web: web)
    }

    private struct Run {
        let performed: Bool
        let envelope: String
        /// Decoded once so a test can assert on structure rather than substrings where the
        /// distinction matters (`data.element_at_point` vs `meta.warnings`).
        let json: [String: Any]

        var ok: Bool { json["ok"] as? Bool ?? false }
        var data: [String: Any] { json["data"] as? [String: Any] ?? [:] }
        var warnings: [String] { (json["meta"] as? [String: Any])?["warnings"] as? [String] ?? [] }
        var errorCode: String? {
            ((json["error"] as? [String: Any])?["code"]) as? String
        }
        var elementAtPoint: String? { data["element_at_point"] as? String }
    }

    private func run(
        x: Int, y: Int,
        warnOnMiss: Bool = true,
        capture: CapturedScreen? = makeCapture(),
        elements: [AXElementInfo] = [],
        actionsSinceCapture: Int = 0,
        detail: String = "Clicked."
    ) async -> Run {
        var performed = false
        var messages: [ChatMessage] = []
        await sut._testRunPointerAction(
            x: x, y: y, target: nil, warnOnMiss: warnOnMiss,
            stepID: "role-1", taskID: 1,
            capture: capture, elements: elements, actionsSinceCapture: actionsSinceCapture,
            conversationMessages: &messages,
            perform: { _ in performed = true; return detail })

        let envelope = messages.first(where: { $0.role == .tool })?.content ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(envelope.utf8))) as? [String: Any] ?? [:]
        return Run(performed: performed, envelope: envelope, json: json)
    }

    // MARK: - Preconditions: the action must not run at all

    /// Clicking before any `screen_capture` has no coordinate space to resolve against. The
    /// envelope has to say *which* call is missing, or a weak model retries the click with
    /// tweaked coordinates forever — the failure is in the sequence, not the arguments.
    func testNoCaptureYet_refusesAndNamesTheMissingCall() async {
        let result = await run(x: 10, y: 10, capture: nil)

        XCTAssertFalse(result.performed, "no capture ⇒ no coordinate space ⇒ nothing to click")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.errorCode, ToolErrorCode.computerUseDenied.rawValue)
        XCTAssertTrue(result.envelope.contains("screen_capture"),
                      "the model must be told which call it skipped: \(result.envelope)")
    }

    /// Out-of-bounds is rejected rather than clamped: a clamped click lands on a real pixel the
    /// model never saw — quite possibly on another display — and reports success.
    func testCoordinateOutsideTheScreenshot_isRejectedNotClamped() async {
        let result = await run(x: 100, y: 10)

        XCTAssertFalse(result.performed)
        XCTAssertEqual(result.errorCode, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertTrue(result.envelope.contains("100×100"),
                      "the message must state the bounds it was measured against")
    }

    /// Bounds are half-open — `pixelWidth` is one past the last column. This pins the boundary
    /// from both sides in one test, so an off-by-one in either direction fails exactly here.
    func testBoundsAreHalfOpen_lastPixelIsInsideAndOnePastIsNot() async {
        let inside = await run(x: 99, y: 99)
        let outside = await run(x: 100, y: 100)

        XCTAssertTrue(inside.performed, "(99, 99) is the last real pixel of a 100×100 image")
        XCTAssertFalse(outside.performed, "(100, 100) is one past it")
    }

    func testNegativeCoordinate_isRejected() async {
        let result = await run(x: -1, y: 10)

        XCTAssertFalse(result.performed)
        XCTAssertEqual(result.errorCode, ToolErrorCode.invalidArgs.rawValue)
    }

    // MARK: - The element echo

    func testClickInsideAnAdvertisedElement_echoesRoleAndLabel() async {
        let result = await run(
            x: 15, y: 15,
            elements: [Self.element(label: "Post", x: 10, y: 10, w: 20, h: 20)])

        XCTAssertTrue(result.performed)
        XCTAssertEqual(result.elementAtPoint, #"AXButton "Post""#)
        XCTAssertTrue(result.warnings.isEmpty, "a fresh capture and a hit warrants no warning")
    }

    func testClickInDeadSpace_omitsTheEchoEntirely() async {
        let result = await run(
            x: 90, y: 90,
            elements: [Self.element(label: "Post", x: 10, y: 10, w: 20, h: 20)])

        XCTAssertNil(result.elementAtPoint,
                     "no element contains the point — inventing an echo would be worse than silence")
    }

    /// The echo resolves against the exact list shipped with the capture, so overlapping
    /// elements must resolve to the SMALLEST — the innermost control is what a user would hit.
    func testOverlappingElements_echoesTheSmallest() async {
        let result = await run(
            x: 50, y: 50,
            elements: [
                Self.element(role: "AXGroup", label: "Toolbar", x: 0, y: 0, w: 100, h: 100),
                Self.element(label: "Send", x: 45, y: 45, w: 10, h: 10),
            ])

        XCTAssertEqual(result.elementAtPoint, #"AXButton "Send""#,
                       "the innermost control is the one the click actually hits")
    }

    // MARK: - Staleness

    /// The reason the suffix rides IN `data` rather than only in `meta.warnings`: a weak model
    /// weights the authoritative slot, so a bare `element_at_point: Post` reads as confirmation
    /// the click landed on Post even when prior actions have since changed the UI.
    func testStaleCapture_qualifiesTheEchoInTheAuthoritativeSlot() async {
        let result = await run(
            x: 15, y: 15,
            elements: [Self.element(label: "Post", x: 10, y: 10, w: 20, h: 20)],
            actionsSinceCapture: 2)

        XCTAssertEqual(result.elementAtPoint, #"AXButton "Post" (from an earlier capture — may be stale)"#)
    }

    func testStaleCapture_alsoWarns() async {
        let result = await run(x: 15, y: 15, actionsSinceCapture: 3)

        XCTAssertTrue(result.warnings.contains { $0.contains("3 actions have") },
                      "got: \(result.warnings)")
    }

    /// Staleness is measured BEFORE this action runs — the coordinates were aimed against a
    /// capture that N *prior* actions may have invalidated, and the action now being performed
    /// is not one of them. Reading the counter after the increment would report "1 action has
    /// run" on the very first click after a fresh capture, i.e. warn about itself.
    func testFirstActionAfterAFreshCapture_doesNotWarnAboutItself() async {
        let result = await run(x: 15, y: 15, actionsSinceCapture: 0)

        XCTAssertTrue(result.warnings.isEmpty, "got: \(result.warnings)")
        XCTAssertNil(result.elementAtPoint)
    }

    // MARK: - Miss warning

    func testMissWithAdvertisedElements_warns() async {
        let result = await run(
            x: 90, y: 90,
            elements: [Self.element(label: "Post", x: 10, y: 10, w: 20, h: 20)])

        XCTAssertTrue(result.warnings.contains { $0.contains("(90, 90)") }, "got: \(result.warnings)")
    }

    /// With an empty element list a "miss" is not evidence of anything — the app may simply be
    /// AX-sparse, or Accessibility may not be granted. Warning here would fire on every single
    /// click in those apps and train the model to ignore the warning.
    func testMissWithNoAdvertisedElements_staysSilent() async {
        let result = await run(x: 90, y: 90, elements: [])

        XCTAssertTrue(result.warnings.isEmpty, "got: \(result.warnings)")
    }

    /// Scroll passes `warnOnMiss: false`: scroll containers are legitimately absent from the
    /// actionable-element list, so every scroll would otherwise carry a spurious miss warning.
    func testWarnOnMissDisabled_suppressesOnlyTheMissWarning() async {
        let result = await run(
            x: 90, y: 90, warnOnMiss: false,
            elements: [Self.element(label: "Post", x: 10, y: 10, w: 20, h: 20)],
            actionsSinceCapture: 1)

        XCTAssertFalse(result.warnings.contains { $0.contains("(90, 90)") },
                       "the miss warning must be suppressed")
        XCTAssertTrue(result.warnings.contains { $0.contains("1 action has") },
                      "but staleness is a different signal and must survive: \(result.warnings)")
    }

    // MARK: - The success envelope

    func testSuccessEnvelope_carriesThePerformDetailVerbatim() async {
        let result = await run(x: 10, y: 10, detail: "Scrolled (0, -120) at image (10, 10).")

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.data["status"] as? String, "ok")
        XCTAssertEqual(result.data["detail"] as? String, "Scrolled (0, -120) at image (10, 10).")
    }

    /// Exactly one tool message per action. `finalizeToolResult` also persists a `[CALL]`/
    /// `[RESULT]` pair and rewrites the tool card; a second append here would double every
    /// computer-use result in the model's conversation.
    func testExactlyOneToolMessageIsAppended() async {
        var messages: [ChatMessage] = []
        await sut._testRunPointerAction(
            x: 10, y: 10, target: nil, warnOnMiss: true,
            stepID: "role-1", taskID: 1, capture: Self.makeCapture(),
            conversationMessages: &messages,
            perform: { _ in "Clicked." })

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .tool)
    }

    // MARK: - Staleness counter

    /// Every action that reaches the screen advances the counter, including one that missed
    /// every advertised element — a click into dead space can still open a menu or dismiss a
    /// popover, which is exactly the kind of change that invalidates the capture.
    func testAMissedClick_stillAdvancesStaleness() async {
        _ = await run(x: 90, y: 90, elements: [Self.element(label: "Post", x: 10, y: 10, w: 20, h: 20)])

        XCTAssertEqual(sut._testComputerUseActionsSinceCapture(stepID: "role-1", taskID: 1), 1)
    }

    func testPerformedAction_advancesStalenessFromWhereverItStood() async {
        _ = await run(x: 10, y: 10, actionsSinceCapture: 4)

        XCTAssertEqual(sut._testComputerUseActionsSinceCapture(stepID: "role-1", taskID: 1), 5)
    }

    /// A rejected action must NOT advance staleness — nothing happened on screen, and inflating
    /// the counter makes a still-valid capture look stale and pushes the model into a needless
    /// re-capture loop.
    func testRejectedAction_doesNotAdvanceStaleness() async {
        var messages: [ChatMessage] = []
        await sut._testRunPointerAction(
            x: 500, y: 500, target: nil, warnOnMiss: true,
            stepID: "role-1", taskID: 1, capture: Self.makeCapture(),
            actionsSinceCapture: 0,
            conversationMessages: &messages,
            perform: { _ in "Clicked." })

        XCTAssertEqual(sut._testComputerUseActionsSinceCapture(stepID: "role-1", taskID: 1), 0,
                       "an out-of-bounds click changed nothing on screen")
    }
}
