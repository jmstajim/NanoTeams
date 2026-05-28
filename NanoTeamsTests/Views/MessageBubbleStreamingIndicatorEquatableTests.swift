import SwiftUI
import XCTest

@testable import NanoTeams

/// Drift-guard for `MessageBubbleStreamingIndicator.==` (synthesized).
/// Each stored prop covered must participate in equality — otherwise
/// `.equatable()` at the call site in `MessageBubbleView.body` would
/// silently drop updates to that prop. If you add a new stored prop to
/// `MessageBubbleStreamingIndicator` and this suite still passes, you
/// forgot to either include it in `==` (synthesis covers it automatically
/// for stored props) or update this suite.
///
/// Pattern mirrors `MessageBubbleEquatableTests`: build two views via a
/// factory, override exactly one prop in the second, assert `==` returns
/// false. Plus one test that two fully-equal baselines compare equal.
@MainActor
final class MessageBubbleStreamingIndicatorEquatableTests: XCTestCase {

    // MARK: - Factory

    /// All defaults form the canonical baseline (`isStreaming: false`,
    /// nothing else set). Each test overrides exactly ONE knob.
    private static func makeIndicator(
        isStreaming: Bool = false,
        isImplicitStreamTarget: Bool = false,
        hasMessageContent: Bool = false,
        hasThinkingContent: Bool = false,
        processingProgress: Double? = nil,
        hasStreamActivity: Bool = false
    ) -> MessageBubbleStreamingIndicator {
        MessageBubbleStreamingIndicator(
            isStreaming: isStreaming,
            isImplicitStreamTarget: isImplicitStreamTarget,
            hasMessageContent: hasMessageContent,
            hasThinkingContent: hasThinkingContent,
            processingProgress: processingProgress,
            hasStreamActivity: hasStreamActivity
        )
    }

    // MARK: - Identical baselines compare equal

    func testEqual_whenAllPropsMatch() async {
        XCTAssertEqual(Self.makeIndicator(), Self.makeIndicator())
    }

    // MARK: - Per-prop drift coverage

    func testNotEqual_whenIsStreamingDiffers() async {
        XCTAssertNotEqual(Self.makeIndicator(), Self.makeIndicator(isStreaming: true))
    }

    func testNotEqual_whenHasMessageContentDiffers() async {
        XCTAssertNotEqual(Self.makeIndicator(), Self.makeIndicator(hasMessageContent: true))
    }

    func testNotEqual_whenHasThinkingContentDiffers() async {
        XCTAssertNotEqual(Self.makeIndicator(), Self.makeIndicator(hasThinkingContent: true))
    }

    func testNotEqual_whenProcessingProgressDiffers() async {
        XCTAssertNotEqual(Self.makeIndicator(), Self.makeIndicator(processingProgress: 0.5))
    }

    func testNotEqual_whenHasStreamActivityDiffers() async {
        XCTAssertNotEqual(Self.makeIndicator(), Self.makeIndicator(hasStreamActivity: true))
    }

    func testNotEqual_whenIsImplicitStreamTargetDiffers() async {
        XCTAssertNotEqual(Self.makeIndicator(), Self.makeIndicator(isImplicitStreamTarget: true))
    }

    // MARK: - Steady-state equality (the hot path this optimization targets)

    /// Pin the actual streaming steady-state combinations the optimization
    /// is meant to skip: every 0.3s tick during a "Waiting" / "Generating" /
    /// "Processing" phase produces identical inputs (no content yet, no
    /// thinking yet). `==` must return true so SwiftUI skips the subtree.
    func testEqual_whenSteadyStateWaiting() async {
        let a = Self.makeIndicator(isStreaming: true)
        let b = Self.makeIndicator(isStreaming: true)
        XCTAssertEqual(a, b)
    }

    func testEqual_whenSteadyStateGenerating() async {
        let a = Self.makeIndicator(isStreaming: true, hasStreamActivity: true)
        let b = Self.makeIndicator(isStreaming: true, hasStreamActivity: true)
        XCTAssertEqual(a, b)
    }

    func testEqual_whenSteadyStateProcessing() async {
        let a = Self.makeIndicator(isStreaming: true, processingProgress: 0.42)
        let b = Self.makeIndicator(isStreaming: true, processingProgress: 0.42)
        XCTAssertEqual(a, b)
    }

    // MARK: - Real-world streaming transitions (must propagate, must not be coalesced)

    /// `Waiting → Generating` happens when the first delta of any kind arrives
    /// (`hasStreamActivity` flips false → true) before any visible content /
    /// thinking. SwiftUI must re-evaluate so the status row text flips
    /// `"Waiting"` → `"Generating"`.
    func testNotEqual_waitingToGenerating() async {
        let waiting    = Self.makeIndicator(isStreaming: true, hasStreamActivity: false)
        let generating = Self.makeIndicator(isStreaming: true, hasStreamActivity: true)
        XCTAssertNotEqual(waiting, generating)
    }

    /// `Generating → Processing` happens when `processingProgress` lands
    /// (typically nil → ~0.0–0.05) while `hasStreamActivity` is already true.
    /// Status row flips `"Generating"` → `"Processing"`.
    func testNotEqual_generatingToProcessing() async {
        let generating = Self.makeIndicator(isStreaming: true, hasStreamActivity: true)
        let processing = Self.makeIndicator(isStreaming: true, processingProgress: 0.1, hasStreamActivity: true)
        XCTAssertNotEqual(generating, processing)
    }

    /// `Streaming → Committed` (`isStreaming` true → false) is the flip that
    /// hides the status row entirely. Even though the post-commit `body`
    /// returns nil, `==` must distinguish the two values — otherwise the
    /// dispatcher's `.equatable()` would suppress the commit transition.
    func testNotEqual_streamingToCommitted() async {
        let streaming = Self.makeIndicator(isStreaming: true, hasStreamActivity: true)
        let committed = Self.makeIndicator(isStreaming: false, hasStreamActivity: true)
        XCTAssertNotEqual(streaming, committed)
    }

    /// `Committed → Implicit target` is the new transition this fix
    /// introduces: after `isStreaming` flips false (text committed), the
    /// dispatcher sets `isImplicitStreamTarget = true` so the latest
    /// committed bubble of a still-running step picks up the
    /// "Generating" / "Processing" pill while the LLM keeps producing
    /// invisible output (tool-call args, prompt processing for the next
    /// iteration). `==` must distinguish these so the status row actually
    /// appears.
    func testNotEqual_committedToImplicitTarget() async {
        let committed       = Self.makeIndicator(isStreaming: false, isImplicitStreamTarget: false, hasMessageContent: true, hasStreamActivity: true)
        let implicitTarget  = Self.makeIndicator(isStreaming: false, isImplicitStreamTarget: true,  hasMessageContent: true, hasStreamActivity: true)
        XCTAssertNotEqual(committed, implicitTarget)
    }

    // MARK: - Numeric edge cases (defense against future "normalize" refactors)

    /// `processingProgress` ticks in small deltas (~0.01) during real
    /// streaming. If a future refactor introduces fuzzy `Double?` equality
    /// (e.g. epsilon comparison), per-tick progress updates would silently
    /// stop propagating. Pin the boundary so synthesized `==` stays exact.
    func testNotEqual_processingProgressMinorDelta() async {
        let a = Self.makeIndicator(isStreaming: true, processingProgress: 0.10)
        let b = Self.makeIndicator(isStreaming: true, processingProgress: 0.11)
        XCTAssertNotEqual(a, b)
    }

    /// `processingProgress: nil` and `processingProgress: 0.0` carry
    /// **different** semantics — nil means "no progress signal at all"
    /// (status row shows "Waiting"/"Generating"), 0.0 means "progress 0%
    /// reported" (status row shows "Processing 0%"). A "normalize nil to
    /// zero" refactor would collapse them; this test stops that.
    func testNotEqual_processingProgressNilVsZero() async {
        XCTAssertNotEqual(
            Self.makeIndicator(isStreaming: true, processingProgress: nil),
            Self.makeIndicator(isStreaming: true, processingProgress: 0.0)
        )
    }
}
