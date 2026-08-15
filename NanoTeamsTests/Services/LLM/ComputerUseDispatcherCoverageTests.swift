import CoreGraphics
import XCTest

@testable import NanoTeams

/// `appendComputerUseResult` — the computer-use finalizer's dispatcher, and until this suite the
/// single largest untested function in the app (82 executable lines, zero covered).
///
/// It was not untested because nobody thought to: it was unreachable. The first thing it does is
/// ask the OS whether this process holds the Accessibility grant, and an `xctest` runner does not,
/// so every path past that line was dead on any machine anyone could run. The second thing it does,
/// on the paths that DO get past, is post real CGEvents — so making it reachable and making it safe
/// to test were the same problem. `ComputerUseEnvironment` solves both: the tests below drive the
/// production dispatcher end to end, and not one keystroke reaches the machine running them.
///
/// What is actually being pinned here is the promise the agent is given about its own actions. A
/// dispatcher that reports `ok` for input the OS silently dropped is not a cosmetic defect — the
/// model re-captures, sees nothing changed, and loops; that exact failure is why the permission
/// guard exists, and nothing tested it.
///
/// RED: flip `requiresAccessibility` to return `false` for every case → the four action arms stop
/// consulting the grant and `testClick_withoutAccessibility_refusesAndSynthesizesNothing` fails
/// with a click in the log.
@MainActor
final class ComputerUseDispatcherCoverageTests: XCTestCase, @unchecked Sendable {

    private var env: FakeComputerUseEnvironment!
    private var sut: LLMExecutionService!

    override func setUp() async throws {
        try await super.setUp()
        env = FakeComputerUseEnvironment()
        sut = LLMExecutionService(repository: NTMSRepository(), computerUse: env.environment)
    }

    override func tearDown() async throws {
        sut = nil
        env = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private static let stepID = "engineer"
    private static let taskID = 7

    private func result(_ action: ComputerUseAction, tool: String = ToolNames.uiClick) -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: "call-1", toolName: tool, argumentsJSON: "{}", outputJSON: "",
            isError: false, signal: .computerUse(action))
    }

    /// Seeds the per-step capture clicks resolve against, exactly as a delivered `screen_capture`
    /// would have.
    private func seedCapture(_ captured: CapturedScreen = FakeScreenCapture.screenshot(),
                             elements: [AXElementInfo] = []) {
        sut._testSeedComputerUseCapture(
            stepID: Self.stepID, taskID: Self.taskID, capture: captured, elements: elements)
    }

    @discardableResult
    private func dispatch(_ action: ComputerUseAction, tool: String = ToolNames.uiClick) async -> [ChatMessage] {
        var messages: [ChatMessage] = []
        await sut.appendComputerUseResult(
            result: result(action, tool: tool), toolCallID: UUID(),
            stepID: Self.stepID, taskID: Self.taskID,
            client: UnreachableChatClient(), config: LLMConfig(), networkLogger: nil,
            conversationMessages: &messages, tracker: nil)
        return messages
    }

    private func envelope(_ messages: [ChatMessage]) -> String {
        messages.first(where: { $0.role == .tool })?.content ?? ""
    }

    // MARK: - Permission gate

    /// The guard the whole file hangs on. Without the grant the OS drops synthesized events on the
    /// floor and returns nothing to say so, so a dispatcher that proceeded would report success for
    /// an action that never happened.
    ///
    /// RED: delete the `!computerUse.input.hasAccessibility()` guard → a click lands in the log and
    /// the envelope reads `ok:true`.
    func testClick_withoutAccessibility_refusesAndSynthesizesNothing() async {
        env.input.accessibilityGranted = false
        seedCapture()

        let messages = await dispatch(.click(x: 10, y: 10, button: "left", double: false, target: nil))

        XCTAssertEqual(env.input.synthesisLog, [], "no input may be synthesized without the grant")
        XCTAssertTrue(envelope(messages).contains("\"ok\":false"))
        XCTAssertTrue(envelope(messages).contains("Accessibility"),
                      "the refusal must name the permission — it is the only actionable part")
    }

    /// Refusing is not enough on its own: the user has to be shown the switch. The dispatcher opens
    /// the System Settings pane, once, on the way out.
    func testRefusal_promptsForTheGrant() async {
        env.input.accessibilityGranted = false
        seedCapture()

        await dispatch(.typeText(text: "hi", target: nil))

        XCTAssertEqual(env.input.trustPrompts, 1)
    }

    /// All four input actions are gated, not just the click that happened to be tested first.
    /// Enumerated rather than sampled: the gate is a `switch`-free predicate, so a new action case
    /// added to `ComputerUseAction` inherits whichever default `requiresAccessibility` returns.
    func testEveryInputAction_isGatedByTheGrant() async {
        let actions: [ComputerUseAction] = [
            .click(x: 1, y: 1, button: "left", double: false, target: nil),
            .scroll(x: 1, y: 1, dx: 0, dy: 5, target: nil),
            .typeText(text: "x", target: nil),
            .pressKey(keys: "cmd+s", target: nil),
        ]
        for action in actions {
            env = FakeComputerUseEnvironment()
            env.input.accessibilityGranted = false
            sut = LLMExecutionService(repository: NTMSRepository(), computerUse: env.environment)
            seedCapture()

            let messages = await dispatch(action)

            XCTAssertEqual(env.input.synthesisLog, [], "\(action) synthesized input while ungranted")
            XCTAssertTrue(envelope(messages).contains("\"ok\":false"), "\(action) reported success")
        }
    }

    /// `screen_capture` needs Screen Recording, which `ScreenCaptureService` checks for itself —
    /// gating it on Accessibility too would make a read-only capture impossible on a machine that
    /// deliberately grants only the weaker permission.
    ///
    /// RED: make `requiresAccessibility` return `true` unconditionally → the capture never reaches
    /// the screen adapter.
    func testCapture_isNotGatedByAccessibility() async {
        env.input.accessibilityGranted = false

        await dispatch(.capture(target: "screen", windowTitle: nil), tool: ToolNames.screenCapture)

        XCTAssertEqual(env.screen.calls.count, 1, "capture must reach the screen adapter without the input grant")
    }

    // MARK: - Type

    func testType_synthesizesTheTextAndReportsOK() async {
        let messages = await dispatch(.typeText(text: "hello world", target: nil), tool: ToolNames.uiType)

        XCTAssertEqual(env.input.typed, ["hello world"])
        XCTAssertTrue(envelope(messages).contains("\"ok\":true"))
        XCTAssertTrue(envelope(messages).contains("\"action\":\"type\""))
    }

    /// Typing invalidates the screenshot the model is aiming with, so it must advance the staleness
    /// counter — the value `runPointerAction` later turns into "(from an earlier capture — may be
    /// stale)" on the element echo.
    ///
    /// RED: drop the `computerUseActionsSinceCapture += 1` from the type arm → the count stays 0 and
    /// a click after a keystroke claims a fresh capture.
    func testType_advancesTheStalenessCounter() async {
        seedCapture()

        await dispatch(.typeText(text: "a", target: nil), tool: ToolNames.uiType)

        XCTAssertEqual(sut._testComputerUseActionsSinceCapture(stepID: Self.stepID, taskID: Self.taskID), 1)
    }

    // MARK: - Key

    func testPressKey_synthesizesTheComboAndEchoesIt() async {
        seedCapture()

        let messages = await dispatch(.pressKey(keys: "cmd+s", target: nil), tool: ToolNames.uiKey)

        XCTAssertEqual(env.input.pressedKeys, ["cmd+s"])
        XCTAssertTrue(envelope(messages).contains("\"keys\":\"cmd+s\""))
        XCTAssertEqual(sut._testComputerUseActionsSinceCapture(stepID: Self.stepID, taskID: Self.taskID), 1)
    }

    /// An unparseable combo is the model's mistake, so it gets `INVALID_ARGS` and the message the
    /// error type carries — not a bare failure it cannot act on.
    ///
    /// RED: swallow the `catch` → the model is told the keystroke succeeded.
    func testPressKey_unknownCombo_reportsInvalidArgsWithTheCombo() async {
        env.input.pressKeysError = InputControlError.unknownKeyCombo("cmd+nonsense")
        seedCapture()

        let messages = await dispatch(.pressKey(keys: "cmd+nonsense", target: nil), tool: ToolNames.uiKey)

        XCTAssertTrue(envelope(messages).contains("\"ok\":false"))
        XCTAssertTrue(envelope(messages).contains("cmd+nonsense"))
        XCTAssertEqual(sut._testComputerUseActionsSinceCapture(stepID: Self.stepID, taskID: Self.taskID), 0,
                       "a keystroke that never happened must not age the capture")
    }

    // MARK: - Click / scroll routing

    /// The dispatcher's job on a click is to hand `runPointerAction` the right button and the right
    /// miss-warning policy. `"right"` is the only string that means the right button — anything else
    /// (including a model's `"RIGHT"`) is left, which is the safe direction: a stray context menu is
    /// recoverable, an unintended primary click is not.
    func testClick_routesButtonAndDoubleThrough() async {
        seedCapture()

        await dispatch(.click(x: 10, y: 20, button: "right", double: true, target: nil))

        XCTAssertEqual(env.input.clicks, [
            FakeInputControl.ClickCall(point: CGPoint(x: 10, y: 20), button: .right, double: true)
        ])
    }

    /// Right-clicks skip the miss warning: opening a context menu on empty background is a
    /// legitimate dead-space click, and warning about it teaches the model to distrust a correct
    /// action.
    ///
    /// RED: pass `warnOnMiss: true` for right-clicks → the envelope grows a "did not land on any
    /// element" warning.
    func testRightClick_doesNotWarnAboutMissingEveryElement() async {
        seedCapture(elements: [AXElementInfo(role: "AXButton", label: "Post", x: 0, y: 0, w: 5, h: 5,
                                             cx: 2, cy: 2, web: false)])

        let right = await dispatch(.click(x: 90, y: 90, button: "right", double: false, target: nil))
        XCTAssertFalse(envelope(right).contains("is not inside any element"), "right-click must not warn on a miss")

        let left = await dispatch(.click(x: 90, y: 90, button: "left", double: false, target: nil))
        XCTAssertTrue(envelope(left).contains("is not inside any element"), "left-click on dead space must warn")
    }

    func testScroll_routesDeltasThrough() async {
        seedCapture()

        await dispatch(.scroll(x: 10, y: 20, dx: -3, dy: 7, target: nil), tool: ToolNames.uiScroll)

        XCTAssertEqual(env.input.scrolls, [
            FakeInputControl.ScrollCall(point: CGPoint(x: 10, y: 20), dx: -3, dy: 7)
        ])
    }

    // MARK: - Target activation

    /// Input must land in the app the model named, so the dispatcher raises it first.
    func testAction_withTarget_raisesThatApp() async {
        await dispatch(.typeText(text: "x", target: "Safari"), tool: ToolNames.uiType)

        XCTAssertEqual(env.input.activations, ["Safari"])
    }

    /// `"screen"` is the whole-display pseudo-target, not an app — trying to raise it would send the
    /// resolver hunting for an application by that name.
    func testAction_targetingScreen_raisesNothing() async {
        await dispatch(.typeText(text: "x", target: "screen"), tool: ToolNames.uiType)

        XCTAssertEqual(env.input.activations, [], "\"screen\" is a display, not an app to raise")
        XCTAssertEqual(env.input.typed, ["x"], "and the action still runs")
    }

    /// A target that resolves to nothing is not an error: the action applies to whatever is
    /// frontmost, which is the documented behaviour of an omitted target.
    func testAction_unresolvableTarget_stillActs() async {
        env.input.resolvableSpecs = []

        await dispatch(.typeText(text: "x", target: "NotRunning"), tool: ToolNames.uiType)

        XCTAssertEqual(env.input.typed, ["x"])
    }

    /// The policy switch that lets a user keep windows where they are. When it is off, no raise —
    /// but the action still happens.
    ///
    /// RED: ignore `raiseTargetWindowBeforeClick` → the app is activated against the user's setting.
    func testAction_whenRaisingIsDisabledByPolicy_doesNotActivate() async {
        let delegate = MockLLMExecutionDelegate()
        delegate.computerUsePolicy = ComputerUsePolicy(
            mode: .auto, restrictionLevel: .standard, raiseTargetWindowBeforeClick: false)
        sut.delegate = delegate

        await dispatch(.typeText(text: "x", target: "Safari"), tool: ToolNames.uiType)

        XCTAssertEqual(env.input.activations, [])
        XCTAssertEqual(env.input.typed, ["x"])
    }

    // MARK: - Capture path

    /// The capture arm's happy path up to delivery: the screenshot is taken with the requested
    /// target, the AX tree is enumerated for it, and the per-RUN capture counter advances (that
    /// counter is what makes the privacy prompt fire once per run rather than once per role).
    func testCapture_takesTheShotEnumeratesAXAndCountsIt() async {
        env.screen.result = .success(FakeScreenCapture.screenshot(
            targetKind: "window", appName: "Safari", bundleID: "com.apple.Safari", pid: 999))

        await dispatch(.capture(target: "Safari", windowTitle: "Feed"), tool: ToolNames.screenCapture)

        XCTAssertEqual(env.screen.calls, [FakeScreenCapture.Call(
            targetSpec: "Safari", windowTitle: "Feed", ownBundleID: "com.nanoteams.test")])
        XCTAssertEqual(env.ax.requests.count, 1)
        XCTAssertEqual(env.ax.requests.first?.pid, 999, "AX must enumerate the captured window's app")
        XCTAssertEqual(sut._testComputerUseCaptureCount(taskID: Self.taskID), 1)
    }

    /// A window capture pins AX to that window's region so elements from the app's OTHER windows
    /// don't get reported at coordinates inside this screenshot.
    ///
    /// RED: pass `matchWindowToRegion: false` → the flag stops tracking the capture kind.
    func testCapture_ofAWindow_asksAXToMatchTheRegion() async {
        env.screen.result = .success(FakeScreenCapture.screenshot(targetKind: "window", pid: 5))

        await dispatch(.capture(target: "Safari", windowTitle: nil), tool: ToolNames.screenCapture)
        XCTAssertEqual(env.ax.requests.first?.matchWindowToRegion, true)

        env = FakeComputerUseEnvironment()
        env.screen.result = .success(FakeScreenCapture.screenshot(targetKind: "display", pid: 5))
        sut = LLMExecutionService(repository: NTMSRepository(), computerUse: env.environment)

        await dispatch(.capture(target: "screen", windowTitle: nil), tool: ToolNames.screenCapture)
        XCTAssertEqual(env.ax.requests.first?.matchWindowToRegion, false,
                       "a whole-display capture has no window to match")
    }

    /// A whole-display capture carries no pid, so AX falls back to whatever is frontmost — the app
    /// the user is actually looking at.
    func testCapture_wholeDisplay_enumeratesTheFrontmostApp() async {
        env.frontmost.app = FrontmostApplication(bundleIdentifier: "com.apple.Safari", processIdentifier: 314)

        await dispatch(.capture(target: "screen", windowTitle: nil), tool: ToolNames.screenCapture)

        XCTAssertEqual(env.ax.requests.first?.pid, 314)
    }

    /// …unless the frontmost app is NanoTeams itself. Enumerating our own tree would hand the model
    /// this app's UI as the thing to operate — the same self-feeding the display capture's own
    /// window exclusion exists to prevent, one layer up.
    ///
    /// RED: drop the `front.bundleIdentifier != ownBundle` test → AX is asked for our own pid.
    func testCapture_wholeDisplay_neverEnumeratesOurselves() async {
        env.frontmost.app = FrontmostApplication(
            bundleIdentifier: "com.nanoteams.test", processIdentifier: 1)

        await dispatch(.capture(target: "screen", windowTitle: nil), tool: ToolNames.screenCapture)

        XCTAssertTrue(env.ax.requests.isEmpty, "our own accessibility tree is never the agent's target")
    }

    /// Nothing frontmost and no captured pid — there is no tree to walk, and the empty result is
    /// what `emptyElementsNote` later turns into an honest warning.
    func testCapture_withNoResolvablePID_skipsAXEntirely() async {
        env.frontmost.app = nil

        await dispatch(.capture(target: "screen", windowTitle: nil), tool: ToolNames.screenCapture)

        XCTAssertTrue(env.ax.requests.isEmpty)
    }

    /// A capture that fails is reported as a failure — with the reason, since every one of them
    /// (permission, no display, no such window) names a different thing the agent or user can do.
    ///
    /// RED: swallow the `catch` → the model gets `ok:true` with no screenshot.
    func testCapture_whenTheScreenshotFails_reportsTheReason() async {
        env.screen.result = .failure(ScreenCaptureError.windowNotFound("Notes", visibleApps: ["Safari"]))

        let messages = await dispatch(.capture(target: "Notes", windowTitle: nil), tool: ToolNames.screenCapture)

        XCTAssertTrue(envelope(messages).contains("\"ok\":false"))
        XCTAssertTrue(envelope(messages).contains("Notes"))
        XCTAssertEqual(sut._testComputerUseCaptureCount(taskID: Self.taskID), 0,
                       "a capture that never happened must not spend the per-run privacy budget")
    }

    /// Cancellation — Pause, supersede, a work-folder switch — appends NOTHING. Finalizing would
    /// write a tool result into a conversation nobody is going to send, and on re-entry the step
    /// would replay a result for a call it is about to make again.
    ///
    /// RED: replace `catch is CancellationError { return }` with the generic catch → a tool message
    /// is appended.
    func testCapture_whenCancelled_appendsNothing() async {
        env.screen.result = .failure(CancellationError())

        let messages = await dispatch(.capture(target: "screen", windowTitle: nil), tool: ToolNames.screenCapture)

        XCTAssertEqual(messages, [])
    }

    /// The main model can't see images and no Vision model is configured, so the screenshot has
    /// nowhere to go. Reported as a failure naming both ways out — silently succeeding would leave
    /// the agent clicking against a picture it never received.
    func testCapture_withNoVisionRoute_reportsWhatToConfigure() async {
        let messages = await dispatch(.capture(target: "screen", windowTitle: nil), tool: ToolNames.screenCapture)

        XCTAssertTrue(envelope(messages).contains("\"ok\":false"))
        XCTAssertTrue(envelope(messages).contains("Vision"))
        XCTAssertNil(sut._testLastComputerUseCapture(stepID: Self.stepID, taskID: Self.taskID),
                     "clicks must keep resolving against the last capture the model actually saw")
    }

    /// Cancellation during the Vision round-trip is the one that is easiest to get wrong: unlike the
    /// screenshot, this await is not obviously an OS call, and a `catch` that treated it as a
    /// generic failure would tell the model "the Vision model failed" for a step the user had just
    /// paused — and append a tool result into a conversation that is being torn down.
    ///
    /// RED: remove `catch is CancellationError { return }` from the description path → the envelope
    /// blames the Vision model.
    func testCapture_whenTheVisionDescriptionIsCancelled_appendsNothing() async {
        let delegate = MockLLMExecutionDelegate()
        delegate.visionLLMConfig = LLMConfig(baseURLString: "http://127.0.0.1:1", modelName: "v")
        sut.delegate = delegate

        var messages: [ChatMessage] = []
        await sut.appendComputerUseResult(
            result: result(.capture(target: "screen", windowTitle: nil), tool: ToolNames.screenCapture),
            toolCallID: UUID(), stepID: Self.stepID, taskID: Self.taskID,
            client: CancellingChatClient(), config: LLMConfig(), networkLogger: nil,
            conversationMessages: &messages, tracker: nil)

        XCTAssertEqual(messages, [])
        XCTAssertNil(sut._testLastComputerUseCapture(stepID: Self.stepID, taskID: Self.taskID))
    }

    // MARK: - Signal guard

    /// The finalizer is dispatched by signal case; a non-computer-use result reaching it must do
    /// nothing at all rather than fall through to some default action.
    func testNonComputerUseSignal_isIgnoredEntirely() async {
        var messages: [ChatMessage] = []
        await sut.appendComputerUseResult(
            result: ToolExecutionResult(
                providerID: "call-1", toolName: ToolNames.readFile, argumentsJSON: "{}",
                outputJSON: "", isError: false),
            toolCallID: UUID(), stepID: Self.stepID, taskID: Self.taskID,
            client: UnreachableChatClient(), config: LLMConfig(), networkLogger: nil,
            conversationMessages: &messages, tracker: nil)

        XCTAssertEqual(messages.count, 0)
        XCTAssertEqual(env.input.synthesisLog, [])
    }
}

/// A client whose stream ends in `CancellationError` — the shape a Pause landing mid-request
/// produces, as distinct from a server that merely refused.
private final class CancellingChatClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
