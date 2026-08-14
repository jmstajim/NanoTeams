import XCTest

@testable import NanoTeams

/// The IMPURE half of the computer-use gate — the part `ComputerUsePermissionServiceTests`
/// (pure evaluator) and `ComputerUseGateTests` (Semi-automatic routing) structurally cannot
/// reach: `resolved(...)`, `judgeContext(...)`, `pointerGlobalPoint(...)` and
/// `approvalRequest(...)` are all `private`, so every case here drives the REAL
/// `gateComputerUseCalls` entry point and asserts on what came out the other side (the
/// synthetic deny map, the published `ComputerUseApprovalRequest`, or the exact prompt the
/// judge client received).
///
/// The headline pin is CLAUDE.md's documented gate-validates-a-different-value bug: the
/// human approval card must carry `action.detail` (untruncated), NEVER the 60-char
/// `action.summary` — otherwise a benign 60-char prefix gets approved while an arbitrary
/// suffix types.
///
/// SAFETY: nothing here posts a CGEvent, moves the pointer, types, or captures the screen.
/// The gate is a decision pre-pass; the OS action lives in the finalizer, never invoked.
/// `CapturedScreen` fixtures are seeded at a global origin of (50000, 50000) so the
/// own-window self-guard (`InputControlService.ownWindowFrames()`, a real but read-only
/// `CGWindowList` query) can never intersect a resolved point and flip a case to a
/// self-target deny. `InputControlService.runningApp(matching:)` is likewise read-only and
/// every target spec used here is a phantom app name that resolves to nil.
///
/// `@MainActor` + `async` per the documented sync-test abort gotcha (constructing the
/// `@MainActor` `LLMExecutionService` from a synchronous test method aborts on CI); `setUp`
/// is immune. The hold-then-resolve harness is copied verbatim from `BashGateTests`.
@MainActor
final class ComputerUseGateResolutionTests: XCTestCase {

    var service: LLMExecutionService!
    var delegate: MockLLMExecutionDelegate!
    // Class-level, never a local in a @MainActor test body — constructing a class
    // instance as a local aborts on this Xcode.
    private var judgeClient: RecordingComputerUseJudgeClient!

    private let stepID = "step1"
    private let taskID = 1

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        delegate.snapshot = nil  // → not under Autovisor (isUnderAutovisor returns false)
        service.attach(delegate: delegate)
        judgeClient = RecordingComputerUseJudgeClient()
    }

    override func tearDown() {
        service = nil
        delegate = nil
        judgeClient = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func task() -> NTMSTask {
        NTMSTask(id: 1, title: "t", supervisorTask: "g", runs: [])
    }

    private func call(_ name: String, _ argsJSON: String, providerID: String = "p1") -> StepToolCall {
        StepToolCall(providerID: providerID, name: name, argumentsJSON: argsJSON)
    }

    private func key() -> TaskStepKey { TaskStepKey(taskID: taskID, stepID: stepID) }

    /// Seeds the per-step capture metadata `resolved` / `judgeContext` / `approvalRequest`
    /// all read. Origin is far outside any real display so a resolved global point can
    /// never land inside a live NanoTeams window (the self-guard).
    private func seedCapture(
        pngBase64: String = "PNGDATA",
        pixelWidth: Int = 1000,
        pixelHeight: Int = 1000,
        appName: String? = nil,
        windowTitle: String? = nil,
        elements: [AXElementInfo] = [],
        actionsSinceCapture: Int = 0
    ) {
        var state = LLMExecutionService.StepExecutionState()
        state.lastComputerUseCapture = CapturedScreen(
            pngBase64: pngBase64, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            regionWidthPt: 1000, regionHeightPt: 1000,
            originX: 50000, originY: 50000,
            targetKind: "display", appName: appName, bundleID: nil,
            windowTitle: windowTitle, displayID: nil, pid: nil)
        state.lastComputerUseElements = elements
        state.computerUseActionsSinceCapture = actionsSinceCapture
        service.executionStates[key()] = state
    }

    // MARK: - Gate drivers

    /// Runs the gate to completion. Only safe for policies under which no action is HELD
    /// for a human (otherwise this suspends until the XCTest timeout).
    private func gate(
        _ calls: [StepToolCall],
        policy: ComputerUsePolicy,
        supervisorMode: SupervisorMode = .autonomous,
        allowedToolNames: Set<String> = ToolHandlerRegistry.computerUseTools
    ) async -> [Int: ToolExecutionResult] {
        delegate.computerUsePolicy = policy
        return await service.gateComputerUseCalls(
            resolvedToolCalls: calls,
            allowedToolNames: allowedToolNames,
            stepID: stepID,
            taskID: taskID,
            supervisorMode: supervisorMode,
            task: task(),
            client: judgeClient,
            config: LLMConfig(),
            networkLogger: nil)
    }

    /// Starts the gate and waits until it publishes an approval request, returning the
    /// still-running task plus the published request. Mirrors `BashGateTests.gateHolding`.
    private func gateHolding(
        _ calls: [StepToolCall],
        policy: ComputerUsePolicy,
        supervisorMode: SupervisorMode = .manual
    ) async -> (task: Task<[Int: ToolExecutionResult], Never>, request: ComputerUseApprovalRequest?) {
        delegate.computerUsePolicy = policy
        let names = ToolHandlerRegistry.computerUseTools
        let sid = stepID
        let tid = taskID
        let running = Task { [service, judgeClient, gateTask = task()] in
            await service!.gateComputerUseCalls(
                resolvedToolCalls: calls, allowedToolNames: names,
                stepID: sid, taskID: tid, supervisorMode: supervisorMode, task: gateTask,
                client: judgeClient!, config: LLMConfig(), networkLogger: nil)
        }
        for _ in 0..<500 {
            if let request = delegate.computerUseApprovalBeganRequests.first {
                return (running, request)
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the gate did not hold a computer-use action for approval")
        running.cancel()
        return (running, nil)
    }

    // MARK: - Assertion helpers

    private func denyMessage(_ result: ToolExecutionResult?) -> String {
        guard let result,
              let dict = JSONUtilities.parseJSONDictionary(result.outputJSON),
              let error = dict["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return "" }
        return message
    }

    private func assertIsComputerUseDeny(
        _ result: ToolExecutionResult?, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let result else {
            return XCTFail("expected a synthetic deny, but the call passed through to execution",
                           file: file, line: line)
        }
        XCTAssertTrue(result.isError, "a gate interception must be an error result", file: file, line: line)
        XCTAssertTrue(
            result.outputJSON.contains(ToolErrorCode.computerUseDenied.rawValue),
            "expected a COMPUTER_USE_DENIED envelope, got: \(result.outputJSON)", file: file, line: line)
    }

    // MARK: - approvalRequest: the untruncated-detail security contract

    /// CLAUDE.md pins this as a FIXED bug: the approval card once showed
    /// `action.summary`, which caps typed text at 60 chars, while the finalizer typed the
    /// full string — a benign prefix approved, an arbitrary suffix run. The request must
    /// carry `action.detail`.
    func testApprovalRequest_typeText_carriesUntruncatedDetail_notThe60CharSummary() async {
        let longText = String(repeating: "a", count: 120) + "-TAIL-MARKER"
        let expected = ComputerUseAction.typeText(text: longText, target: nil)
        // Precondition on the fixture itself: if `summary` stopped truncating, this test
        // would pass vacuously.
        XCTAssertFalse(
            expected.summary.contains("-TAIL-MARKER"),
            "fixture must be long enough that `summary` truncates away the tail")

        let (running, request) = await gateHolding(
            [call(ToolNames.uiType, "{\"text\":\"\(longText)\"}")],
            policy: ComputerUsePolicy(mode: .manual))
        guard let request else { return }

        XCTAssertEqual(
            request.actionSummary, expected.detail,
            "the approval card must show the FULL action text the finalizer will run")
        XCTAssertNotEqual(
            request.actionSummary, expected.summary,
            "the 60-char display summary must never reach a security surface")
        XCTAssertTrue(
            request.actionSummary.contains("-TAIL-MARKER"),
            "the human must see the suffix that will actually be typed")

        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: request.actionKey, decision: .deny)
        let results = await running.value
        assertIsComputerUseDeny(results[0])
        XCTAssertTrue(
            denyMessage(results[0]).contains("declined"),
            "a human deny must name the human, got: \(denyMessage(results[0]))")
        XCTAssertTrue(
            delegate.computerUseApprovalBeganRequests.isEmpty,
            "the held request must be cleared once the await resolves")
        XCTAssertEqual(judgeClient.callCount, 0, "the human path must never consult the judge")
    }

    /// A click's request carries the crosshair coordinates + the last screenshot so the card
    /// can render a preview, and identifies itself by the tool call's own id.
    func testApprovalRequest_click_carriesCrosshairCoordinatesScreenshotAndCallIdentity() async {
        seedCapture(pngBase64: "SCREENSHOT-BYTES")
        let clickCall = call(ToolNames.uiClick, #"{"x":100,"y":250,"button":"left"}"#)

        let (running, request) = await gateHolding([clickCall], policy: ComputerUsePolicy(mode: .manual))
        guard let request else { return }

        XCTAssertEqual(request.targetX, 100, "the crosshair X must be the image-pixel X")
        XCTAssertEqual(request.targetY, 250, "the crosshair Y must be the image-pixel Y")
        XCTAssertEqual(request.screenshotBase64, "SCREENSHOT-BYTES",
                       "the card previews the step's last capture")
        XCTAssertEqual(request.actionKey, clickCall.id.uuidString,
                       "the request must be keyed by the tool call's own id")
        XCTAssertEqual(request.taskID, taskID)
        XCTAssertEqual(request.stepID, stepID)
        XCTAssertNil(request.targetApp, "an untargeted click has no app to name")
        XCTAssertFalse(request.offerAlways,
                       "Always-allow is meaningless without a specific target app")

        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: request.actionKey, decision: .allow)
        let results = await running.value
        XCTAssertTrue(results.isEmpty, "allow → no synthetic → the call passes through and runs for real")
    }

    /// Non-pointer actions take the `default:` arm: no crosshair, and with no capture seeded,
    /// no screenshot either.
    func testApprovalRequest_pressKey_hasNoCrosshairAndNoScreenshotWithoutACapture() async {
        let (running, request) = await gateHolding(
            [call(ToolNames.uiKey, #"{"keys":"cmd+s"}"#)],
            policy: ComputerUsePolicy(mode: .manual))
        guard let request else { return }

        XCTAssertNil(request.targetX, "a key press has no coordinate to crosshair")
        XCTAssertNil(request.targetY)
        XCTAssertNil(request.screenshotBase64, "no capture yet → no preview image")
        XCTAssertEqual(request.actionSummary, ComputerUseAction.pressKey(keys: "cmd+s", target: nil).detail)

        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: request.actionKey, decision: .deny)
        _ = await running.value
    }

    /// A targeted action offers Always-allow and names the app; granting it records the
    /// per-run session grant keyed by the LOWERCASED resolved target.
    func testApprovalRequest_targetedAction_offersAlways_andGrantingRecordsTheRunAllowlist() async {
        let (running, request) = await gateHolding(
            [call(ToolNames.uiClick, #"{"x":10,"y":10,"target":"ZZZPhantomApp"}"#)],
            policy: ComputerUsePolicy(mode: .manual))
        guard let request else { return }

        XCTAssertEqual(request.targetApp, "ZZZPhantomApp", "the card must name the app being acted on")
        XCTAssertTrue(request.offerAlways, "a specific target app makes Always-allow meaningful")

        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: request.actionKey, decision: .alwaysAllowApp)
        let results = await running.value

        XCTAssertTrue(results.isEmpty, "Always-allow allows this action too, not just future ones")
        let granted = service.computerUseSessionAllowedApps[taskID] ?? []
        XCTAssertTrue(
            granted.contains("zzzphantomapp"),
            "the run grant must be recorded lowercased so later lookups match case-insensitively, got: \(granted)")
        XCTAssertEqual(granted.count, 1, "exactly the granted app, nothing else")
    }

    /// The first `screen_capture` of a run is held for privacy in Manual mode; once the run
    /// has captured, `gateFirstCaptureOnly` auto-allows and nothing is held.
    func testCaptureGate_firstCaptureIsHeld_thenLaterCapturesAutoAllow() async {
        let (running, request) = await gateHolding(
            [call(ToolNames.screenCapture, #"{"target":"screen"}"#)],
            policy: ComputerUsePolicy(mode: .manual))
        guard let request else { return }

        XCTAssertNil(request.targetApp, "a whole-screen capture targets no app")
        XCTAssertFalse(request.offerAlways)
        XCTAssertNil(request.targetX, "a capture has no crosshair")

        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: request.actionKey, decision: .allow)
        let firstResults = await running.value
        XCTAssertTrue(firstResults.isEmpty, "an approved capture passes through to execution")

        // The finalizer bumps this per-TASK counter after a real capture; simulate that and
        // re-gate. A regression here would HANG this test rather than fail it, which is the
        // honest signal: the gate would be holding a capture it promised not to.
        service.computerUseCaptureCountByTask[taskID] = 1
        let results = await gate(
            [call(ToolNames.screenCapture, #"{"target":"screen"}"#)],
            policy: ComputerUsePolicy(mode: .manual), supervisorMode: .manual)
        XCTAssertTrue(results.isEmpty, "a subsequent capture must auto-allow, not ask again")
        XCTAssertTrue(delegate.computerUseApprovalBeganRequests.isEmpty,
                      "no second privacy prompt may be published")
    }

    /// The per-run grant short-circuits the whole review tier. Driven autonomously so a
    /// broken short-circuit DENIES (deterministic failure) instead of hanging on a human.
    func testSessionGrant_shortCircuitsReview_forTheGrantedAppOnly() async {
        service.computerUseSessionAllowedApps[taskID] = Set(["zzzphantomapp"])

        let results = await gate(
            [
                call(ToolNames.uiClick, #"{"x":10,"y":10,"target":"ZZZPhantomApp"}"#, providerID: "granted"),
                call(ToolNames.uiClick, #"{"x":10,"y":10,"target":"ZZZOtherApp"}"#, providerID: "ungranted"),
            ],
            policy: ComputerUsePolicy(mode: .manual))

        XCTAssertNil(results[0], "the granted app must pass through with no review")
        assertIsComputerUseDeny(results[1])
        XCTAssertEqual(judgeClient.callCount, 0, "a session grant is not a judge question")
    }

    // MARK: - judgeContext: which app the judge rules on, and staleness

    /// CLAUDE.md's ordering rule: `action.appTargetSpec ?? capture?.appName`. The finalizer
    /// raises and acts in the action's OWN target, so judging the last capture's app instead
    /// would rule on the wrong application entirely.
    func testJudgeContext_actionTargetWinsOverCaptureApp_andStaleCaptureIsLabelled() async {
        seedCapture(
            appName: "ZZZPhantomSafari",
            windowTitle: "Feed | Somewhere",
            elements: [AXElementInfo(role: "AXButton", label: "Post",
                                     x: 90, y: 90, w: 20, h: 20, cx: 100, cy: 100, web: true)],
            actionsSinceCapture: 3)

        let results = await gate(
            [call(ToolNames.uiClick, #"{"x":100,"y":100,"target":"ZZZPhantomTerminal"}"#)],
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard))

        XCTAssertTrue(results.isEmpty, "the stub judge allows, so the click passes through")
        XCTAssertEqual(judgeClient.callCount, 1, "Auto mode must consult the judge exactly once")

        let prompt = judgeClient.lastUserPrompt
        XCTAssertTrue(
            prompt.contains("Target app: ZZZPhantomTerminal"),
            "the judge must rule on the action's declared target, got: \(prompt)")
        XCTAssertFalse(
            prompt.contains("Target app: ZZZPhantomSafari"),
            "the last capture's app must not override the action's own target")
        XCTAssertTrue(
            prompt.contains("Feed | Somewhere"),
            "the window title still comes from the capture, got: \(prompt)")
        XCTAssertTrue(
            prompt.contains("AXButton") && prompt.contains("Post"),
            "the advertised element under the click must be resolved for the judge, got: \(prompt)")
        XCTAssertTrue(
            prompt.contains("stale"),
            "3 actions since the capture must be flagged as possibly stale, got: \(prompt)")
    }

    /// With no declared target the capture's app is the fallback — and a FRESH capture
    /// (zero actions since) must not be labelled stale.
    func testJudgeContext_untargetedAction_fallsBackToCaptureApp_andFreshCaptureIsNotStale() async {
        seedCapture(
            appName: "ZZZPhantomSafari",
            elements: [AXElementInfo(role: "AXButton", label: "Post",
                                     x: 90, y: 90, w: 20, h: 20, cx: 100, cy: 100, web: true)],
            actionsSinceCapture: 0)

        _ = await gate(
            [call(ToolNames.uiClick, #"{"x":100,"y":100}"#)],
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard))

        let prompt = judgeClient.lastUserPrompt
        XCTAssertTrue(
            prompt.contains("Target app: ZZZPhantomSafari"),
            "an untargeted action is judged against the app that was captured, got: \(prompt)")
        XCTAssertFalse(
            prompt.contains("stale"),
            "a capture with no intervening actions is current, got: \(prompt)")
    }

    /// A click that hits no advertised element leaves the label out entirely rather than
    /// inventing one — the judge must not be handed a neighbouring element as confirmation.
    func testJudgeContext_clickOutsideEveryAdvertisedElement_omitsTheElementLabel() async {
        seedCapture(
            appName: "ZZZPhantomSafari",
            elements: [AXElementInfo(role: "AXButton", label: "Post",
                                     x: 0, y: 0, w: 10, h: 10, cx: 5, cy: 5, web: false)])

        _ = await gate(
            [call(ToolNames.uiClick, #"{"x":500,"y":500}"#)],
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard))

        XCTAssertFalse(
            judgeClient.lastUserPrompt.contains("Element under cursor"),
            "a dead-space click has no element, got: \(judgeClient.lastUserPrompt)")
    }

    /// A judge DENY becomes the synthetic result, carrying the judge's own reason so the
    /// model learns why rather than seeing a generic refusal.
    func testJudgeDeny_synthesizesADenyCarryingTheJudgesReason() async {
        judgeClient.verdictJSON = #"{"decision":"DENY","reason":"Deletes a mailbox."}"#

        let results = await gate(
            [call(ToolNames.uiClick, #"{"x":10,"y":10}"#)],
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .strict))

        assertIsComputerUseDeny(results[0])
        XCTAssertTrue(
            denyMessage(results[0]).contains("Deletes a mailbox"),
            "the judge's reason must reach the model, got: \(denyMessage(results[0]))")
    }

    // MARK: - resolved(): allowlist, self-guard, bounds

    /// Allowlist matching is case-insensitive on BOTH sides (stored entries and the model's
    /// spec are lowercased before comparison), and a non-matching target denies. Auto +
    /// Safety Off is used so the allowlist is the ONLY thing that can deny — a pass-through
    /// at index 0 proves the match, a deny at index 1 proves the deny arm.
    func testAllowlist_matchesTargetSpecCaseInsensitively_andDeniesEverythingElse() async {
        let results = await gate(
            [
                call(ToolNames.uiClick, #"{"x":10,"y":10,"target":"zzzphantomapp"}"#, providerID: "in"),
                call(ToolNames.uiClick, #"{"x":10,"y":10,"target":"ZZZOtherApp"}"#, providerID: "out"),
            ],
            policy: ComputerUsePolicy(
                mode: .auto, restrictionLevel: .off, targetAppAllowlist: ["ZZZPhantomApp"]))

        XCTAssertNil(results[0], "a differently-cased spelling of an allowlisted app must be allowed")
        assertIsComputerUseDeny(results[1])
        XCTAssertTrue(
            denyMessage(results[1]).contains("allowlist"),
            "the deny must name the allowlist, got: \(denyMessage(results[1]))")
        XCTAssertEqual(judgeClient.callCount, 0, "Safety = Off never reaches the judge")
    }

    /// The documented `else` arm of the allowlist resolution: a whole-screen action has no
    /// target to check, so a non-empty allowlist cannot restrict it → deny rather than
    /// silently letting an untargeted click through the restriction.
    func testAllowlist_untargetedAction_isDeniedWhenAnAllowlistIsConfigured() async {
        let results = await gate(
            [call(ToolNames.uiClick, #"{"x":10,"y":10}"#)],
            policy: ComputerUsePolicy(
                mode: .auto, restrictionLevel: .off, targetAppAllowlist: ["ZZZPhantomApp"]))

        assertIsComputerUseDeny(results[0])
        XCTAssertTrue(
            denyMessage(results[0]).contains("allowlist"),
            "an unrestrictable action must be refused by the allowlist, got: \(denyMessage(results[0]))")
    }

    /// An empty allowlist means "any app" — the same untargeted click that the configured
    /// allowlist refuses above must pass. Pins that the deny came from the allowlist and not
    /// from the untargeted-ness itself.
    func testAllowlist_empty_leavesUntargetedActionsAlone() async {
        let results = await gate(
            [call(ToolNames.uiClick, #"{"x":10,"y":10}"#)],
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .off))

        XCTAssertTrue(results.isEmpty, "no allowlist configured → no allowlist restriction")
    }

    /// The self-guard's by-name arm: a target spelled "NanoTeams" in any casing is refused
    /// before every other tier, including Auto + Safety Off which allows everything else.
    func testSelfGuard_targetNamedNanoTeams_isDeniedEvenWithSafetyOff() async {
        let results = await gate(
            [call(ToolNames.uiClick, #"{"x":10,"y":10,"target":"nAnOtEaMs"}"#)],
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .off))

        assertIsComputerUseDeny(results[0])
        XCTAssertTrue(
            denyMessage(results[0]).contains("NanoTeams"),
            "the deny must name the self-target, got: \(denyMessage(results[0]))")
        XCTAssertEqual(judgeClient.callCount, 0, "a self-target is never a judge question")
    }

    /// `pointerGlobalPoint` returns nil for a coordinate outside the captured image, which
    /// `resolved` turns into `clickInBounds == false` → hard deny. Never clamped onto a
    /// random display.
    func testPointerBounds_coordinateOutsideTheCapture_isDenied() async {
        seedCapture(pixelWidth: 1000, pixelHeight: 1000)

        let results = await gate(
            [call(ToolNames.uiClick, #"{"x":5000,"y":5000}"#)],
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .off))

        assertIsComputerUseDeny(results[0])
        XCTAssertTrue(
            denyMessage(results[0]).contains("outside the captured"),
            "the deny must name the bounds failure, got: \(denyMessage(results[0]))")
    }

    /// The upper bound is EXCLUSIVE: `pixelWidth` is one past the last addressable column,
    /// so a click there is out of bounds while `pixelWidth - 1` is inside.
    func testPointerBounds_upperEdgeIsExclusive() async {
        seedCapture(pixelWidth: 1000, pixelHeight: 1000)

        let results = await gate(
            [
                call(ToolNames.uiClick, #"{"x":999,"y":999}"#, providerID: "inside"),
                call(ToolNames.uiClick, #"{"x":1000,"y":999}"#, providerID: "past-edge"),
            ],
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .off))

        XCTAssertNil(results[0], "the last addressable pixel is in bounds")
        assertIsComputerUseDeny(results[1])
        XCTAssertTrue(denyMessage(results[1]).contains("outside the captured"))
    }

    /// With no capture yet, bounds are UNKNOWN (nil), not false — the gate must not deny a
    /// coordinate it cannot check; the finalizer errors instead. Same click that the seeded
    /// capture above denies.
    func testPointerBounds_withNoCaptureYet_areUnknownRatherThanOutOfBounds() async {
        let results = await gate(
            [call(ToolNames.uiClick, #"{"x":5000,"y":5000}"#)],
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .off))

        XCTAssertTrue(
            results.isEmpty,
            "an uncheckable coordinate must not be denied as out-of-bounds before any capture")
    }

    /// Scroll is a pointer action too, so it goes through the same bounds resolution — its
    /// read-only auto-allow must not skip the geometry check.
    func testPointerBounds_scrollIsBoundsCheckedLikeAClick() async {
        seedCapture(pixelWidth: 1000, pixelHeight: 1000)

        let results = await gate(
            [call(ToolNames.uiScroll, #"{"x":9999,"y":10,"dx":0,"dy":-120}"#)],
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard))

        assertIsComputerUseDeny(results[0])
        XCTAssertTrue(
            denyMessage(results[0]).contains("outside the captured"),
            "a scroll's read-only tier must not bypass the bounds check, got: \(denyMessage(results[0]))")
    }

    // MARK: - gateComputerUseCalls: interception scope and index keying

    /// The gate only intercepts tools the role is actually authorised for. A computer-use
    /// call absent from `allowedToolNames` is left to the runtime authorisation layer — even
    /// under mode Off, which would otherwise deny it.
    func testGate_computerUseCallNotInAllowedToolNames_isNotIntercepted() async {
        let results = await gate(
            [call(ToolNames.uiClick, #"{"x":10,"y":10}"#)],
            policy: ComputerUsePolicy(mode: .off),
            allowedToolNames: [ToolNames.readFile])

        XCTAssertTrue(
            results.isEmpty,
            "an unauthorised tool is the authorisation layer's business, not the gate's")
    }

    /// No computer-use call in the batch at all → the gate returns without touching policy.
    func testGate_noComputerUseCalls_returnsEmpty() async {
        let results = await gate(
            [call(ToolNames.readFile, #"{"path":"a.txt"}"#)],
            policy: ComputerUsePolicy(mode: .off))

        XCTAssertTrue(results.isEmpty, "a non-computer-use batch is untouched")
    }

    /// The returned map is sparse and keyed by the call's ORIGINAL index in the batch —
    /// `+ToolIteration` merges it positionally, so re-keying by computer-use ordinal would
    /// attach a denial to the wrong tool call.
    func testGate_sparseMapIsKeyedByOriginalBatchIndex() async {
        let results = await gate(
            [
                call(ToolNames.readFile, #"{"path":"a.txt"}"#, providerID: "read"),
                call(ToolNames.uiClick, #"{"x":10,"y":10}"#, providerID: "click"),
                call(ToolNames.uiKey, #"{"keys":"cmd+q"}"#, providerID: "key"),
            ],
            policy: ComputerUsePolicy(mode: .off))

        XCTAssertNil(results[0], "the non-computer-use call must not be intercepted")
        XCTAssertEqual(Set(results.keys), Set([1, 2]), "denials must land on the original indices")
        XCTAssertEqual(results[1]?.toolName, ToolNames.uiClick)
        XCTAssertEqual(results[2]?.toolName, ToolNames.uiKey)
        XCTAssertEqual(results[1]?.providerID, "click",
                       "the synthetic result must inherit the call's provider id")
    }

    /// Mode Off denies every computer-use action and names the policy blocker.
    func testGate_modeOff_deniesAndNamesTheSetting() async {
        let results = await gate(
            [call(ToolNames.screenCapture, #"{"target":"screen"}"#)],
            policy: ComputerUsePolicy(mode: .off))

        assertIsComputerUseDeny(results[0])
        XCTAssertTrue(
            denyMessage(results[0]).contains("disabled"),
            "the deny must name the policy blocker, got: \(denyMessage(results[0]))")
    }

    /// Manual mode with nobody to ask denies, and the message names a recourse the MODEL can
    /// act on — rather than leaving an autonomous run wedged on an unexplained refusal, or
    /// telling it to open a Settings pane it cannot reach.
    func testGate_manualModeWithoutAHuman_deniesAndNamesTheSupervisorRecourse() async {
        let results = await gate(
            [call(ToolNames.uiClick, #"{"x":10,"y":10}"#)],
            policy: ComputerUsePolicy(mode: .manual),
            supervisorMode: .autonomous)

        assertIsComputerUseDeny(results[0])
        let message = denyMessage(results[0])
        XCTAssertTrue(message.contains("no human is available"),
                      "the deny must explain WHY it could not ask, got: \(message)")
        XCTAssertTrue(message.contains("Ask the supervisor"),
                      "the deny must name a model-reachable recourse, got: \(message)")
        XCTAssertFalse(message.contains("Settings"),
                       "the model cannot open a Settings pane, got: \(message)")
        XCTAssertEqual(judgeClient.callCount, 0,
                       "a non-Auto mode must never fall back to the unattended judge")
    }

    /// A cancelled step (Pause / teardown) resolves a held approval as deny — an unapproved
    /// action is never run.
    func testGate_cancellationWhileHolding_resolvesAsDeny() async {
        let (running, request) = await gateHolding(
            [call(ToolNames.uiClick, #"{"x":10,"y":10}"#)],
            policy: ComputerUsePolicy(mode: .manual))
        guard request != nil else { return }

        running.cancel()
        let results = await running.value
        assertIsComputerUseDeny(results[0])
    }

    /// An unparseable action fails CLOSED: the map is sparse-by-omission, so skipping it
    /// would have run the OS action ungated.
    func testGate_unparseableAction_isDeniedRatherThanPassedThrough() async {
        let results = await gate(
            [call(ToolNames.uiClick, #"{"y":10}"#)],
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .off))

        assertIsComputerUseDeny(results[0])
        XCTAssertTrue(
            denyMessage(results[0]).contains("parse"),
            "the deny must name the parse failure, got: \(denyMessage(results[0]))")
    }

    // MARK: - parseComputerUseAction

    /// Malformed / non-object arguments collapse to an empty dictionary. A capture then
    /// degrades to the whole screen (its only argument is optional), while every action that
    /// REQUIRES arguments returns nil so the gate denies rather than inventing coordinates.
    func testParse_malformedArguments_captureDegradesToScreen_pointerActionsReturnNil() async {
        for bad in ["not json at all", "", "[1,2,3]", "{", "null", "\"a string\""] {
            XCTAssertEqual(
                service.parseComputerUseAction(name: ToolNames.screenCapture, argsJSON: bad),
                ComputerUseAction.capture(target: "screen", windowTitle: nil),
                "a capture with unusable arguments must default to the whole screen: \(bad)")
            XCTAssertNil(
                service.parseComputerUseAction(name: ToolNames.uiClick, argsJSON: bad),
                "a click must not resolve without coordinates: \(bad)")
            XCTAssertNil(
                service.parseComputerUseAction(name: ToolNames.uiScroll, argsJSON: bad),
                "a scroll must not resolve without coordinates: \(bad)")
            XCTAssertNil(
                service.parseComputerUseAction(name: ToolNames.uiType, argsJSON: bad),
                "typing must not resolve without text: \(bad)")
            XCTAssertNil(
                service.parseComputerUseAction(name: ToolNames.uiKey, argsJSON: bad),
                "a key press must not resolve without keys: \(bad)")
        }
    }

    /// A tool the gate does not own resolves to nil. Combined with the caller's
    /// `computerUseTools` membership guard this is belt-and-braces, but a hallucinated
    /// `ui_hover` reaching the parser must not become some other action.
    func testParse_unknownOrNonComputerUseToolName_returnsNil() async {
        for name in ["ui_hover", "ui_drag", ToolNames.readFile, "", "   "] {
            XCTAssertNil(
                service.parseComputerUseAction(name: name, argsJSON: #"{"x":1,"y":2}"#),
                "\(name) is not a computer-use action")
        }
    }

    /// Only one coordinate is not enough for either pointer action — both are required, and
    /// a missing one must not silently default to the origin.
    func testParse_pointerActions_requireBothCoordinates() async {
        for tool in [ToolNames.uiClick, ToolNames.uiScroll] {
            XCTAssertNil(service.parseComputerUseAction(name: tool, argsJSON: #"{"x":10}"#),
                         "\(tool) must reject a missing y")
            XCTAssertNil(service.parseComputerUseAction(name: tool, argsJSON: #"{"y":10}"#),
                         "\(tool) must reject a missing x")
            XCTAssertNil(service.parseComputerUseAction(name: tool, argsJSON: #"{}"#),
                         "\(tool) must reject empty arguments")
        }
    }

    /// Scroll deltas are optional and default to zero; the parse wires them through
    /// unchanged, negatives included.
    func testParse_scroll_deltasDefaultToZeroAndKeepTheirSign() async {
        XCTAssertEqual(
            service.parseComputerUseAction(name: ToolNames.uiScroll, argsJSON: #"{"x":1,"y":2}"#),
            ComputerUseAction.scroll(x: 1, y: 2, dx: 0, dy: 0, target: nil),
            "absent deltas mean no movement, not a rejected call")
        XCTAssertEqual(
            service.parseComputerUseAction(
                name: ToolNames.uiScroll, argsJSON: #"{"x":1,"y":2,"dx":-120,"dy":40}"#),
            ComputerUseAction.scroll(x: 1, y: 2, dx: -120, dy: 40, target: nil))
    }

    /// The parse routes `button` through `ComputerUseAction.normalizedButton` — the shared
    /// resolver — so only an explicit right stays right. Anything the model spelled some
    /// other way must not silently become the more disruptive action.
    func testParse_click_buttonIsNormalizedThroughTheSharedResolver() async {
        func button(_ json: String) -> String? {
            if case .click(_, _, let b, _, _)? =
                service.parseComputerUseAction(name: ToolNames.uiClick, argsJSON: json) { return b }
            return nil
        }
        XCTAssertEqual(button(#"{"x":1,"y":2,"button":"RIGHT"}"#), "right", "casing must not matter")
        XCTAssertEqual(button(#"{"x":1,"y":2,"button":"  right  "}"#), "right", "padding must not matter")
        XCTAssertEqual(button(#"{"x":1,"y":2,"button":"middle"}"#), "left",
                       "an unrecognised button must not escalate to right-click")
        XCTAssertEqual(button(#"{"x":1,"y":2}"#), "left", "absent button means left")
    }

    /// `ui_type` accepts the model's common misspellings of `text` through the shared
    /// content resolver, and refuses an empty payload outright.
    func testParse_uiType_acceptsContentAliases_andRejectsEmptyText() async {
        XCTAssertEqual(
            service.parseComputerUseAction(name: ToolNames.uiType, argsJSON: #"{"text":"hello"}"#),
            ComputerUseAction.typeText(text: "hello", target: nil))
        XCTAssertEqual(
            service.parseComputerUseAction(name: ToolNames.uiType, argsJSON: #"{"content":"hello"}"#),
            ComputerUseAction.typeText(text: "hello", target: nil),
            "`content` is the canonical alias the shared resolver checks first")
        XCTAssertNil(
            service.parseComputerUseAction(name: ToolNames.uiType, argsJSON: #"{"text":""}"#),
            "an empty string is nothing to type")
    }

    /// `ui_key` accepts the singular `key` spelling and refuses an empty combination.
    func testParse_uiKey_acceptsSingularAlias_andRejectsEmptyKeys() async {
        XCTAssertEqual(
            service.parseComputerUseAction(name: ToolNames.uiKey, argsJSON: #"{"keys":"cmd+s"}"#),
            ComputerUseAction.pressKey(keys: "cmd+s", target: nil))
        XCTAssertEqual(
            service.parseComputerUseAction(name: ToolNames.uiKey, argsJSON: #"{"key":"tab"}"#),
            ComputerUseAction.pressKey(keys: "tab", target: nil),
            "the singular spelling is a routine model emission")
        XCTAssertNil(
            service.parseComputerUseAction(name: ToolNames.uiKey, argsJSON: #"{"keys":""}"#),
            "an empty combination is nothing to press")
    }

    /// A blank target — absent, empty, or whitespace — must resolve to "no app targeted"
    /// (whole screen / frontmost app) rather than a phantom app named "  ". The
    /// security-relevant value is `appTargetSpec`, which is what the allowlist, the
    /// self-guard and the judge all read.
    func testParse_blankTargets_resolveToNoAppTarget() async {
        for json in [#"{"target":""}"#, #"{"target":"   "}"#, #"{}"#] {
            let action = service.parseComputerUseAction(name: ToolNames.screenCapture, argsJSON: json)
            XCTAssertNotNil(action, "a capture always parses: \(json)")
            XCTAssertNil(action?.appTargetSpec,
                         "a blank capture target means the whole screen: \(json)")
        }
        for json in [#"{"x":1,"y":2,"target":""}"#, #"{"x":1,"y":2,"target":"   "}"#, #"{"x":1,"y":2}"#] {
            let action = service.parseComputerUseAction(name: ToolNames.uiClick, argsJSON: json)
            XCTAssertNotNil(action, "a click with coordinates always parses: \(json)")
            XCTAssertNil(action?.appTargetSpec,
                         "a blank click target means the frontmost app: \(json)")
        }
    }

    /// `window_title` narrows the capture when given and is dropped when blank — an empty
    /// substring would match every window and is not a narrowing the model asked for.
    func testParse_screenCapture_windowTitleIsKeptWhenGivenAndDroppedWhenBlank() async {
        XCTAssertEqual(
            service.parseComputerUseAction(
                name: ToolNames.screenCapture, argsJSON: #"{"target":"Notes","window_title":"Draft"}"#),
            ComputerUseAction.capture(target: "Notes", windowTitle: "Draft"))
        XCTAssertEqual(
            service.parseComputerUseAction(
                name: ToolNames.screenCapture, argsJSON: #"{"target":"Notes","window_title":""}"#),
            ComputerUseAction.capture(target: "Notes", windowTitle: nil),
            "an empty window title is not a narrowing")
    }

    // MARK: - Routing arguments are never mistaken for content

    /// `resolveContentString` ends in "the single remaining String argument is
    /// the content". It was written for the file tools, so its exclusion list
    /// knows nothing about this feature — and `ui_type` with a target and no
    /// text therefore resolved its text to the TARGET and typed the app's own
    /// name into it. Under Auto approval the judge would have seen a perfectly
    /// plausible `typeText`.
    func testParse_uiType_targetIsNeverUsedAsTheTextToType() async {
        XCTAssertNil(
            service.parseComputerUseAction(
                name: ToolNames.uiType, argsJSON: #"{"target":"Safari"}"#),
            "a type with no text must be REJECTED, never resolved to the target name")

        for json in [
            #"{"target":"Safari","window_title":"Inbox"}"#,
            #"{"keys":"cmd+v"}"#,
            #"{"button":"left"}"#,
        ] {
            XCTAssertNil(
                service.parseComputerUseAction(name: ToolNames.uiType, argsJSON: json),
                "no routing argument may become typed text: \(json)")
        }

        // The genuine content aliases must still work — the exclusion list must
        // not be so wide that it breaks the recovery path it sits next to.
        XCTAssertEqual(
            service.parseComputerUseAction(
                name: ToolNames.uiType, argsJSON: #"{"target":"Safari","text":"hello"}"#),
            ComputerUseAction.typeText(text: "hello", target: "Safari"))
        XCTAssertEqual(
            service.parseComputerUseAction(
                name: ToolNames.uiType, argsJSON: #"{"target":"Safari","content":"hello"}"#),
            ComputerUseAction.typeText(text: "hello", target: "Safari"),
            "excluding `target` must not disable the `content` alias beside it")
    }

    /// `optionalString` is a bare `as? String`, so a present-but-EMPTY value is
    /// non-nil and short-circuits `??`. A blank `keys` used to swallow a valid
    /// singular `key` — the model's keypress was silently dropped and the step
    /// burned an iteration discovering nothing.
    func testParse_uiKey_blankPluralDoesNotSwallowTheSingularSpelling() async {
        XCTAssertEqual(
            service.parseComputerUseAction(
                name: ToolNames.uiKey, argsJSON: #"{"keys":"","key":"Return"}"#),
            ComputerUseAction.pressKey(keys: "Return", target: nil),
            "an empty `keys` must fall through to `key`, not short-circuit to nothing")

        XCTAssertNil(
            service.parseComputerUseAction(
                name: ToolNames.uiKey, argsJSON: #"{"keys":"","key":""}"#),
            "both blank is still nothing to press")

        XCTAssertEqual(
            service.parseComputerUseAction(
                name: ToolNames.uiKey, argsJSON: #"{"keys":"cmd+s","key":"Return"}"#),
            ComputerUseAction.pressKey(keys: "cmd+s", target: nil),
            "a non-empty plural still wins — precedence is unchanged")
    }

    /// Same short-circuit, other spelling: an empty `text` must fall through to
    /// the content aliases rather than rejecting the call outright.
    func testParse_uiType_blankTextFallsThroughToTheContentAlias() async {
        XCTAssertEqual(
            service.parseComputerUseAction(
                name: ToolNames.uiType, argsJSON: #"{"text":"","content":"hello"}"#),
            ComputerUseAction.typeText(text: "hello", target: nil))
    }
}

// MARK: - Stub

/// Records the judge consultation (count + the exact user prompt the gate's
/// `judgeContext` produced) and returns a scriptable verdict. Defaults to OK so the
/// `judgeContext` tests observe the pass-through path; flip `verdictJSON` for the deny case.
private final class RecordingComputerUseJudgeClient: LLMClient, @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var lastMessages: [ChatMessage] = []
    var verdictJSON = #"{"decision":"OK","reason":"ok"}"#

    /// The `user` turn — where `ComputerUseJudgeService.userPrompt` renders the context the
    /// gate resolved (target app, window title, element label, staleness note).
    var lastUserPrompt: String {
        lastMessages.first(where: { $0.role == .user })?.content ?? ""
    }

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        callCount += 1
        lastMessages = messages
        let verdict = verdictJSON
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: verdict))
            continuation.finish()
        }
    }

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
}
