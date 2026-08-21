import CoreGraphics
import XCTest
@testable import NanoTeams

// MARK: - Mouse event plan

/// `click` posts real `CGEvent`s at the developer's cursor, so nothing here may call it. What it
/// DECIDES — which event types and button, and the click-state sequence — is now
/// `mouseEventPlan`, and that is decidable without synthesizing anything.
///
/// Both halves of the plan are load-bearing. A wrong `CGEventType` clicks with the other mouse
/// button (a context menu where the model asked for a selection). A double-click that doesn't
/// post a SECOND down/up pair at `clickState == 2` arrives at the target app as two unrelated
/// single clicks, so no double-click action ever fires and the model retries forever.
final class InputControlMouseEventPlanTests: XCTestCase {

    func testLeftSingleClick_isOneDownUpPairAtClickStateOne() {
        let plan = InputControlService.mouseEventPlan(button: .left, double: false)
        XCTAssertEqual(plan, [
            .init(type: .leftMouseDown, button: .left, clickState: 1),
            .init(type: .leftMouseUp, button: .left, clickState: 1),
        ])
    }

    func testRightSingleClick_usesTheRightButtonEventTypes() {
        let plan = InputControlService.mouseEventPlan(button: .right, double: false)
        XCTAssertEqual(plan, [
            .init(type: .rightMouseDown, button: .right, clickState: 1),
            .init(type: .rightMouseUp, button: .right, clickState: 1),
        ])
    }

    /// The click-state ladder 1 → 2 is what AppKit reads to recognize a double-click. Posting two
    /// pairs both at state 1 is indistinguishable from the user clicking twice slowly.
    func testDoubleClick_postsASecondPairAtClickStateTwo() {
        let plan = InputControlService.mouseEventPlan(button: .left, double: true)
        XCTAssertEqual(plan.count, 4)
        XCTAssertEqual(plan.map(\.clickState), [1, 1, 2, 2])
    }

    func testRightDoubleClick_keepsTheRightButtonThroughout() {
        let plan = InputControlService.mouseEventPlan(button: .right, double: true)
        XCTAssertEqual(plan.count, 4)
        XCTAssertTrue(plan.allSatisfy { $0.button == .right })
        XCTAssertEqual(plan.map(\.type), [.rightMouseDown, .rightMouseUp, .rightMouseDown, .rightMouseUp])
    }

    /// Down strictly before up, in every pair: an inverted pair is a mouse-up with no press,
    /// which most apps drop silently.
    func testEveryPair_isDownThenUp() {
        for button in [MouseButton.left, .right] {
            for double in [false, true] {
                let plan = InputControlService.mouseEventPlan(button: button, double: double)
                XCTAssertEqual(plan.count % 2, 0, "\(button)/\(double)")
                for pair in stride(from: 0, to: plan.count, by: 2) {
                    let down = plan[pair].type
                    let up = plan[pair + 1].type
                    XCTAssertTrue(down == .leftMouseDown || down == .rightMouseDown, "\(button)/\(double)")
                    XCTAssertTrue(up == .leftMouseUp || up == .rightMouseUp, "\(button)/\(double)")
                    XCTAssertEqual(plan[pair].clickState, plan[pair + 1].clickState, "\(button)/\(double)")
                }
            }
        }
    }

    /// The two buttons must never share an event type — that would be a silent cross-wire.
    func testLeftAndRightPlans_shareNoEventType() {
        let left = Set(InputControlService.mouseEventPlan(button: .left, double: true).map(\.type.rawValue))
        let right = Set(InputControlService.mouseEventPlan(button: .right, double: true).map(\.type.rawValue))
        XCTAssertTrue(left.isDisjoint(with: right))
    }

    /// A single click is a strict PREFIX of a double click — the extra pair is additive, so a
    /// double-click can never change what the first click delivers.
    func testSingleClickPlan_isThePrefixOfTheDoubleClickPlan() {
        let single = InputControlService.mouseEventPlan(button: .left, double: false)
        let double = InputControlService.mouseEventPlan(button: .left, double: true)
        XCTAssertEqual(Array(double.prefix(single.count)), single)
    }
}

// MARK: - Scroll deltas

/// `scroll` warps the real cursor and posts a real wheel event, so it can't be called here.
/// `scrollDeltas` is the part that can be wrong: `wheel1` is the VERTICAL axis and `wheel2` the
/// horizontal one, and swapping them scrolls sideways when the model asked to scroll down.
final class InputControlScrollDeltaTests: XCTestCase {

    func testVerticalGoesToWheelOne_andHorizontalToWheelTwo() {
        let d = InputControlService.scrollDeltas(dx: 3, dy: -5)
        XCTAssertEqual(d.wheel1, -5, "wheel1 is vertical")
        XCTAssertEqual(d.wheel2, 3, "wheel2 is horizontal")
    }

    func testPureVerticalScroll_leavesTheHorizontalAxisAtZero() {
        let d = InputControlService.scrollDeltas(dx: 0, dy: 120)
        XCTAssertEqual(d.wheel1, 120)
        XCTAssertEqual(d.wheel2, 0)
    }

    func testPureHorizontalScroll_leavesTheVerticalAxisAtZero() {
        let d = InputControlService.scrollDeltas(dx: -40, dy: 0)
        XCTAssertEqual(d.wheel1, 0)
        XCTAssertEqual(d.wheel2, -40)
    }

    func testZeroScroll_isZeroOnBothAxes() {
        let d = InputControlService.scrollDeltas(dx: 0, dy: 0)
        XCTAssertEqual(d.wheel1, 0)
        XCTAssertEqual(d.wheel2, 0)
    }

    /// `dx`/`dy` are model-authored integers decoded straight from tool arguments, so `Int.max` is
    /// a reachable value and a plain `Int32(_:)` conversion would TRAP on it — the same
    /// uncatchable-crash class as an out-of-range `Int(Double)`. `Int32(clamping:)` saturates.
    func testOutOfRangeDeltas_saturateRatherThanTrapping() {
        let high = InputControlService.scrollDeltas(dx: Int.max, dy: Int.max)
        XCTAssertEqual(high.wheel1, Int32.max)
        XCTAssertEqual(high.wheel2, Int32.max)

        let low = InputControlService.scrollDeltas(dx: Int.min, dy: Int.min)
        XCTAssertEqual(low.wheel1, Int32.min)
        XCTAssertEqual(low.wheel2, Int32.min)
    }

    /// One past the `Int32` boundary in each direction — the values a naive conversion gets wrong
    /// by wrapping rather than by trapping.
    func testJustPastTheInt32Boundary_clampsToTheBoundary() {
        XCTAssertEqual(InputControlService.scrollDeltas(dx: 0, dy: Int(Int32.max) + 1).wheel1, Int32.max)
        XCTAssertEqual(InputControlService.scrollDeltas(dx: 0, dy: Int(Int32.min) - 1).wheel1, Int32.min)
    }

    /// Anti-vacuity for the clamp: values that FIT must pass through untouched, boundaries
    /// included.
    func testInRangeDeltas_passThroughExactly() {
        XCTAssertEqual(InputControlService.scrollDeltas(dx: 0, dy: Int(Int32.max)).wheel1, Int32.max)
        XCTAssertEqual(InputControlService.scrollDeltas(dx: Int(Int32.min), dy: 0).wheel2, Int32.min)
        XCTAssertEqual(InputControlService.scrollDeltas(dx: -7, dy: 7).wheel1, 7)
    }
}

// MARK: - Running-app resolution order

/// `runningApp(matching:)` used to inline its resolution over live `NSRunningApplication`s, which
/// no test can construct — so the tier ORDER (the part that decides which app gets activated and
/// then typed into) was only observable against whatever happened to be running on the machine.
/// It now decides over `AppCandidate`, mirroring `ScreenCaptureService.WindowCandidate`.
final class InputControlAppResolutionOrderTests: XCTestCase {

    private func app(
        _ name: String?, bundle: String? = nil, regular: Bool = true
    ) -> InputControlService.AppCandidate {
        .init(bundleID: bundle, localizedName: name, isRegular: regular)
    }

    // MARK: Tier order

    /// An exact bundle-id hit outranks everything, wherever it sits in the list. A substring that
    /// won here would let "Safari Technology Preview" answer for `com.apple.Safari`.
    func testExactBundleID_winsOverAnEarlierNameSubstring() {
        let apps = [app("Safari Technology Preview"), app("Safari", bundle: "com.apple.Safari")]
        XCTAssertEqual(InputControlService.bestAppIndex(apps, spec: "com.apple.Safari"), 1)
    }

    func testExactName_winsOverAnEarlierSubstring() {
        let apps = [app("Safari Technology Preview"), app("Safari")]
        XCTAssertEqual(InputControlService.bestAppIndex(apps, spec: "safari"), 1)
    }

    func testExactBundleID_winsOverAnEarlierExactName() {
        let apps = [app("Safari"), app("Something", bundle: "safari")]
        XCTAssertEqual(InputControlService.bestAppIndex(apps, spec: "safari"), 1)
    }

    /// The substring tier is the last resort, and it is the ONLY tier that additionally demands a
    /// regular (Dock) app — this is the same wrong-process hazard `windowRank` guards for
    /// captures: `"safari"` must not resolve to the background "Open and Save Panel Service
    /// (Safari)" and get the model typing into an invisible helper.
    func testSubstringTier_skipsBackgroundHelpers() {
        let apps = [
            app("Open and Save Panel Service (Safari)", regular: false),
            app("Safari Technology Preview", regular: true),
        ]
        XCTAssertEqual(InputControlService.bestAppIndex(apps, spec: "safari"), 1)
    }

    /// …and when the helper is the ONLY substring match, the answer is nil rather than the helper.
    func testSubstringTier_withOnlyABackgroundHelper_resolvesToNil() {
        let apps = [app("Open and Save Panel Service (Safari)", regular: false)]
        XCTAssertNil(InputControlService.bestAppIndex(apps, spec: "safari"))
    }

    /// The regular-app requirement applies to the SUBSTRING tier only: an exactly-named agent app
    /// was named precisely, so honour it.
    func testExactNameTier_doesNotRequireARegularApp() {
        let apps = [app("Hammerspoon", regular: false)]
        XCTAssertEqual(InputControlService.bestAppIndex(apps, spec: "Hammerspoon"), 0)
    }

    func testExactBundleIDTier_doesNotRequireARegularApp() {
        let apps = [app("Agent", bundle: "com.example.agent", regular: false)]
        XCTAssertEqual(InputControlService.bestAppIndex(apps, spec: "com.example.agent"), 0)
    }

    // MARK: Normalization

    func testMatching_isCaseInsensitiveOnBothNameAndBundleID() {
        XCTAssertEqual(InputControlService.bestAppIndex([app("Safari")], spec: "SAFARI"), 0)
        XCTAssertEqual(
            InputControlService.bestAppIndex([app("x", bundle: "COM.Apple.Safari")], spec: "com.apple.safari"), 0)
    }

    func testSpec_isTrimmed() {
        XCTAssertEqual(InputControlService.bestAppIndex([app("Safari")], spec: "  Safari \n"), 0)
    }

    // MARK: Degenerate input

    /// A blank spec must resolve to NOTHING rather than an arbitrary app — `contains("")` is true
    /// for every name, so the substring tier would otherwise activate whatever is first in the
    /// list and let the model type into it.
    func testBlankSpec_resolvesToNil() {
        let apps = [app("Safari"), app("Finder")]
        XCTAssertNil(InputControlService.bestAppIndex(apps, spec: ""))
        XCTAssertNil(InputControlService.bestAppIndex(apps, spec: "   \n\t "))
    }

    func testUnknownSpec_resolvesToNil() {
        XCTAssertNil(InputControlService.bestAppIndex([app("Safari")], spec: "definitely-not-running"))
    }

    func testEmptyCandidateList_resolvesToNil() {
        XCTAssertNil(InputControlService.bestAppIndex([], spec: "Safari"))
    }

    /// `NSRunningApplication` reports both fields as optionals; neither may crash or accidentally
    /// match.
    func testCandidatesWithNilFields_areToleratedAndNeverMatch() {
        let apps = [app(nil, bundle: nil), app(nil, bundle: nil), app("Safari")]
        XCTAssertEqual(InputControlService.bestAppIndex(apps, spec: "safari"), 2)
        XCTAssertNil(InputControlService.bestAppIndex([app(nil, bundle: nil)], spec: "safari"))
    }

    /// Ties inside one tier resolve to the FIRST candidate — `NSWorkspace` orders roughly by
    /// launch, so this is stable across calls rather than arbitrary.
    func testTiesWithinATier_resolveToTheFirstCandidate() {
        let apps = [app("Safari"), app("Safari")]
        XCTAssertEqual(InputControlService.bestAppIndex(apps, spec: "safari"), 0)
    }

    /// `hasAccessibility` is the NON-prompting half of the permission pair (`AXIsProcessTrusted`),
    /// so it is safe to call — unlike `requestAccessibilityIfNeeded`, which opens the System
    /// Settings prompt and must never run from a test. Pinned as a pure, repeatable query.
    func testHasAccessibility_isANonPromptingIdempotentQuery() {
        XCTAssertEqual(InputControlService.hasAccessibility(), InputControlService.hasAccessibility())
    }
}

// MARK: - Own-window self-guard (window-list filtering)

/// The impure half of the self-guard — enumerating this process's on-screen windows — decides
/// which points the model is DENIED. A window we fail to recognize as ours is a window the model
/// is allowed to click, i.e. the app operating its own UI. The filter is now `ownWindowRects`,
/// driven here with real `CGWindowListCopyWindowInfo`-shaped payloads.
final class InputControlOwnWindowRectTests: XCTestCase {

    private let ownPID = 4242

    private func info(pid: Int, rect: CGRect) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowBounds as String: (rect.dictionaryRepresentation as NSDictionary) as! [String: Any],
        ]
    }

    func testOnlyThisProcessesWindows_areReported() {
        let mine = CGRect(x: 10, y: 20, width: 300, height: 200)
        let theirs = CGRect(x: 400, y: 0, width: 800, height: 600)
        let rects = InputControlService.ownWindowRects(
            from: [info(pid: 9999, rect: theirs), info(pid: ownPID, rect: mine)], pid: ownPID)
        XCTAssertEqual(rects, [mine])
    }

    func testEveryOwnWindow_isReported_inListOrder() {
        let a = CGRect(x: 0, y: 0, width: 300, height: 200)
        let b = CGRect(x: 500, y: 100, width: 400, height: 250)
        let rects = InputControlService.ownWindowRects(
            from: [info(pid: ownPID, rect: a), info(pid: 1, rect: .init(x: 0, y: 0, width: 9, height: 9)),
                   info(pid: ownPID, rect: b)],
            pid: ownPID)
        XCTAssertEqual(rects, [a, b])
    }

    /// Zero-area bookkeeping windows (status-item shells, 1×1 offscreen helpers) are dropped. A
    /// degenerate rect can only ever produce a FALSE deny, and a deny on a point our UI doesn't
    /// actually cover reads to the model as an unexplained refusal it can't route around.
    func testDegenerateWindows_areDropped() {
        let payload = [
            info(pid: ownPID, rect: CGRect(x: 0, y: 0, width: 1, height: 1)),
            info(pid: ownPID, rect: CGRect(x: 0, y: 0, width: 0, height: 500)),
            info(pid: ownPID, rect: CGRect(x: 0, y: 0, width: 500, height: 1)),
            info(pid: ownPID, rect: .zero),
        ]
        XCTAssertEqual(InputControlService.ownWindowRects(from: payload, pid: ownPID), [])
    }

    func testEntryWithoutBounds_isSkippedRatherThanCrashing() {
        let payload: [[String: Any]] = [[kCGWindowOwnerPID as String: ownPID]]
        XCTAssertEqual(InputControlService.ownWindowRects(from: payload, pid: ownPID), [])
    }

    func testEntryWithoutOwnerPID_isSkipped() {
        let payload: [[String: Any]] = [
            [kCGWindowBounds as String: (CGRect(x: 0, y: 0, width: 300, height: 200)
                    .dictionaryRepresentation as NSDictionary) as! [String: Any]]
        ]
        XCTAssertEqual(InputControlService.ownWindowRects(from: payload, pid: ownPID), [])
    }

    func testEntryWithUnusableBounds_isSkipped() {
        let payload: [[String: Any]] = [[
            kCGWindowOwnerPID as String: ownPID,
            kCGWindowBounds as String: ["nonsense": 1],
        ]]
        XCTAssertEqual(InputControlService.ownWindowRects(from: payload, pid: ownPID), [])
    }

    func testEmptyWindowList_reportsNoRects() {
        XCTAssertEqual(InputControlService.ownWindowRects(from: [], pid: ownPID), [])
    }

    /// A NanoTeams window on a secondary monitor left of the main one has a negative origin. It
    /// must survive intact — the guard compares against CG global top-left points, and clamping
    /// would leave that window clickable.
    func testNegativeOriginWindows_survive_andStillBlockClicks() {
        let offLeft = CGRect(x: -1920, y: -300, width: 600, height: 400)
        let rects = InputControlService.ownWindowRects(from: [info(pid: ownPID, rect: offLeft)], pid: ownPID)
        XCTAssertEqual(rects, [offLeft])
        XCTAssertTrue(InputControlService.pointInAnyRect(CGPoint(x: -1900, y: -280), rects: rects))
        XCTAssertFalse(InputControlService.pointInAnyRect(CGPoint(x: 100, y: 100), rects: rects))
    }

    /// The two halves compose: what the filter reports is exactly what the containment test is
    /// asked about, so a point inside one of our windows is denied and one outside is not.
    func testFilteredRects_feedTheContainmentGuard() {
        let mine = CGRect(x: 100, y: 100, width: 200, height: 200)
        let rects = InputControlService.ownWindowRects(
            from: [info(pid: ownPID, rect: mine),
                   info(pid: 7, rect: CGRect(x: 0, y: 0, width: 1000, height: 1000))],
            pid: ownPID)
        XCTAssertTrue(InputControlService.pointInAnyRect(CGPoint(x: 150, y: 150), rects: rects))
        XCTAssertFalse(InputControlService.pointInAnyRect(CGPoint(x: 50, y: 50), rects: rects),
                       "a point inside ANOTHER app's window must stay clickable")
    }
}
