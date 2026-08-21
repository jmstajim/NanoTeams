import XCTest

@testable import NanoTeams

/// String-typed coordinates through the computer-use path.
///
/// CLAUDE.md carries a hard invariant: the permission GATE and the HANDLER must resolve
/// arguments through the SAME resolver, or the gate judges something other than what
/// executes. `parseComputerUseAction` (gate) uses `optionalInt` / `optionalBool`; the
/// handlers use `requiredInt` / `optionalInt` / `optionalBool`. Both now funnel into the
/// private `coerceInt` / `coerceBool`, and that agreement is otherwise unpinned — a
/// regression that de-coerced ONE side would let a reviewer approve "left-click at (0,0)"
/// while a double-click at (834, 12) actually runs.
///
/// SAFETY: nothing here posts a CGEvent, moves the pointer, types, or captures the screen.
/// The handlers are pure argument-resolution + `.computerUse(action)` signal emission; the
/// OS action lives in the service finalizer, which is never invoked.
///
/// `@MainActor` + `async` for every test that touches `service`, per the documented
/// sync-test abort gotcha (constructing the `@MainActor` `LLMExecutionService` from a
/// synchronous test method aborts on CI). `setUp` is immune.
@MainActor
final class ComputerUseCoercionTests: XCTestCase {

    var service: LLMExecutionService!
    var delegate: MockLLMExecutionDelegate!
    // Class-level, not a local inside a @MainActor helper — constructing a class
    // instance as a local in a @MainActor test method aborts on this Xcode.
    // `private` because the stub type is file-scoped.
    private var judgeClient: UnusedJudgeClient!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        delegate.snapshot = nil  // → not under Autovisor
        service.attach(delegate: delegate)
        judgeClient = UnusedJudgeClient()
    }

    override func tearDown() async throws {
        service = nil
        delegate = nil
        judgeClient = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func ctx() -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: URL(fileURLWithPath: "/tmp"), taskID: 1, runID: 0, roleID: "role")
    }

    private func signalAction(_ result: ToolExecutionResult) -> ComputerUseAction? {
        if case .computerUse(let a)? = result.signal { return a }
        return nil
    }

    /// The gate's view of a tool call: parsed straight from the raw arguments JSON.
    private func gateAction(_ tool: String, _ argsJSON: String) -> ComputerUseAction? {
        service.parseComputerUseAction(name: tool, argsJSON: argsJSON)
    }

    /// Pure-evaluator input with the same shape `ComputerUsePermissionServiceTests` uses.
    private func evalInput(
        _ action: ComputerUseAction,
        isSelf: Bool = false, allowed: Bool = true, session: Bool = false,
        bounds: Bool? = nil, captured: Bool = false
    ) -> ComputerUseEvalInput {
        ComputerUseEvalInput(
            action: action, isSelfTarget: isSelf, targetAllowedByAllowlist: allowed,
            sessionPreApproved: session, clickInBounds: bounds, captureAlreadyOccurredThisRun: captured)
    }

    private func isDeny(_ d: ComputerUsePermissionDecision) -> Bool { if case .deny = d { return true }; return false }

    private func task() -> NTMSTask { NTMSTask(id: 1, title: "t", supervisorTask: "g", runs: []) }

    private func gate(
        _ calls: [StepToolCall], policy: ComputerUsePolicy
    ) async -> [Int: ToolExecutionResult] {
        delegate.computerUsePolicy = policy
        return await service.gateComputerUseCalls(
            resolvedToolCalls: calls,
            allowedToolNames: ToolHandlerRegistry.computerUseTools,
            stepID: "step1",
            taskID: 1,
            // Autonomous → no human is available, so a `.ask` can only ever resolve to a
            // deny. Combined with Safety=Off below, no test here can reach the judge.
            supervisorMode: .autonomous,
            task: task(),
            client: judgeClient,
            config: LLMConfig(),
            networkLogger: nil)
    }

    // MARK: - Gate ↔ handler agreement

    /// The headline invariant: a quoted coordinate resolves to the SAME pixel on both
    /// sides. A regression removing coercion from either side changes what runs relative
    /// to what was reviewed (or wedges a valid click into a hard deny).
    func testQuotedCoordinates_gateAndHandlerResolveTheSamePixel() async {
        let json = #"{"x":"501","y":"7"}"#

        guard case .click(let gx, let gy, _, _, _)? = gateAction(ToolNames.uiClick, json) else {
            return XCTFail("gate must parse quoted coordinates into a .click")
        }
        XCTAssertEqual(gx, 501, "gate x")
        XCTAssertEqual(gy, 7, "gate y")

        let r = UIClickTool().handle(context: ctx(), args: ["x": "501", "y": "7"])
        guard case .click(let hx, let hy, _, _, _)? = signalAction(r) else {
            return XCTFail("handler must emit a .click for quoted coordinates, got: \(r.outputJSON)")
        }
        XCTAssertEqual(hx, 501, "handler x")
        XCTAssertEqual(hy, 7, "handler y")
    }

    /// Whitespace padding is a routine model emission. Dropping the trim would turn a
    /// working click into a hard deny (gate) / INVALID_ARGS (handler).
    func testWhitespacePaddedCoordinates_resolveOnBothSides() async {
        guard case .click(let gx, let gy, _, _, _)? = gateAction(ToolNames.uiClick, "{\"x\":\" 501 \",\"y\":\"\\t7\\n\"}") else {
            return XCTFail("gate must trim whitespace around quoted coordinates")
        }
        XCTAssertEqual(gx, 501)
        XCTAssertEqual(gy, 7)

        let r = UIClickTool().handle(context: ctx(), args: ["x": " 501 ", "y": "\t7\n"])
        guard case .click(let hx, let hy, _, _, _)? = signalAction(r) else {
            return XCTFail("handler must trim whitespace, got: \(r.outputJSON)")
        }
        XCTAssertEqual(hx, 501)
        XCTAssertEqual(hy, 7)
    }

    /// CLAUDE.md's click-aiming note: the handler TRUNCATES a fractional coordinate and
    /// clicks it. If the gate rounded (or rejected) instead, the reviewed point and the
    /// clicked point would be different pixels. Truncation is toward zero on both signs.
    func testFractionalQuotedCoordinates_truncateTowardZeroOnBothSides() async {
        let json = #"{"x":"834.9","y":"-2.9"}"#

        guard case .click(let gx, let gy, _, _, _)? = gateAction(ToolNames.uiClick, json) else {
            return XCTFail("gate must accept a fractional quoted coordinate")
        }
        XCTAssertEqual(gx, 834, "834.9 must truncate to 834, not round to 835")
        XCTAssertEqual(gy, -2, "-2.9 must truncate toward zero to -2, not to -3")

        let r = UIClickTool().handle(context: ctx(), args: ["x": "834.9", "y": "-2.9"])
        guard case .click(let hx, let hy, _, _, _)? = signalAction(r) else {
            return XCTFail("handler must accept a fractional quoted coordinate, got: \(r.outputJSON)")
        }
        XCTAssertEqual(hx, 834, "handler must truncate identically to the gate")
        XCTAssertEqual(hy, -2, "handler must truncate identically to the gate")
    }

    /// A negative coordinate must survive as negative. Absolutizing or dropping the sign
    /// would turn an out-of-bounds point (which the bounds check denies) into a real
    /// on-screen pixel — a bypass, not a formatting detail.
    func testNegativeQuotedCoordinate_keepsItsSign() async {
        guard case .click(let gx, let gy, _, _, _)? = gateAction(ToolNames.uiClick, #"{"x":"-5","y":"-9"}"#) else {
            return XCTFail("gate must parse a negative quoted coordinate")
        }
        XCTAssertEqual(gx, -5)
        XCTAssertEqual(gy, -9)

        let r = UIClickTool().handle(context: ctx(), args: ["x": "-5", "y": "-9"])
        guard case .click(let hx, let hy, _, _, _)? = signalAction(r) else {
            return XCTFail("handler must parse a negative quoted coordinate, got: \(r.outputJSON)")
        }
        XCTAssertEqual(hx, -5)
        XCTAssertEqual(hy, -9)
    }

    /// `double` drives the reviewed text (`action.detail` → the judge prompt and the human
    /// approval card). A quoted "true" that only ONE side honors means the reviewer approves
    /// a single click and a double-click runs.
    func testQuotedDoubleFlag_isHonoredOnBothSides() async {
        guard case .click(_, _, _, let gDouble, _)? = gateAction(ToolNames.uiClick, #"{"x":1,"y":1,"double":"true"}"#) else {
            return XCTFail("expected a .click from the gate")
        }
        XCTAssertTrue(gDouble, "gate must honor a quoted boolean")

        let r = UIClickTool().handle(context: ctx(), args: ["x": 1, "y": 1, "double": "true"])
        guard case .click(_, _, _, let hDouble, _)? = signalAction(r) else {
            return XCTFail("expected a .click from the handler")
        }
        XCTAssertTrue(hDouble, "handler must honor a quoted boolean")

        // The reviewer-facing text must reflect it — that is the whole reason the flag
        // has to agree across the two sides.
        XCTAssertTrue(
            ComputerUseAction.click(x: 1, y: 1, button: "left", double: gDouble, target: nil)
                .detail.contains("Double"),
            "the reviewed detail text must announce a double-click")
    }

    /// Scroll deltas default to 0 when absent. A quoted delta that the gate drops (→ 0)
    /// but the handler honors means the reviewed action ("Scroll (0, 0)") is not the
    /// executed one.
    func testQuotedScrollDeltas_areHonoredOnBothSides() async {
        guard case .scroll(let gx, let gy, let gdx, let gdy, _)? =
            gateAction(ToolNames.uiScroll, #"{"x":"5","y":"6","dx":"-120","dy":"40"}"#) else {
            return XCTFail("gate must parse quoted scroll arguments")
        }
        XCTAssertEqual([gx, gy, gdx, gdy], [5, 6, -120, 40], "gate scroll x/y/dx/dy")

        let r = UIScrollTool().handle(
            context: ctx(), args: ["x": "5", "y": "6", "dx": "-120", "dy": "40"])
        guard case .scroll(let hx, let hy, let hdx, let hdy, _)? = signalAction(r) else {
            return XCTFail("handler must parse quoted scroll arguments, got: \(r.outputJSON)")
        }
        XCTAssertEqual([hx, hy, hdx, hdy], [5, 6, -120, 40], "handler scroll x/y/dx/dy")
    }

    // MARK: - Coercion buys no bypass

    /// Sloppy typing must not weaken any decision tier. The coerced action is the SAME
    /// domain value as the numeric one, so self-guard, bounds, allowlist and the
    /// session short-circuit all rule on it identically.
    func testCoercedAction_evaluatesIdenticallyToTheNumericAction() async {
        guard let coerced = gateAction(ToolNames.uiClick, #"{"x":"9999","y":"9999","target":"SomeApp"}"#),
              let numeric = gateAction(ToolNames.uiClick, #"{"x":9999,"y":9999,"target":"SomeApp"}"#) else {
            return XCTFail("both spellings must parse")
        }
        // Equality of the domain action is the whole claim. A follow-up loop
        // comparing `evaluate()` across permission tiers was removed on review:
        // `evalInput` derives entirely from the action, so once the actions are
        // equal the two inputs are structurally equal and the comparison reduces
        // to `f(x) == f(x)` — unfailable. The tiers that matter are pinned
        // against absolute expectations below, not against each other.
        XCTAssertEqual(coerced, numeric, "a quoted coordinate must produce the identical domain action")
    }

    /// The specific case that must not become a bypass: a point that is out of bounds as a
    /// number is out of bounds as a string. Asserts the decision is a DENY (not merely
    /// "equal to the numeric decision", which would also hold if both wrongly allowed).
    func testOutOfBoundsQuotedCoordinate_denies() async {
        guard let coerced = gateAction(ToolNames.uiClick, #"{"x":"9999","y":"9999"}"#) else {
            return XCTFail("expected a parsed .click")
        }
        let d = ComputerUsePermissionService.evaluate(
            evalInput(coerced, bounds: false), policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .off))
        XCTAssertTrue(isDeny(d), "an out-of-bounds click must deny even with Safety = Off")
    }

    // MARK: - Fail closed

    /// The gate's contract is sparse-by-omission: an index ABSENT from the returned map
    /// passes through to execution. So an unparseable action must produce a synthetic
    /// deny — silently skipping it would run the OS action ungated.
    ///
    /// Both calls share one policy (Auto + Safety Off) under which a well-formed click is
    /// allowed with no judge and no human, which is what makes the contrast sharp:
    /// index 0 (quoted, valid) passes through, index 1 (garbage) is denied.
    func testUnparseableCoordinate_gateDenies_whileValidQuotedCoordinatePassesThrough() async {
        let calls = [
            StepToolCall(providerID: "ok", name: ToolNames.uiClick, argumentsJSON: #"{"x":"501","y":"7"}"#),
            StepToolCall(providerID: "bad", name: ToolNames.uiClick, argumentsJSON: #"{"x":"501abc","y":7}"#),
        ]
        let results = await gate(calls, policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .off))

        XCTAssertNil(results[0], "a valid quoted coordinate must not be denied by the gate")
        guard let denied = results[1] else {
            return XCTFail("an unparseable coordinate must be intercepted, not passed through to execution")
        }
        XCTAssertTrue(denied.isError, "the interception must be an error result")
        XCTAssertTrue(
            denied.outputJSON.contains("COMPUTER_USE_DENIED"),
            "expected a computer-use deny envelope, got: \(denied.outputJSON)")
        XCTAssertTrue(
            denied.outputJSON.contains("parse"),
            "the deny must name the parse failure (not the no-human reason): \(denied.outputJSON)")
        XCTAssertEqual(
            judgeClient.callCount, 0,
            "an unparseable action must be denied outright, never sent to the judge for a verdict")
    }

    /// JSON `null` for a required coordinate must also fail closed at the gate.
    func testNullCoordinate_gateDenies() async {
        let calls = [StepToolCall(name: ToolNames.uiClick, argumentsJSON: #"{"x":null,"y":7}"#)]
        let results = await gate(calls, policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .off))

        guard let denied = results[0] else {
            return XCTFail("a null coordinate must be intercepted, not passed through to execution")
        }
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(
            denied.outputJSON.contains("parse"),
            "expected the parse-failure deny, got: \(denied.outputJSON)")
        XCTAssertEqual(judgeClient.callCount, 0, "a null coordinate must never reach the judge")
    }

    /// A coordinate no `Int` can hold must resolve to nil, not trap. `Int(1e300)` is a
    /// runtime crash and that literal can arrive straight from a model — if the exactness
    /// check regressed, this test takes the whole process down rather than failing.
    func testOverflowingCoordinate_deniesWithoutTrapping() async {
        XCTAssertNil(
            gateAction(ToolNames.uiClick, #"{"x":"1e300","y":7}"#),
            "an out-of-Int-range coordinate must not resolve")

        let r = UIClickTool().handle(context: ctx(), args: ["x": "1e300", "y": 7])
        XCTAssertTrue(r.isError, "the handler must reject an out-of-range coordinate")
        XCTAssertNil(r.signal, "a rejected coordinate must not emit a computer-use signal")
    }

    /// The point of the new `invalidValue` case: an argument the model DID send must not
    /// be reported as missing — that sends it hunting for a phantom omission instead of
    /// fixing the type. Asserting only `error is ToolArgumentError` would pass for both.
    func testCoordinateErrors_distinguishAbsentFromUncoercible() async {
        let absent = UIClickTool().handle(context: ctx(), args: ["y": 10])
        XCTAssertTrue(
            absent.outputJSON.contains("Missing required argument: x"),
            "an omitted coordinate must report as missing, got: \(absent.outputJSON)")

        let garbage = UIClickTool().handle(context: ctx(), args: ["x": "501abc", "y": 10])
        XCTAssertTrue(
            garbage.outputJSON.contains("Argument 'x' must be an integer"),
            "a present-but-uncoercible coordinate must report the type, got: \(garbage.outputJSON)")
        XCTAssertFalse(
            garbage.outputJSON.contains("Missing required"),
            "an argument the model sent must never be reported as missing")

        // JSON null is treated as an omission, not a malformed value.
        let null = UIClickTool().handle(context: ctx(), args: ["x": NSNull(), "y": 10])
        XCTAssertTrue(
            null.outputJSON.contains("Missing required argument: x"),
            "a null coordinate counts as absent, got: \(null.outputJSON)")
    }

    /// `ui_scroll` requires x/y too — an unparseable one must not silently degrade into a
    /// scroll at the origin (both handler and gate reject rather than defaulting).
    func testUnparseableScrollCoordinate_rejectedRatherThanDefaultedToOrigin() async {
        XCTAssertNil(
            gateAction(ToolNames.uiScroll, #"{"x":"","y":"6","dx":0,"dy":-3}"#),
            "an empty-string coordinate must not resolve to 0")

        let r = UIScrollTool().handle(context: ctx(), args: ["x": "", "y": "6"])
        XCTAssertTrue(r.isError, "the handler must reject an empty-string coordinate")
        XCTAssertNil(r.signal, "a rejected scroll must not emit a computer-use signal")
    }
}

// MARK: - Stub

/// Satisfies the gate's `client:` parameter and records whether the judge was consulted.
/// Every test here uses a policy under which the judge is unreachable (Auto + Safety Off
/// allows, or the action is denied before evaluation), so the gate tests assert
/// `callCount == 0`: a deny must be the gate's own verdict, not a judge round-trip.
/// Returns DENY if ever called, so a routing regression cannot accidentally pass.
private final class UnusedJudgeClient: LLMClient, @unchecked Sendable {
    private(set) var callCount = 0

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        callCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: #"{"decision":"DENY","reason":"unexpected judge call"}"#))
            continuation.finish()
        }
    }

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
}
