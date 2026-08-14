import Foundation

// MARK: - Hotkey Manager Protocol

/// Abstraction over global hotkey registration for dependency injection in tests.
/// `GlobalHotkeyManager` is the production conformance.
@MainActor
protocol HotkeyManager: AnyObject {
    /// Returns `false` when the combo could NOT be claimed — almost always because another app
    /// already owns it. Deliberately not `@discardableResult`: a hotkey that failed to register
    /// is a feature the user is told exists and that silently never fires, so every caller has
    /// to decide what to say about it.
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool
}

extension GlobalHotkeyManager: HotkeyManager {}

/// The inert default for `QuickCaptureController`'s seam — claims nothing, registers nothing.
///
/// Sibling of `InertSelectionCapturer`, and here for the same reason: a seam parameter's `nil`
/// must resolve to an inert implementation, never a live one. `hotkeyManager` was the one seam of
/// the four that resolved OUTWARD, to `GlobalHotkeyManager.shared`, so 78 of the 88 test
/// construction sites that omit it were handed the process-global Carbon registrar. Harmless
/// today only by accident — `register` is reachable solely through `setup(store:dictation:)`, and
/// all 20 of those call sites happen to inject a fake — which is precisely the accident CLAUDE.md
/// #49 describes going wrong at scale, where the same shape accumulated 93 sites before anyone
/// noticed the default was live.
///
/// Returning `false` is the honest answer, not a convenience: `false` means "the combo could not
/// be claimed", and an inert registrar claims nothing. A test that reaches this and asserts a
/// hotkey works gets a red test instead of a passing one backed by a real system-wide hotkey.
@MainActor
final class InertHotkeyManager: HotkeyManager {
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32,
                  handler: @escaping () -> Void) -> Bool {
        false
    }
}
