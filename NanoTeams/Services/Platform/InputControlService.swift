import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// See `ClipboardCaptureService` for why this AX prompt key is inlined as a plain
/// `CFString` literal (Swift 6 data-race checker + the `var`-declared AX global).
nonisolated(unsafe) private let _cuTrustedCheckPromptKey: CFString = "AXTrustedCheckOptionPrompt" as CFString

// MARK: - Mouse Button

nonisolated enum MouseButton: String, Sendable {
    case left
    case right
}

// MARK: - Errors

/// `accessibilityDenied` is deliberately NOT a case here (wave 32): the trust guard lives
/// one layer up — `LLMExecutionService+ComputerUse` checks `hasAccessibility()` BEFORE any
/// input action and answers with its own `.computerUseDenied` envelope
/// (`LLMExecutionService.accessibilityDeniedMessage`), so a case here could never be thrown.
nonisolated enum InputControlError: LocalizedError {
    case unknownKeyCombo(String)

    var errorDescription: String? {
        switch self {
        case .unknownKeyCombo(let combo):
            "Unrecognized key combination '\(combo)'."
        }
    }
}

// MARK: - Seam

/// The input-synthesis surface the computer-use finalizer depends on, as a protocol so a test can
/// drive the dispatcher without a single `CGEvent` reaching the developer's cursor.
///
/// Everything here is impure by construction; every *decision* it would otherwise hide
/// (`mouseEventPlan`, `scrollDeltas`, `parseKeyCombo`, `bestAppIndex`, `imagePixelToGlobalPoint`)
/// is already a pure static on `InputControlService` and already covered. That is why the seam is
/// this thin: it exists to make the finalizer's *orchestration* reachable, not to re-test the
/// arithmetic through a mock.
///
/// `activateApp(matching:)` deliberately fuses resolve + activate: `NSRunningApplication` cannot be
/// constructed in a fixture, so it must never cross the seam. The `Bool` is "an app was found and
/// raised", which is exactly the fact the caller branches on.
nonisolated protocol InputControlling: Sendable {
    func hasAccessibility() -> Bool
    /// Raises the system Accessibility prompt (opens System Settings) if not already trusted.
    func requestAccessibilityIfNeeded()
    func click(globalPoint: CGPoint, button: MouseButton, double: Bool)
    func scroll(globalPoint: CGPoint, dx: Int, dy: Int)
    func typeText(_ text: String)
    func pressKeys(_ combo: String) throws
    /// Resolves `spec` to a running application and activates it. `false` = nothing matched.
    func activateApp(matching spec: String) -> Bool
}

/// The live adapter: one framework round-trip per method, no decision of its own.
nonisolated struct SystemInputControl: InputControlling {
    func hasAccessibility() -> Bool { InputControlService.hasAccessibility() }
    func requestAccessibilityIfNeeded() { InputControlService.requestAccessibilityIfNeeded() }

    func click(globalPoint: CGPoint, button: MouseButton, double: Bool) {
        InputControlService.click(globalPoint: globalPoint, button: button, double: double)
    }

    func scroll(globalPoint: CGPoint, dx: Int, dy: Int) {
        InputControlService.scroll(globalPoint: globalPoint, dx: dx, dy: dy)
    }

    func typeText(_ text: String) { InputControlService.typeText(text) }

    func pressKeys(_ combo: String) throws { try InputControlService.pressKeys(combo) }

    func activateApp(matching spec: String) -> Bool {
        guard let app = InputControlService.runningApp(matching: spec) else { return false }
        InputControlService.activate(app)
        return true
    }
}

/// Everything an untrusted process would do anyway: refuse. Used as the default so a test that
/// constructs `LLMExecutionService` without naming an environment cannot synthesize input — the
/// inward-resolving rule, and here it is not a nicety: the live adapter clicks and types at
/// whatever is under the developer's cursor.
///
/// `hasAccessibility() == false` is the honest inert answer — it is the state a process without the
/// grant is in, and it is the one that ends in "no input synthesized". Returning `true` instead
/// would let the no-op click report success, which is the exact defect the finalizer's permission
/// guard was added to fix.
///
/// `pressKeys` still throws for an unparseable combo: the parse is pure, so dropping only the OS
/// effect is what "inert" means here — a fake that silently accepted `"cmd+nonsense"` would hide a
/// real error arm.
nonisolated struct InertInputControl: InputControlling {
    func hasAccessibility() -> Bool { false }
    func requestAccessibilityIfNeeded() {}
    func click(globalPoint: CGPoint, button: MouseButton, double: Bool) {}
    func scroll(globalPoint: CGPoint, dx: Int, dy: Int) {}
    func typeText(_ text: String) {}

    func pressKeys(_ combo: String) throws {
        guard InputControlService.parseKeyCombo(combo) != nil else {
            throw InputControlError.unknownKeyCombo(combo)
        }
    }

    func activateApp(matching spec: String) -> Bool { false }
}

// MARK: - Input Control Service

/// Synthesizes mouse/keyboard/scroll input via `CGEvent`, resolves and activates target apps,
/// and converts image-pixel coordinates (the space the model saw) to global display points.
/// Stateless; the coordinate math is pure and unit-tested. **Invariant:** everything on this
/// path uses CoreGraphics **top-left global points** — never AppKit's bottom-left `NSScreen.frame`.
nonisolated enum InputControlService {

    // MARK: - Permission

    static func hasAccessibility() -> Bool { AXIsProcessTrusted() }

    static func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([_cuTrustedCheckPromptKey: true] as CFDictionary)
        }
    }

    // MARK: - Pure coordinate conversion (unit-tested)

    /// Maps an image-pixel coordinate (relative to the returned screenshot) to a global display
    /// point for `CGEvent`. Returns `nil` when the coordinate is outside the captured region —
    /// the caller turns that into an error envelope (never a clamped click on a random display).
    /// The single `regionPt / pixel` ratio folds BOTH the Retina scale and the downscale.
    ///
    /// Bounds are **half-open**: valid pixel coordinates are `0 ..< pixelWidth` (and height).
    /// `imageX == pixelWidth` is one past the last pixel column and maps to the region's far
    /// edge — a point OUTSIDE the captured content (over a neighbouring display / the display
    /// edge). Rejecting it keeps a click on an actual captured pixel.
    static func imagePixelToGlobalPoint(
        imageX: Double, imageY: Double,
        originX: Double, originY: Double,
        regionWidthPt: Double, regionHeightPt: Double,
        pixelWidth: Int, pixelHeight: Int
    ) -> CGPoint? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        guard imageX >= 0, imageY >= 0,
              imageX < Double(pixelWidth), imageY < Double(pixelHeight) else { return nil }
        let gx = originX + imageX * (regionWidthPt / Double(pixelWidth))
        let gy = originY + imageY * (regionHeightPt / Double(pixelHeight))
        return CGPoint(x: gx, y: gy)
    }

    /// Inverse of `imagePixelToGlobalPoint`: maps a global display point (CoreGraphics top-left
    /// points — the same space `CGEvent` / `CGDisplayBounds` use) INTO the screenshot's
    /// image-pixel space. Used to place AX element frames on the exact image the model sees, so
    /// a click on an element's reported `(x, y)` lands back on that element's global point.
    ///
    /// The single `pixel / regionPt` ratio is the reciprocal of the forward map's `regionPt /
    /// pixel`, so the two are exact inverses (`forward(inverse(g)) == g`). Returns `nil` only for
    /// degenerate (non-positive) region/pixel dimensions — NOT for out-of-region points, since
    /// an element can legitimately straddle the capture edge (the caller clips).
    static func globalPointToImagePixel(
        globalX: Double, globalY: Double,
        originX: Double, originY: Double,
        regionWidthPt: Double, regionHeightPt: Double,
        pixelWidth: Int, pixelHeight: Int
    ) -> (x: Double, y: Double)? {
        guard pixelWidth > 0, pixelHeight > 0, regionWidthPt > 0, regionHeightPt > 0 else { return nil }
        let ix = (globalX - originX) * (Double(pixelWidth) / regionWidthPt)
        let iy = (globalY - originY) * (Double(pixelHeight) / regionHeightPt)
        return (ix, iy)
    }

    // MARK: - Own-window self-guard (whole-display click occlusion)

    /// Pure containment test — true iff `point` (CG global top-left space) lands inside any of
    /// `rects`. Extracted so the self-window guard's geometry is unit-testable without a live
    /// window server. See `ownWindowFrames()` for the impure enumeration.
    static func pointInAnyRect(_ point: CGPoint, rects: [CGRect]) -> Bool {
        rects.contains { $0.contains(point) }
    }

    /// On-screen window frames owned by THIS process, in CoreGraphics global **top-left** points
    /// (the same space `imagePixelToGlobalPoint` returns). Used to deny a click that lands on a
    /// NanoTeams window that a whole-display capture filtered out of the image but which is still
    /// physically on screen — the model would otherwise click the app's own UI.
    static func ownWindowFrames() -> [CGRect] {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return ownWindowRects(from: infos, pid: Int(getpid()))
    }

    /// Pure half of `ownWindowFrames`: the frames belonging to `pid` in a `CGWindowListCopyWindowInfo`
    /// payload. Extracted because this filter is the whole self-guard — a window that fails to be
    /// recognized as ours is a window the model is allowed to click.
    ///
    /// The `> 1` size floor drops zero-area bookkeeping windows (status-item shells, offscreen
    /// 1×1 helpers): a degenerate rect can only ever produce a false DENY, and a deny on a
    /// point that isn't really covered by our UI reads to the model as an unexplained refusal.
    static func ownWindowRects(from infos: [[String: Any]], pid: Int) -> [CGRect] {
        var rects: [CGRect] = []
        for info in infos {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 1, rect.height > 1 else { continue }
            rects.append(rect)
        }
        return rects
    }

    // MARK: - Mouse

    /// One synthesized mouse event: which `CGEventType` and button, and the click-state counter
    /// that tells AppKit whether this is the first or the second click of a double-click.
    nonisolated struct MouseEventStep: Equatable, Sendable {
        let type: CGEventType
        let button: CGMouseButton
        let clickState: Int64
    }

    /// The exact event sequence `click` posts. Extracted so the mapping is pinnable without
    /// synthesizing real input: a wrong `CGEventType` clicks with the other mouse button, and a
    /// double-click that doesn't post a SECOND down/up pair at `clickState == 2` is delivered to
    /// the target app as two unrelated single clicks (no double-click action fires).
    static func mouseEventPlan(button: MouseButton, double: Bool) -> [MouseEventStep] {
        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) = button == .right
            ? (.rightMouseDown, .rightMouseUp, .right)
            : (.leftMouseDown, .leftMouseUp, .left)
        var plan = [
            MouseEventStep(type: downType, button: cgButton, clickState: 1),
            MouseEventStep(type: upType, button: cgButton, clickState: 1),
        ]
        if double {
            plan.append(MouseEventStep(type: downType, button: cgButton, clickState: 2))
            plan.append(MouseEventStep(type: upType, button: cgButton, clickState: 2))
        }
        return plan
    }

    static func click(globalPoint: CGPoint, button: MouseButton = .left, double: Bool = false) {
        let src = CGEventSource(stateID: .hidSystemState)
        for step in mouseEventPlan(button: button, double: double) {
            guard let event = CGEvent(mouseEventSource: src, mouseType: step.type,
                                      mouseCursorPosition: globalPoint, mouseButton: step.button)
            else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: step.clickState)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Scroll wheel deltas for a `(dx, dy)` request. `wheel1` is the VERTICAL axis and `wheel2`
    /// the horizontal one — swapping them scrolls sideways when the model asked to scroll down.
    /// `Int32(clamping:)` saturates rather than trapping: `dx`/`dy` are model-authored integers
    /// decoded straight from tool arguments, so `Int.max` is a reachable value.
    static func scrollDeltas(dx: Int, dy: Int) -> (wheel1: Int32, wheel2: Int32) {
        (wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx))
    }

    static func scroll(globalPoint: CGPoint, dx: Int, dy: Int) {
        CGWarpMouseCursorPosition(globalPoint)
        let src = CGEventSource(stateID: .hidSystemState)
        let deltas = scrollDeltas(dx: dx, dy: dy)
        if let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                            wheel1: deltas.wheel1, wheel2: deltas.wheel2, wheel3: 0) {
            ev.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard

    /// Types arbitrary Unicode text via a single synthesized event carrying the UTF-16 string.
    static func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    /// Presses a key combo such as `"cmd+s"`, `"return"`, `"cmd+shift+4"`.
    static func pressKeys(_ combo: String) throws {
        guard let parsed = parseKeyCombo(combo) else { throw InputControlError.unknownKeyCombo(combo) }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: parsed.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: parsed.keyCode, keyDown: false) else { return }
        down.flags = parsed.flags
        up.flags = parsed.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Pure parse of a `"mod+mod+key"` combo → (modifier flags, virtual keycode). Unit-tested.
    static func parseKeyCombo(_ combo: String) -> (flags: CGEventFlags, keyCode: CGKeyCode)? {
        let raw = combo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }

        // Split on "+", where "+" is BOTH the separator and a legitimate key ("cmd++" = zoom in).
        // The two cases are told apart by how many empty tokens trail: `"shift+"` splits to
        // ["shift", ""] — one trailing empty, i.e. a stray separator, which must stay a
        // modifier-only combo and be rejected. `"cmd++"` splits to ["cmd", "", ""] — two, the
        // second of which IS the key.
        //
        // The previous rule turned ANY single trailing empty into a "+" key token, which no
        // keycode table has an entry for, so the branch could not end in a successful parse:
        // `"cmd++"` returned `unknownKeyCombo` while the code read as if "+" were supported.
        var parts = raw.components(separatedBy: "+")
        var trailingEmpties = 0
        while parts.last == "" {
            parts.removeLast()
            trailingEmpties += 1
        }
        if trailingEmpties >= 2 { parts.append("+") }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let keyToken = parts.last else { return nil }

        var flags: CGEventFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            default: return nil
            }
        }
        // "+" is shift+"=" on US-ANSI — there is no key of its own to name, so the shift is
        // implicit and must be OR-ed in rather than required from the caller.
        if keyToken == "+" {
            guard let equals = keyCode(for: "=") else { return nil }
            return (flags.union(.maskShift), equals)
        }
        guard let code = keyCode(for: keyToken) else { return nil }
        return (flags, code)
    }

    // MARK: - App resolution / activation

    /// Plain-value projection of an `NSRunningApplication` — the class can't be constructed in
    /// tests, so the resolution order is decided over this instead (same split as
    /// `ScreenCaptureService.WindowCandidate`).
    nonisolated struct AppCandidate: Equatable, Sendable {
        let bundleID: String?
        let localizedName: String?
        /// `activationPolicy == .regular`, i.e. an ordinary Dock app rather than an agent /
        /// background helper.
        let isRegular: Bool
    }

    /// Index of the app `spec` resolves to, in strict tier order: exact bundle id, then exact
    /// name, then a name SUBSTRING — and the substring tier alone additionally requires a regular
    /// (Dock) app, because that is the tier where `"safari"` would otherwise match a background
    /// helper such as "Open and Save Panel Service (Safari)" and activate the wrong process. The
    /// tiers must stay ordered: a substring hit that outranked an exact one would let a longer
    /// app name steal a precisely-named target.
    static func bestAppIndex(_ candidates: [AppCandidate], spec: String) -> Int? {
        let needle = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        if let i = candidates.firstIndex(where: { $0.bundleID?.lowercased() == needle }) { return i }
        if let i = candidates.firstIndex(where: { $0.localizedName?.lowercased() == needle }) { return i }
        return candidates.firstIndex {
            ($0.localizedName?.lowercased().contains(needle) ?? false) && $0.isRegular
        }
    }

    /// Resolves a running application by exact bundle id, exact name, then contains-name.
    static func runningApp(matching spec: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        let candidates = apps.map {
            AppCandidate(bundleID: $0.bundleIdentifier, localizedName: $0.localizedName,
                         isRegular: $0.activationPolicy == .regular)
        }
        return bestAppIndex(candidates, spec: spec).map { apps[$0] }
    }

    static func activate(_ app: NSRunningApplication) {
        app.activate()
    }

    // MARK: - Keycode map

    private static func keyCode(for token: String) -> CGKeyCode? {
        if let named = Self.namedKeyCodes[token] { return named }
        // Single letter / digit / common punctuation.
        if token.count == 1, let code = Self.charKeyCodes[token] { return code }
        return nil
    }

    private static let namedKeyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "spacebar": 49,
        "delete": 51, "backspace": 51, "forwarddelete": 117, "escape": 53, "esc": 53,
        "left": 123, "leftarrow": 123, "right": 124, "rightarrow": 124,
        "down": 125, "downarrow": 125, "up": 126, "uparrow": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "help": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    private static let charKeyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50,
    ]
}
