import XCTest

@testable import NanoTeams

/// The status pill's pure presentation helpers.
///
/// The ordering ones carry real logic and a real hazard: the pill is driven by an INCREMENTING
/// counter, so a comparator that is not a total order lets rows swap places on every tick while
/// the user is reading the popover. The `(a.value, b.key) > (b.value, a.key)` tuple trick that
/// gives "count descending, then name ascending" is exactly the kind of thing that survives a
/// careless edit while quietly losing the tie-break.
@MainActor
final class PrefixCacheStatusIndicatorLogicTests: XCTestCase {

    // MARK: - causeRowLabel

    /// The eviction row was structurally unable to name anyone: `PrefixCacheReporter` aggregates
    /// by `CauseClass`, which erases `Cause.serverDroppedCache`'s payload. A bare "Server dropped
    /// the cached prefix" is true and unactionable — the whole point of a suspect is to say WHICH
    /// other caller to move off this model.
    /// RED: return `cause.label` unconditionally → the row loses the lead again.
    func testCauseRowLabel_appendsTheLeadWhenThereIsOne() {
        XCTAssertEqual(
            PrefixCacheStatusIndicator.causeRowLabel(
                .serverDroppedCache, suspect: "startup_software_engineer"),
            "Server dropped the cached prefix — likely startup_software_engineer")
    }

    /// "likely", not "by": interleaving is never a proven cause here, only the last other caller
    /// seen on the same (server, model).
    /// RED: assert the label wording claims certainty → the popover states as fact what the
    /// policy explicitly refuses to make a standalone verdict.
    func testCauseRowLabel_hedgesRatherThanAccusing() {
        let label = PrefixCacheStatusIndicator.causeRowLabel(.serverDroppedCache, suspect: "x")
        XCTAssertTrue(label.contains("likely"))
    }

    /// RED: drop the `isEmpty` half of the guard → an empty suspect renders a dangling
    /// "— likely " with nothing after it.
    func testCauseRowLabel_isTheBareLabelWithoutALead() {
        XCTAssertEqual(
            PrefixCacheStatusIndicator.causeRowLabel(.serverDroppedCache, suspect: nil),
            PrefixCachePolicy.CauseClass.serverDroppedCache.label)
        XCTAssertEqual(
            PrefixCacheStatusIndicator.causeRowLabel(.modelReloaded, suspect: ""),
            PrefixCachePolicy.CauseClass.modelReloaded.label)
    }

    // MARK: - sortedCauses

    func testSortedCauses_ordersByCountDescending() {
        let sorted = PrefixCacheStatusIndicator.sortedCauses([
            .degradedReplay: 2,
            .systemPromptChanged: 9,
            .modelReloaded: 5,
        ])
        XCTAssertEqual(sorted.map(\.0), [.systemPromptChanged, .modelReloaded, .degradedReplay])
        XCTAssertEqual(sorted.map(\.1), [9, 5, 2])
    }

    /// The tie-break is what makes the order STABLE across ticks. Without it two equal counts
    /// are ordered by `Dictionary`'s iteration, which is seeded per process and reshuffles.
    func testSortedCauses_breaksTiesByNameAscending() {
        let sorted = PrefixCacheStatusIndicator.sortedCauses([
            .serverDroppedCache: 3,
            .conversationRewritten: 3,
            .degradedReplay: 3,
        ])
        XCTAssertEqual(
            sorted.map(\.0.rawValue), ["conversationRewritten", "degradedReplay", "serverDroppedCache"],
            "equal counts must fall back to a name order, or the popover reshuffles on every tick")
    }

    /// The property the tie-break exists for, stated directly: the same input always renders the
    /// same row order, whatever order the dictionary happens to hand it over in.
    func testSortedCauses_isDeterministicAcrossRepeatedCalls() {
        let counts: [PrefixCachePolicy.CauseClass: Int] = [
            .systemPromptChanged: 4, .conversationRewritten: 4,
            .degradedReplay: 4, .modelReloaded: 4, .serverDroppedCache: 4,
        ]
        let first = PrefixCacheStatusIndicator.sortedCauses(counts).map(\.0)
        for _ in 0..<20 {
            XCTAssertEqual(PrefixCacheStatusIndicator.sortedCauses(counts).map(\.0), first)
        }
    }

    func testSortedCauses_emptyInput_isEmpty() {
        XCTAssertTrue(PrefixCacheStatusIndicator.sortedCauses([:]).isEmpty)
    }

    // MARK: - sortedOwners

    func testSortedOwners_ordersByCountThenName() {
        let sorted = PrefixCacheStatusIndicator.sortedOwners(
            ["reviewer": 1, "engineer": 7, "bash judge": 7])
        XCTAssertEqual(sorted.map(\.0), ["bash judge", "engineer", "reviewer"])
        XCTAssertEqual(sorted.map(\.1), [7, 7, 1])
    }

    func testSortedOwners_emptyInput_isEmpty() {
        XCTAssertTrue(PrefixCacheStatusIndicator.sortedOwners([:]).isEmpty)
    }

    // MARK: - tooltip

    /// Singular/plural is the whole reason this is a function and not an interpolation.
    func testTooltip_agreesWithTheCount() async {
        let reporter = PrefixCacheReporter()
        reporter.report(PrefixCacheMiss(
            owner: .step(taskID: 1, stepID: "engineer"), runID: 0, modelName: "m",
            diagnosis: .init(
                cause: .degradedReplay, commonSegments: 0, previousSegments: 1,
                discardedTokens: 10_000)))

        let one = PrefixCacheStatusIndicator.tooltip(for: reporter)
        XCTAssertTrue(one.contains("1 prompt cache miss"), one)
        XCTAssertFalse(one.contains("misses"), "one miss must not read as plural: \(one)")

        reporter.report(PrefixCacheMiss(
            owner: .step(taskID: 1, stepID: "reviewer"), runID: 0, modelName: "m",
            diagnosis: .init(
                cause: .modelReloaded, commonSegments: 0, previousSegments: 1,
                discardedTokens: 10_000)))
        XCTAssertTrue(PrefixCacheStatusIndicator.tooltip(for: reporter).contains("2 prompt cache misses"))
    }
}
