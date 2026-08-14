import AppKit
import Carbon

// MARK: - Registration outcome (pure)

/// Why a `register` call did or didn't end up owning the combo. Split out of `GlobalHotkeyManager`
/// so the decision is testable without Carbon (the manager is a `private init` singleton whose
/// every path calls `RegisterEventHotKey`), and so the two distinct failures stay distinguishable:
/// both end as `false` to the caller, but they mean different things and only one of them leaves
/// the combo claimed by somebody else.
nonisolated enum HotkeyRegistrationOutcome: Equatable, Sendable {
    case registered
    /// Carbon refused — the combo is already owned by another process (Alfred, Raycast, Keyboard
    /// Maestro and the system itself all claim triple-modifier combos).
    case refusedByCarbon(OSStatus)
    /// The Carbon event handler could not be installed, so nothing would ever be delivered.
    /// We must NOT go on to call `RegisterEventHotKey` in this state: that would claim the combo
    /// process-wide (denying it to whatever app the user actually wants to use it in) for a
    /// hotkey that can never fire — and report success while doing it.
    case eventHandlerUnavailable

    /// Whether the manager now owns the combo. The only `true`.
    var didRegister: Bool { self == .registered }

    /// Carbon's answer, read the way `RegisterEventHotKey` documents it: a `noErr` status that
    /// nonetheless produced no ref is still a failure, and treating it as success would leave the
    /// manager claiming an id it holds no ref for — which `unregister` could then never release.
    static func evaluate(carbonStatus: OSStatus, gotRef: Bool) -> Self {
        guard carbonStatus == noErr, gotRef else { return .refusedByCarbon(carbonStatus) }
        return .registered
    }
}

// MARK: - Hotkey Registry (pure)

/// The id → (Carbon ref, handler) bookkeeping behind `GlobalHotkeyManager`, generic over the ref
/// token so it can be exercised without Carbon (`EventHotKeyRef` is an opaque pointer no test can
/// fabricate).
///
/// The stage/commit/rollback shape is the point. A handler has to be stored BEFORE the Carbon call
/// (the callback can fire the moment registration succeeds), but a failed registration must not
/// leave it behind: a leftover handler makes the manager claim an id it does not own, so the next
/// `register(id:)` takes the "already registered" branch and calls `unregister` on a ref that was
/// never there — and `handleHotKey` would dispatch to a handler for a combo the user never got.
nonisolated struct HotkeyRegistry<Ref> {
    private(set) var refs: [UInt32: Ref] = [:]
    private(set) var handlers: [UInt32: () -> Void] = [:]

    var isEmpty: Bool { refs.isEmpty && handlers.isEmpty }
    /// Ids the registry holds a live ref for.
    var registeredIDs: Set<UInt32> { Set(refs.keys) }

    /// True if `id` is spoken for in EITHER map — a staged-but-uncommitted handler counts, because
    /// re-registering over it must still tear the old state down first.
    func claims(_ id: UInt32) -> Bool { refs[id] != nil || handlers[id] != nil }

    func handler(for id: UInt32) -> (() -> Void)? { handlers[id] }

    mutating func stageHandler(id: UInt32, handler: @escaping () -> Void) { handlers[id] = handler }

    mutating func commit(id: UInt32, ref: Ref) { refs[id] = ref }

    /// Undoes `stageHandler` after a failed registration.
    mutating func rollback(id: UInt32) { handlers.removeValue(forKey: id) }

    /// Forgets `id` entirely and hands back the ref the caller must release, if there was one.
    /// The handler goes unconditionally — a staged-but-refless id is exactly the state
    /// `rollback` exists to prevent, and leaving it behind here would recreate it.
    mutating func remove(id: UInt32) -> Ref? {
        handlers.removeValue(forKey: id)
        return refs.removeValue(forKey: id)
    }

    /// Empties the registry, handing back every ref the caller must release.
    mutating func removeAll() -> [Ref] {
        let released = Array(refs.values)
        refs.removeAll()
        handlers.removeAll()
        return released
    }
}

// MARK: - Global Hotkey Manager

/// Registers system-wide keyboard shortcuts using Carbon's `RegisterEventHotKey` API.
/// Works even when the application is not in focus.
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var registry = HotkeyRegistry<EventHotKeyRef>()
    private var eventHandler: EventHandlerRef?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this block runs on the main thread, but
            // Swift 6's strict checker can't prove that, so it treats the
            // closure as nonisolated. The runtime assertion is safe.
            MainActor.assumeIsolated {
                self?.unregisterAll()
            }
        }
    }

    // MARK: - Public API

    /// Registers a global hotkey.
    /// - Parameters:
    ///   - id: Unique identifier for this hotkey (used for unregistration)
    ///   - keyCode: Carbon virtual key code (e.g., 29 for '0', 40 for 'k')
    ///   - modifiers: Carbon modifier mask (e.g., `cmdKey | optionKey | controlKey`)
    ///   - handler: Closure invoked on the main actor when the hotkey is pressed
    /// - Returns: `false` when the combo could not be claimed — either Carbon refused it (another
    ///   process already owns it; Alfred, Raycast, Keyboard Maestro and the system itself all
    ///   claim triple-modifier combos) or the Carbon event handler could not be installed, in
    ///   which case nothing would ever be delivered. The status used to be captured and dropped,
    ///   so the hotkey the Settings shortcut sheet advertises simply never fired and nothing
    ///   anywhere said why. See `HotkeyRegistrationOutcome`.
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        if registry.claims(id) {
            unregister(id: id)
        }
        // Staged BEFORE the Carbon call: the callback can fire as soon as registration succeeds.
        registry.stageHandler(id: id, handler: handler)

        // Install the Carbon event handler once. Bail BEFORE claiming the combo if that fails —
        // registering a hotkey nothing can deliver would take the combo away from whatever app
        // the user actually wants it in, and report success while doing it.
        guard ensureEventHandlerInstalled() else {
            return finishRegistration(.eventHandlerUnavailable, id: id, ref: nil)
        }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x41494351) // "AICQ"
        hotKeyID.id = id

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        return finishRegistration(
            .evaluate(carbonStatus: status, gotRef: ref != nil), id: id, ref: ref)
    }

    /// Commits or rolls back the staged handler according to `outcome`.
    private func finishRegistration(
        _ outcome: HotkeyRegistrationOutcome, id: UInt32, ref: EventHotKeyRef?
    ) -> Bool {
        guard outcome.didRegister, let ref else {
            registry.rollback(id: id)
            return false
        }
        registry.commit(id: id, ref: ref)
        return true
    }

    /// Unregisters a previously registered hotkey.
    func unregister(id: UInt32) {
        if let ref = registry.remove(id: id) {
            UnregisterEventHotKey(ref)
        }
    }

    /// Unregisters every hotkey and forgets its handler. **Deliberately KEEPS the installed
    /// Carbon event handler** — `register` re-uses it (`if eventHandler == nil`), and the handler
    /// holds `Unmanaged.passUnretained(self)`, so tearing it down here would have to be paired
    /// with nilling the ref. Safe as-is because the only caller is the `willTerminate` observer.
    /// The doc used to claim it removed the handler, which would have misled anyone adding a
    /// mid-life teardown path.
    func unregisterAll() {
        for ref in registry.removeAll() {
            UnregisterEventHotKey(ref)
        }
    }

    // MARK: - Internal

    fileprivate func handleHotKey(id: UInt32) {
        registry.handler(for: id)?()
    }

    // MARK: - Private

    /// Installs the Carbon event handler if it isn't already installed. Returns whether one is
    /// now in place. `InstallEventHandler`'s `OSStatus` used to be discarded, so a failed install
    /// left `register` reporting `true` for a hotkey that could never fire.
    private func ensureEventHandlerInstalled() -> Bool {
        if eventHandler != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotkeyCallback,
            1, &eventType,
            selfPtr,
            &eventHandler
        )
        guard status == noErr, eventHandler != nil else {
            eventHandler = nil
            return false
        }
        return true
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
