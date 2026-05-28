import AppKit
import SwiftUI

// MARK: - WindowResizeMonitor

/// Observes the host `NSWindow`'s live-resize lifecycle and exposes `isResizing`
/// as `@Observable` state. Views that observe it can suppress expensive renders
/// (graph re-layout, NTMSLoader rotation, activity-feed bubble re-measure) while
/// a drag is in progress and restore them on `didEndLiveResize`.
///
/// Scope is per-`TeamBoardView` (`@State`), injected into Environment via
/// `WindowResizeMonitorAccessor`. The default Environment value is a no-op
/// monitor that never sees notifications, so surfaces without an explicit
/// binding (e.g. detail windows) silently fall back to the pre-optimization
/// behavior.
///
/// No failsafe: AppKit's `didStartLiveResizeNotification` /
/// `didEndLiveResizeNotification` pairing is documented-reliable. A timer-based
/// clear would fire during paused mid-drags and defeat the optimization.
@MainActor
@Observable
final class WindowResizeMonitor {
    private(set) var isResizing: Bool = false

    private var observerTokens: [NSObjectProtocol] = []
    private weak var boundWindow: NSWindow?

    /// Binds to `window` if not already bound to the same window. Idempotent;
    /// rebinding to a new window automatically unbinds from the previous one.
    func bind(to window: NSWindow) {
        guard window !== boundWindow else { return }
        unbind()
        boundWindow = window
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: NSWindow.willStartLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isResizing = true
            }
        })
        observerTokens.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isResizing = false
            }
        })
    }

    /// Cleans up registered `NotificationCenter` observers when the monitor
    /// deallocates. Without this, the two observer blocks installed by
    /// `bind(to:)` stay registered (each `[weak self]`-no-ops afterwards
    /// — so not a state-corruption bug, but per-`TeamBoardView` accumulation
    /// in `NotificationCenter.default`). Pattern from `docs/swift-6-concurrency.md` §112.
    nonisolated deinit {
        MainActor.assumeIsolated {
            unbind()
        }
    }

    /// Removes all observers and resets `isResizing` to false.
    func unbind() {
        let center = NotificationCenter.default
        let removedCount = observerTokens.count
        for token in observerTokens {
            center.removeObserver(token)
        }
        observerTokens.removeAll()
        boundWindow = nil
        isResizing = false
        #if DEBUG
        Self._testLastUnbindTokenCount = removedCount
        #endif
    }

    #if DEBUG
    /// Records the number of observer tokens removed on the most recent
    /// `unbind()`. Tests use this to verify that `deinit` invokes `unbind()`
    /// — without that invocation, observers leak into `NotificationCenter`.
    /// `nonisolated(unsafe)` is safe because every write goes through
    /// `unbind()`, which is either `@MainActor` (direct call) or routed
    /// through `MainActor.assumeIsolated { unbind() }` (deinit). Reads
    /// happen from `@MainActor` test methods only.
    nonisolated(unsafe) static var _testLastUnbindTokenCount: Int = -1
    #endif
}

// MARK: - WindowResizeMonitorAccessor

/// Invisible `NSViewRepresentable` that binds a `WindowResizeMonitor` to the
/// host `NSWindow` of the SwiftUI subtree it's attached to.
///
/// `nsView.window` is `nil` during the first `updateNSView` pass (the view is
/// not yet inserted into the window). Deferring the bind to the next runloop
/// tick via `DispatchQueue.main.async` lets AppKit complete the window
/// insertion before we observe.
struct WindowResizeMonitorAccessor: NSViewRepresentable {
    let monitor: WindowResizeMonitor

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let monitor = self.monitor
        DispatchQueue.main.async {
            if let window = nsView.window {
                monitor.bind(to: window)
            }
        }
    }
}

// MARK: - EnvironmentValues

extension EnvironmentValues {
    @Entry var windowResizeMonitor: WindowResizeMonitor = WindowResizeMonitor()
}
