import CoreGraphics
import Foundation

@testable import NanoTeams

// MARK: - Input control

/// Records every act of input synthesis instead of performing it.
///
/// The whole reason `InputControlling` exists: the live adapter clicks, scrolls and types at
/// whatever is under the developer's cursor. A suite driving the computer-use dispatcher against
/// the real thing would operate their machine — dozens of times, and hardest precisely on the RED
/// run of a cancellation pin, which fails by clicking.
final class FakeInputControl: InputControlling, @unchecked Sendable {

    struct ClickCall: Equatable {
        let point: CGPoint
        let button: MouseButton
        let double: Bool
    }

    struct ScrollCall: Equatable {
        let point: CGPoint
        let dx: Int
        let dy: Int
    }

    /// What `hasAccessibility()` answers. `true` by default because the permission gate is a
    /// precondition of nearly every test here, not the subject of it — the tests that ARE about
    /// the gate flip it explicitly.
    var accessibilityGranted = true
    /// Specs `activateApp(matching:)` will claim to resolve. `nil` = resolve anything.
    var resolvableSpecs: Set<String>?
    /// Thrown by `pressKeys` when set — the unparseable-combo arm without depending on the real
    /// keycode table.
    var pressKeysError: Error?

    private(set) var accessibilityChecks = 0
    private(set) var trustPrompts = 0
    private(set) var clicks: [ClickCall] = []
    private(set) var scrolls: [ScrollCall] = []
    private(set) var typed: [String] = []
    private(set) var pressedKeys: [String] = []
    private(set) var activations: [String] = []

    /// Every input-synthesizing call in one ordered log, so a test can assert that NOTHING was
    /// synthesized without enumerating four separate arrays (and without silently missing the
    /// fifth someone adds later).
    private(set) var synthesisLog: [String] = []

    func hasAccessibility() -> Bool {
        accessibilityChecks += 1
        return accessibilityGranted
    }

    func requestAccessibilityIfNeeded() { trustPrompts += 1 }

    func click(globalPoint: CGPoint, button: MouseButton, double: Bool) {
        clicks.append(ClickCall(point: globalPoint, button: button, double: double))
        synthesisLog.append("click")
    }

    func scroll(globalPoint: CGPoint, dx: Int, dy: Int) {
        scrolls.append(ScrollCall(point: globalPoint, dx: dx, dy: dy))
        synthesisLog.append("scroll")
    }

    func typeText(_ text: String) {
        typed.append(text)
        synthesisLog.append("type")
    }

    func pressKeys(_ combo: String) throws {
        if let pressKeysError { throw pressKeysError }
        pressedKeys.append(combo)
        synthesisLog.append("key")
    }

    func activateApp(matching spec: String) -> Bool {
        activations.append(spec)
        guard let resolvableSpecs else { return true }
        return resolvableSpecs.contains(spec)
    }
}

// MARK: - Screen capture

final class FakeScreenCapture: ScreenCapturing, @unchecked Sendable {

    struct Call: Equatable {
        let targetSpec: String
        let windowTitle: String?
        let ownBundleID: String
    }

    var result: Result<CapturedScreen, Error>
    private(set) var calls: [Call] = []

    init(result: Result<CapturedScreen, Error> = .success(FakeScreenCapture.screenshot())) {
        self.result = result
    }

    /// A 100×100 pt region captured at 100×100 px at the global origin, so an image pixel maps to
    /// the identical global point and no test's assertion is obscured by coordinate arithmetic.
    static func screenshot(
        targetKind: String = "display", appName: String? = nil, bundleID: String? = nil,
        windowTitle: String? = nil, pid: pid_t? = nil
    ) -> CapturedScreen {
        CapturedScreen(
            pngBase64: "cG5n", pixelWidth: 100, pixelHeight: 100,
            regionWidthPt: 100, regionHeightPt: 100, originX: 0, originY: 0,
            targetKind: targetKind, appName: appName, bundleID: bundleID,
            windowTitle: windowTitle, displayID: nil, pid: pid)
    }

    func capture(targetSpec: String, windowTitle: String?, ownBundleID: String) async throws -> CapturedScreen {
        calls.append(Call(targetSpec: targetSpec, windowTitle: windowTitle, ownBundleID: ownBundleID))
        return try result.get()
    }
}

// MARK: - AX collection

final class FakeAXCollector: AXElementCollecting, @unchecked Sendable {
    var result: AXCollectionResult = .empty
    private(set) var requests: [AXCollectionRequest] = []

    func collectElements(_ request: AXCollectionRequest) async -> AXCollectionResult {
        requests.append(request)
        return result
    }
}

// MARK: - Environment builder

/// Assembles a `ComputerUseEnvironment` over the fakes above and keeps typed references to each,
/// so a test can arm one surface and assert on another without re-deriving the existentials.
struct FakeComputerUseEnvironment {
    let input = FakeInputControl()
    let screen = FakeScreenCapture()
    let ax = FakeAXCollector()
    let frontmost = FakeFrontmostApplicationProvider(app: nil)
    var ownBundleIdentifier: String? = "com.nanoteams.test"

    var environment: ComputerUseEnvironment {
        ComputerUseEnvironment(
            input: input, screen: screen, ax: ax, frontmost: frontmost,
            ownBundleIdentifier: ownBundleIdentifier,
            // Zero: the settle wait is real wall-clock time, and what these tests assert is the
            // cancellation check on either side of it, never its duration.
            activationSettleMilliseconds: 0)
    }
}
