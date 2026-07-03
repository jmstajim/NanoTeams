import XCTest

@testable import NanoTeams

/// Handler-level pins: each computer-use tool validates its args and emits the right
/// `.computerUse(action)` signal, or a non-signalling `INVALID_ARGS` error on bad input.
final class ComputerUseHandlersTests: XCTestCase {

    private let ctx = ToolExecutionContext(
        workFolderRoot: URL(fileURLWithPath: "/tmp"), taskID: 1, runID: 0, roleID: "role")

    private func action(_ result: ToolExecutionResult) -> ComputerUseAction? {
        if case .computerUse(let a)? = result.signal { return a }
        return nil
    }

    // MARK: - screen_capture

    func testScreenCapture_emitsCaptureSignal() {
        let r = ScreenCaptureTool().handle(context: ctx, args: ["target": "Safari", "window_title": "GitHub"])
        XCTAssertFalse(r.isError)
        guard case .capture(let t, let w)? = action(r) else { return XCTFail("expected .capture") }
        XCTAssertEqual(t, "Safari")
        XCTAssertEqual(w, "GitHub")
    }

    func testScreenCapture_missingTarget_defaultsToScreen() {
        let r = ScreenCaptureTool().handle(context: ctx, args: [:])
        guard case .capture(let t, let w)? = action(r) else { return XCTFail("expected .capture") }
        XCTAssertEqual(t, "screen")
        XCTAssertNil(w)
    }

    // MARK: - ui_click

    func testUIClick_emitsClickSignal() {
        let r = UIClickTool().handle(context: ctx, args: ["x": 10, "y": 20])
        guard case .click(let x, let y, let button, let dbl, _)? = action(r) else { return XCTFail("expected .click") }
        XCTAssertEqual(x, 10)
        XCTAssertEqual(y, 20)
        XCTAssertEqual(button, "left")   // default
        XCTAssertFalse(dbl)
    }

    func testUIClick_rightDouble() {
        let r = UIClickTool().handle(context: ctx, args: ["x": 1, "y": 2, "button": "right", "double": true])
        guard case .click(_, _, let button, let dbl, _)? = action(r) else { return XCTFail("expected .click") }
        XCTAssertEqual(button, "right")
        XCTAssertTrue(dbl)
    }

    func testUIClick_missingCoordinate_errorsWithoutSignal() {
        let r = UIClickTool().handle(context: ctx, args: ["x": 10])
        XCTAssertTrue(r.isError)
        XCTAssertNil(r.signal)
    }

    // MARK: - ui_type

    func testUIType_emitsSignal() {
        let r = UITypeTool().handle(context: ctx, args: ["text": "hello"])
        guard case .typeText(let t, _)? = action(r) else { return XCTFail("expected .typeText") }
        XCTAssertEqual(t, "hello")
    }

    func testUIType_emptyText_errorsWithoutSignal() {
        let r = UITypeTool().handle(context: ctx, args: ["text": ""])
        XCTAssertTrue(r.isError)
        XCTAssertNil(r.signal)
    }

    // MARK: - ui_key

    func testUIKey_emitsSignal() {
        let r = UIKeyTool().handle(context: ctx, args: ["keys": "cmd+s"])
        guard case .pressKey(let k, _)? = action(r) else { return XCTFail("expected .pressKey") }
        XCTAssertEqual(k, "cmd+s")
    }

    func testUIKey_missing_errorsWithoutSignal() {
        let r = UIKeyTool().handle(context: ctx, args: [:])
        XCTAssertTrue(r.isError)
        XCTAssertNil(r.signal)
    }

    // MARK: - ui_scroll

    func testUIScroll_defaultsDeltasToZero() {
        let r = UIScrollTool().handle(context: ctx, args: ["x": 5, "y": 6])
        guard case .scroll(let x, let y, let dx, let dy, _)? = action(r) else { return XCTFail("expected .scroll") }
        XCTAssertEqual(x, 5)
        XCTAssertEqual(y, 6)
        XCTAssertEqual(dx, 0)
        XCTAssertEqual(dy, 0)
    }
}
