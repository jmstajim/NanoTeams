import XCTest

@testable import NanoTeams

/// The pill's tooltip is the only reader of `LLMStatusMonitor.lastCheckedAt`, and
/// the only way a re-probe is observable when the server is STILL down — the pill
/// itself looks identical before and after.
@MainActor
final class LLMStatusIndicatorTooltipTests: XCTestCase {

    private let checkedAt = Date(timeIntervalSince1970: 1_000_000)

    func testTooltip_neverChecked_omitsTheTimeClause() {
        let text = LLMStatusIndicator.tooltip(isReachable: false, lastCheckedAt: nil)

        XCTAssertEqual(text, "LLM is offline — click to configure")
    }

    func testTooltip_offline_keepsTheConfigureHint() {
        let text = LLMStatusIndicator.tooltip(isReachable: false, lastCheckedAt: checkedAt)

        XCTAssertTrue(text.hasPrefix("LLM is offline — click to configure"),
                      "the click affordance must survive the added clause")
    }

    func testTooltip_online_readsOnline() {
        let text = LLMStatusIndicator.tooltip(isReachable: true, lastCheckedAt: checkedAt)

        XCTAssertTrue(text.hasPrefix("LLM is online"), text)
    }

    /// The clause must carry the CHECK's own timestamp, so it stays true however
    /// long ago the body last ran. A relative phrasing cannot: `.help(...)` bakes a
    /// String during `body`, and the only things that invalidate this view are the
    /// two properties `publish()` writes together — so "N ago" would always be
    /// computed at ~0 elapsed and then keep claiming "just now" indefinitely.
    func testTooltip_carriesTheCheckTimestamp_notAnElapsedPhrase() {
        let text = LLMStatusIndicator.tooltip(isReachable: true, lastCheckedAt: checkedAt)

        XCTAssertTrue(
            text.contains(checkedAt.formatted(date: .omitted, time: .standard)),
            "expected the check's wall-clock time in: \(text)")
        for relativePhrase in ["just now", "ago"] {
            XCTAssertFalse(
                text.contains(relativePhrase),
                "a relative clause is frozen at body-evaluation time and would lie: \(text)")
        }
    }

    /// Same instant in, same string out — no dependence on when the tooltip is read.
    func testTooltip_isPureInItsInputs() {
        let first = LLMStatusIndicator.tooltip(isReachable: true, lastCheckedAt: checkedAt)
        let second = LLMStatusIndicator.tooltip(isReachable: true, lastCheckedAt: checkedAt)

        XCTAssertEqual(first, second)
    }

    func testTooltip_differentCheckTimes_produceDifferentText() {
        let first = LLMStatusIndicator.tooltip(isReachable: false, lastCheckedAt: checkedAt)
        let later = LLMStatusIndicator.tooltip(
            isReachable: false, lastCheckedAt: checkedAt.addingTimeInterval(61))

        XCTAssertNotEqual(first, later, "a fresh probe must be visible in the tooltip")
    }
}
