import AppKit
import XCTest

@testable import NanoTeams

/// Pure decision logic for "should this resize be accepted, clamped, or
/// blocked?". Drives every resize entry on the panel — `setFrame`,
/// `setContentSize`, `windowWillResize` — so the content-driven auto-grow
/// path (NSHostingView reporting intrinsic content size up to the panel
/// despite `sizingOptions = []`) does NOT change the window dimensions
/// after the user has set them via drag.
///
/// Rules:
///  - User drag (`isUserResize == true`): honor the request, just clamp to
///    floor. The lock is updated by the caller after drag ends.
///  - Programmatic (`isUserResize == false`):
///    - If a lock is set (user has resized at least once this session):
///      ALWAYS return the lock, ignoring the request. This is the
///      content-auto-grow defense.
///    - If no lock yet (first show, autosave restore): return the request
///      clamped to floor. The caller will subsequently capture the result
///      as the lock.
final class QuickCapturePanelResizeDecisionTests: XCTestCase {

    private let floor = NSSize(width: 200, height: 200)

    // MARK: - Live (user drag) path

    func testLive_aboveFloor_noLock_returnsRequest() {
        let result = QuickCapturePanel.ResizeDecision.decide(
            requested: NSSize(width: 350, height: 500),
            userLocked: nil,
            floor: floor,
            isUserResize: true
        )
        XCTAssertEqual(result, NSSize(width: 350, height: 500))
    }

    func testLive_belowFloor_clampsToFloor() {
        let result = QuickCapturePanel.ResizeDecision.decide(
            requested: NSSize(width: 50, height: 50),
            userLocked: nil,
            floor: floor,
            isUserResize: true
        )
        XCTAssertEqual(result, floor)
    }

    func testLive_overridesLock_userIntentWins() {
        // User actively dragging — the new size becomes truth, even if there
        // was a previous lock. (Caller will re-capture lock on drag end.)
        let result = QuickCapturePanel.ResizeDecision.decide(
            requested: NSSize(width: 350, height: 500),
            userLocked: NSSize(width: 200, height: 200),
            floor: floor,
            isUserResize: true
        )
        XCTAssertEqual(result, NSSize(width: 350, height: 500))
    }

    // MARK: - Programmatic path (this is the content-auto-grow defense)

    func testProgrammatic_withLock_ignoresRequest_returnsLock() {
        // NSHostingView reports SwiftUI content intrinsic size — AppKit forwards
        // as a setFrame call. Lock is the source of truth here.
        let lock = NSSize(width: 280, height: 360)
        let result = QuickCapturePanel.ResizeDecision.decide(
            requested: NSSize(width: 420, height: 510),  // content wants to grow
            userLocked: lock,
            floor: floor,
            isUserResize: false
        )
        XCTAssertEqual(result, lock, "content-driven grow must be blocked")
    }

    func testProgrammatic_withLock_ignoresShrink_returnsLock() {
        // Same logic — content shrinking shouldn't pull the panel down either.
        let lock = NSSize(width: 280, height: 360)
        let result = QuickCapturePanel.ResizeDecision.decide(
            requested: NSSize(width: 100, height: 100),
            userLocked: lock,
            floor: floor,
            isUserResize: false
        )
        XCTAssertEqual(result, lock)
    }

    func testProgrammatic_noLock_belowFloor_clampsToFloor() {
        // First open of a session — no lock yet. Autosave restore arrived
        // below floor → clamp up. Caller will then capture floor as lock.
        let result = QuickCapturePanel.ResizeDecision.decide(
            requested: NSSize(width: 100, height: 100),
            userLocked: nil,
            floor: floor,
            isUserResize: false
        )
        XCTAssertEqual(result, floor)
    }

    func testProgrammatic_noLock_aboveFloor_returnsRequest() {
        // First open — autosave restore arrives at reasonable size. Pass
        // through; caller captures this as the lock.
        let result = QuickCapturePanel.ResizeDecision.decide(
            requested: NSSize(width: 400, height: 600),
            userLocked: nil,
            floor: floor,
            isUserResize: false
        )
        XCTAssertEqual(result, NSSize(width: 400, height: 600))
    }

    func testProgrammatic_noLock_atFloor_returnsFloor() {
        // Boundary case — exactly at floor.
        let result = QuickCapturePanel.ResizeDecision.decide(
            requested: floor,
            userLocked: nil,
            floor: floor,
            isUserResize: false
        )
        XCTAssertEqual(result, floor)
    }

    // MARK: - Sub-floor lock defense

    func testProgrammatic_subFloorLock_isClampedUpToFloor() {
        // The function MUST NOT trust the lock to be ≥ floor. AppKit zeros
        // `super.minSize` for our style combo, and if that happens mid-drag
        // the captured lock could be sub-floor. Re-clamp inside the decision
        // so a corrupted lock can't produce a sub-floor result.
        let result = QuickCapturePanel.ResizeDecision.decide(
            requested: NSSize(width: 400, height: 500),
            userLocked: NSSize(width: 100, height: 100),  // bogus lock
            floor: floor,
            isUserResize: false
        )
        XCTAssertEqual(result, floor, "sub-floor lock must be re-clamped to floor")
    }

    func testProgrammatic_partiallySubFloorLock_isClampedPerDimension() {
        let result = QuickCapturePanel.ResizeDecision.decide(
            requested: NSSize(width: 400, height: 500),
            userLocked: NSSize(width: 100, height: 350),  // only width below floor
            floor: floor,
            isUserResize: false
        )
        XCTAssertEqual(result, NSSize(width: 200, height: 350))
    }
}
