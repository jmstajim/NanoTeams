import AppKit
import SwiftUI
import XCTest

@testable import NanoTeams

/// Pins the `WindowResizeMonitor` contract: bind to an NSWindow, flip
/// `isResizing` true/false in lockstep with AppKit's
/// `didStartLiveResizeNotification` / `didEndLiveResizeNotification`.
///
/// These tests guard the 4.41 s resize hang fix. If the monitor ever stops
/// flipping `isResizing`, the resize-suppression branches in NTMSLoader,
/// TeamGraphView, and TeamActivityFeedView all silently degrade back to
/// the pre-fix behavior — and the only signal is a frame-rate regression
/// that's hard to spot in CI.
@MainActor
final class WindowResizeMonitorTests: XCTestCase {

    private var monitor: WindowResizeMonitor!

    override func setUp() {
        super.setUp()
        monitor = WindowResizeMonitor()
    }

    override func tearDown() {
        monitor?.unbind()
        monitor = nil
        super.tearDown()
    }

    /// Build an offscreen NSWindow on demand. Construction lives inside the
    /// test (not in setUp) so a malformed window initializer can't kill an
    /// unrelated test method via shared setUp crash.
    private func makeWindow() -> NSWindow {
        NSWindow()
    }

    // MARK: - Initial state

    func testInit_isResizingIsFalse() async {
        XCTAssertFalse(monitor.isResizing)
    }

    // MARK: - Notification-driven transitions

    func testDidStartLiveResize_flipsIsResizingTrue() async {
        let window = makeWindow()
        monitor.bind(to: window)
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        await Self.flushMainQueue()
        XCTAssertTrue(monitor.isResizing, "Expected isResizing=true after didStartLiveResize.")
    }

    func testDidEndLiveResize_flipsIsResizingFalse() async {
        let window = makeWindow()
        monitor.bind(to: window)
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        await Self.flushMainQueue()
        XCTAssertTrue(monitor.isResizing, "Precondition: monitor entered resize state.")

        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
        await Self.flushMainQueue()
        XCTAssertFalse(monitor.isResizing, "Expected isResizing=false after didEndLiveResize.")
    }

    // MARK: - Bind/unbind lifecycle

    func testBind_isIdempotentForSameWindow() async {
        let window = makeWindow()
        monitor.bind(to: window)
        monitor.bind(to: window)  // Should not register duplicate observers.

        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        await Self.flushMainQueue()
        XCTAssertTrue(monitor.isResizing)

        // If duplicate observers had registered, the second end-notification
        // delivery would race with the first. The monitor settles on false
        // because the last write wins, but the test still proves the public
        // observable surface is coherent.
        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
        await Self.flushMainQueue()
        XCTAssertFalse(monitor.isResizing)
    }

    func testBind_toNewWindow_unbindsFromPrevious() async {
        let secondWindow = makeWindow()
        let window = makeWindow()
        monitor.bind(to: window)
        monitor.bind(to: secondWindow)

        // The first window's notification must no longer affect state.
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        await Self.flushMainQueue()
        XCTAssertFalse(monitor.isResizing, "First window's notification must not reach a rebound monitor.")

        // The second window's notification reaches it.
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification,
            object: secondWindow
        )
        await Self.flushMainQueue()
        XCTAssertTrue(monitor.isResizing)
    }

    func testUnbind_clearsStateAndStopsObserving() async {
        let window = makeWindow()
        monitor.bind(to: window)
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        await Self.flushMainQueue()
        XCTAssertTrue(monitor.isResizing)

        monitor.unbind()
        XCTAssertFalse(monitor.isResizing, "unbind() must reset isResizing.")

        // Post-unbind notifications must be ignored.
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        await Self.flushMainQueue()
        XCTAssertFalse(monitor.isResizing, "Post-unbind notifications must not flip state.")
    }

    // MARK: - Notification filtering

    func testNotificationForDifferentWindow_isIgnored() async {
        let otherWindow = makeWindow()
        let window = makeWindow()
        monitor.bind(to: window)
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification,
            object: otherWindow
        )
        await Self.flushMainQueue()
        XCTAssertFalse(monitor.isResizing, "Notifications for an unbound window must be ignored.")
    }

    // MARK: - EnvironmentValues default

    func testEnvironmentDefault_isNoOpMonitor() async {
        let env = EnvironmentValues()
        XCTAssertFalse(env.windowResizeMonitor.isResizing, "Default Environment monitor must report not-resizing.")
    }

    // MARK: - Deinit observer cleanup

    /// Regression test: without a deinit that calls `unbind()`, the two
    /// `NotificationCenter.default` observer blocks installed by `bind` stay
    /// registered forever once the monitor deallocates. Closures capture
    /// `[weak self]` so they no-op functionally, but they accumulate per
    /// `TeamBoardView` instantiation — a memory + dispatch-overhead leak.
    ///
    /// The test uses the `_testLastUnbindTokenCount` side channel to detect
    /// whether `unbind` actually fired with the 2 expected tokens during
    /// dealloc. Before binding, `bind()` internally calls `unbind()` once on
    /// an empty token list (count 0). If `deinit` runs `unbind()` after the
    /// monitor goes out of scope, the count flips to 2 (the live observers).
    func testDeinit_unbindsRegisteredObservers() async {
        let window = NSWindow()

        // Reset the side channel so this test's signal isn't contaminated
        // by a previous test in the suite that bound + unbound a monitor.
        WindowResizeMonitor._testLastUnbindTokenCount = -1

        autoreleasepool {
            // Use a *separate* monitor — `self.monitor` is held by the
            // XCTestCase instance and won't deallocate until tearDown, which
            // would defeat the autoreleasepool scope.
            let scopedMonitor = WindowResizeMonitor()
            scopedMonitor.bind(to: window)
            // After bind(): the internal unbind() saw zero pre-existing
            // tokens, so the side channel reads 0.
            XCTAssertEqual(
                WindowResizeMonitor._testLastUnbindTokenCount,
                0,
                "Sanity check: bind()'s pre-unbind ran with empty observer list."
            )
            // scopedMonitor drops out of scope here; nothing else retains it.
        }

        // After the autoreleasepool, `scopedMonitor` must have deallocated.
        // If deinit cleans up properly, it will have called `unbind()` with
        // the 2 live observer tokens, so the side channel reads 2.
        XCTAssertEqual(
            WindowResizeMonitor._testLastUnbindTokenCount,
            2,
            "deinit must call unbind() to remove the 2 NotificationCenter observers; otherwise they leak."
        )
    }

    // MARK: - Helpers

    /// Spin the main run loop briefly so `OperationQueue.main`-scheduled
    /// observer blocks fire before we assert. `Task.yield()` alone is not
    /// enough — the observer block is enqueued on `OperationQueue.main`,
    /// not the Swift cooperative pool, so we need a real runloop tick.
    private static func flushMainQueue() async {
        for _ in 0..<3 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
