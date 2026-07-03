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

nonisolated enum InputControlError: LocalizedError {
    case accessibilityDenied
    case unknownKeyCombo(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "Accessibility permission is required to control the mouse and keyboard. Grant it in System Settings → Privacy & Security → Accessibility."
        case .unknownKeyCombo(let combo):
            "Unrecognized key combination '\(combo)'."
        }
    }
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
        let pid = Int(getpid())
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
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

    static func click(globalPoint: CGPoint, button: MouseButton = .left, double: Bool = false) {
        let src = CGEventSource(stateID: .hidSystemState)
        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) = button == .right
            ? (.rightMouseDown, .rightMouseUp, .right)
            : (.leftMouseDown, .leftMouseUp, .left)

        func postPair(clickState: Int64) {
            if let down = CGEvent(mouseEventSource: src, mouseType: downType,
                                  mouseCursorPosition: globalPoint, mouseButton: cgButton) {
                down.setIntegerValueField(.mouseEventClickState, value: clickState)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(mouseEventSource: src, mouseType: upType,
                                mouseCursorPosition: globalPoint, mouseButton: cgButton) {
                up.setIntegerValueField(.mouseEventClickState, value: clickState)
                up.post(tap: .cghidEventTap)
            }
        }
        postPair(clickState: 1)
        if double { postPair(clickState: 2) }
    }

    static func scroll(globalPoint: CGPoint, dx: Int, dy: Int) {
        CGWarpMouseCursorPosition(globalPoint)
        let src = CGEventSource(stateID: .hidSystemState)
        // wheel1 = vertical, wheel2 = horizontal.
        if let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                            wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0) {
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

        // Split on "+", tolerating a trailing empty token meaning the key itself is "+".
        var parts = raw.components(separatedBy: "+")
        if parts.count > 1, parts.last == "" {
            parts.removeLast()
            parts.append("+")
        }
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
        guard let code = keyCode(for: keyToken) else { return nil }
        return (flags, code)
    }

    // MARK: - App resolution / activation

    /// Resolves a running application by exact bundle id, exact name, then contains-name.
    static func runningApp(matching spec: String) -> NSRunningApplication? {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        let apps = NSWorkspace.shared.runningApplications
        return apps.first { $0.bundleIdentifier?.lowercased() == s }
            ?? apps.first { $0.localizedName?.lowercased() == s }
            ?? apps.first { ($0.localizedName?.lowercased().contains(s) ?? false) && $0.activationPolicy == .regular }
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
