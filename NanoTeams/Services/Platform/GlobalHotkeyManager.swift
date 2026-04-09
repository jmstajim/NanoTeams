import AppKit
import Carbon

// MARK: - Global Hotkey Manager

/// Registers system-wide keyboard shortcuts using Carbon's `RegisterEventHotKey` API.
/// Works even when the application is not in focus.
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.unregisterAll()
        }
    }

    // MARK: - Public API

    /// Registers a global hotkey.
    /// - Parameters:
    ///   - id: Unique identifier for this hotkey (used for unregistration)
    ///   - keyCode: Carbon virtual key code (e.g., 29 for '0', 40 for 'k')
    ///   - modifiers: Carbon modifier mask (e.g., `cmdKey | optionKey | controlKey`)
    ///   - handler: Closure invoked on the main actor when the hotkey is pressed
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        if hotkeyRefs[id] != nil || handlers[id] != nil {
            unregister(id: id)
        }
        handlers[id] = handler

        // Install the Carbon event handler once
        if eventHandler == nil {
            installEventHandler()
        }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x41494351) // "AICQ"
        hotKeyID.id = id

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )

        if status == noErr, let ref {
            hotkeyRefs[id] = ref
        }
    }

    /// Unregisters a previously registered hotkey.
    func unregister(id: UInt32) {
        if let ref = hotkeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: id)
    }

    /// Unregisters all hotkeys and removes the event handler.
    func unregisterAll() {
        for (_, ref) in hotkeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()
        handlers.removeAll()
    }

    // MARK: - Internal

    fileprivate func handleHotKey(id: UInt32) {
        handlers[id]?()
    }

    // MARK: - Private

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotkeyCallback,
            1, &eventType,
            selfPtr,
            &eventHandler
        )
    }

    nonisolated deinit {}
}

// MARK: - Carbon Callback

/// C-compatible callback function required by Carbon's `InstallEventHandler`.
/// Extracts the hotkey ID from the event and dispatches to the manager on the main actor.
nonisolated private func globalHotkeyCallback(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr else { return status }

    let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let keyID = hotKeyID.id

    Task { @MainActor in
        manager.handleHotKey(id: keyID)
    }

    return noErr
}
