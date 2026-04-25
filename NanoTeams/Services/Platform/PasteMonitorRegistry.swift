import Foundation

/// Process-wide arbiter that ensures at most one `MessageComposer` paste
/// monitor is installed at any time. Two simultaneously-focused composers
/// (e.g. QuickCapture overlay over the activity feed) would otherwise both
/// fire on the same Cmd+V — double-staging files and consuming the event
/// twice. Owners hand in a `remove` closure so the registry can detach the
/// previous OS-level NSEvent monitor when a new owner takes over.
@MainActor
final class PasteMonitorRegistry {
    static let shared = PasteMonitorRegistry()

    private var current: (ownerID: UUID, remove: () -> Void)?

    var activeOwnerID: UUID? { current?.ownerID }

    /// Replaces the active monitor. Calls the previous owner's `remove`
    /// closure so its NSEvent monitor is detached before the new one fires.
    func register(ownerID: UUID, remove: @escaping () -> Void) {
        if let existing = current {
            existing.remove()
        }
        current = (ownerID, remove)
    }

    /// Detaches only when the caller still holds the slot — a stale release
    /// after eviction is a no-op (otherwise we'd accidentally remove the
    /// new owner's monitor).
    func release(ownerID: UUID) {
        guard let existing = current, existing.ownerID == ownerID else { return }
        existing.remove()
        current = nil
    }

    #if DEBUG
    func _testReset() { current = nil }
    #endif
}
