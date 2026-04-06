import Foundation

// MARK: - Hotkey Manager Protocol

/// Abstraction over global hotkey registration for dependency injection in tests.
/// `GlobalHotkeyManager` is the production conformance.
@MainActor
protocol HotkeyManager: AnyObject {
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void)
    func unregister(id: UInt32)
}

extension GlobalHotkeyManager: HotkeyManager {}
