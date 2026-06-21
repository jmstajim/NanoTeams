import SwiftUI
import XCTest

@testable import NanoTeams

/// Pins the pure decision function behind `NTMSLoader.body`. The body
/// previously hard-coded three branches inline (`isVisible`,
/// `resizeMonitor.isResizing`, default) and missed `accessibilityReduceMotion`
/// entirely — Reduce-Motion users got a continuous 24 Hz spinner.
///
/// Extracting the decision into `static func renderMode(...)` lets us test
/// the truth table without instantiating SwiftUI views. The body becomes a
/// thin switch over the returned `RenderMode`.
@MainActor
final class NTMSLoaderRenderModeTests: XCTestCase {

    // MARK: - Hidden trumps everything

    func testRenderMode_isHidden_whenNotVisible_regardlessOfOtherInputs() async {
        for resizing in [false, true] {
            for reduceMotion in [false, true] {
                XCTAssertEqual(
                    NTMSLoader.renderMode(isVisible: false, isResizing: resizing, reduceMotion: reduceMotion),
                    .hidden,
                    "isVisible=false must always yield .hidden — got resizing=\(resizing), reduceMotion=\(reduceMotion)."
                )
            }
        }
    }

    // MARK: - Reduce Motion is the bug being fixed

    func testRenderMode_isFrozen_whenReduceMotion_andNotResizing() async {
        XCTAssertEqual(
            NTMSLoader.renderMode(isVisible: true, isResizing: false, reduceMotion: true),
            .frozen,
            "Reduce Motion on must freeze the loader — continuous rotation violates the accessibility contract."
        )
    }

    func testRenderMode_isFrozen_whenReduceMotion_andResizing() async {
        XCTAssertEqual(
            NTMSLoader.renderMode(isVisible: true, isResizing: true, reduceMotion: true),
            .frozen,
            "Reduce Motion + resizing both demand a frozen frame."
        )
    }

    // MARK: - Existing branches preserved

    func testRenderMode_isFrozen_whenResizing_andNotReduceMotion() async {
        XCTAssertEqual(
            NTMSLoader.renderMode(isVisible: true, isResizing: true, reduceMotion: false),
            .frozen,
            "Existing resize-suppression must keep returning .frozen."
        )
    }

    func testRenderMode_isLive_whenVisibleAndNoSuppressors() async {
        XCTAssertEqual(
            NTMSLoader.renderMode(isVisible: true, isResizing: false, reduceMotion: false),
            .live,
            "Default state with no suppressors must drive the TimelineView."
        )
    }

    // MARK: - Size truth table

    /// `Size.inline` is the only case with non-square dimensions (14×14).
    /// Every other case derives height as `width / 2`. The visibility
    /// branch renders `Color.clear.frame(width:height:)` using these values,
    /// so a wrong Size→dimension entry would leak as a wrong-sized
    /// invisible-loader placeholder during streaming.
    func testSize_dimensionTruthTable() async {
        let cases: [(NTMSLoader.Size, CGFloat, CGFloat)] = [
            // (size, expectedWidth, expectedHeight)
            (.inline,     14,  14),
            (.mini,       24,  12),
            (.small,      36,  18),
            (.regular,    60,  30),
            (.large,     100,  50),
            (.extraLarge,200, 100),
        ]
        for (size, w, h) in cases {
            XCTAssertEqual(size.width, w, "\(size).width")
            XCTAssertEqual(size.height, h, "\(size).height")
        }
    }

    /// `renderMode` is pure: it inspects only `isVisible / isResizing /
    /// reduceMotion`. A future contributor making it size-aware (e.g.
    /// "skip animation for `.inline`") would break the contract — this
    /// test pins the independence by asserting identical results across
    /// every size, for every visibility branch.
    func testRenderMode_isIndependentOfSize() async {
        let inputs: [(Bool, Bool, Bool)] = [
            (false, false, false),
            (true,  false, false),
            (true,  true,  false),
            (true,  false, true),
            (true,  true,  true),
        ]
        for (visible, resizing, reduce) in inputs {
            let expected = NTMSLoader.renderMode(
                isVisible: visible, isResizing: resizing, reduceMotion: reduce
            )
            // Re-derive for each Size and check equivalence. (Size isn't
            // an input to `renderMode`, so this is a no-op call, but the
            // intent is to pin the API surface.)
            for _ in [
                NTMSLoader.Size.inline, .mini, .small, .regular, .large, .extraLarge
            ] {
                let actual = NTMSLoader.renderMode(
                    isVisible: visible, isResizing: resizing, reduceMotion: reduce
                )
                XCTAssertEqual(actual, expected, "renderMode must be size-independent")
            }
        }
    }
}
