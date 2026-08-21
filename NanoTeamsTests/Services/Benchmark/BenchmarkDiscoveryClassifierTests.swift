import XCTest

@testable import NanoTeams

/// Pins the four ways a model-list lookup can end, and the three different things they mean.
///
/// The whole point of the type is that `ModelCatalog.refresh` returning `false` claims NOTHING —
/// its own doc says callers may use `true` to turn reachability on, never off — so a classifier
/// that read `false` as "the server is silent" would put a lie on screen and, worse, withhold the
/// clearing pass from a server that was answering all along.
final class BenchmarkDiscoveryClassifierTests: XCTestCase {

    /// RED: return `.undetermined` on success → a healthy server is never verified, so it is never
    /// cleared and none of its models are ever planned.
    func testRefreshedTrue_isAnAnswer() {
        let outcome = BenchmarkDiscoveryClassifier.classify(
            refreshed: true, hasLoaded: true, models: ["a", "b"], error: nil)

        XCTAssertEqual(outcome, .answered(["a", "b"]))
    }

    /// An empty list from a live server is a FACT about the server, and it is the case that earns
    /// a clearing pass without contributing a target — an embedding-only server is exactly this.
    ///
    /// RED: map empty to `.noAnswer` → the server holding a resident embedder is the one server
    /// the sweep never clears.
    func testRefreshedTrueWithNoModels_isStillAnAnswer() {
        let outcome = BenchmarkDiscoveryClassifier.classify(
            refreshed: true, hasLoaded: true, models: [], error: nil)

        XCTAssertEqual(outcome, .answered([]))
    }

    /// RED: check `hasLoaded` before `error` → a server that has just started refusing with 401
    /// keeps reporting the model list it answered with an hour ago.
    func testCapturedError_isNoAnswerAndCarriesIt() {
        let outcome = BenchmarkDiscoveryClassifier.classify(
            refreshed: false, hasLoaded: true, models: ["stale"], error: "401 unauthorized")

        XCTAssertEqual(outcome, .noAnswer(detail: "401 unauthorized"))
    }

    /// A refresh that lost the race to an in-flight fetch returns `false` having observed nothing.
    /// If the catalog already holds a list, an EARLIER lookup did succeed.
    ///
    /// RED: return `.undetermined` whenever `refreshed` is false → the common case of the screen's
    /// own model picker fetching at the same moment makes every scan inconclusive.
    func testCoalescedRefreshOverACachedList_isTheCachedAnswer() {
        let outcome = BenchmarkDiscoveryClassifier.classify(
            refreshed: false, hasLoaded: true, models: ["cached"], error: nil)

        XCTAssertEqual(outcome, .answered(["cached"]))
    }

    /// Nothing failed and nothing was ever cached: this call simply did not observe an answer.
    ///
    /// RED: fold this into `.noAnswer` → the row says "no answer" about a server that was never
    /// asked by anyone whose result we saw, and a rescan is never suggested.
    func testCoalescedRefreshWithNothingCached_isUndetermined() {
        let outcome = BenchmarkDiscoveryClassifier.classify(
            refreshed: false, hasLoaded: false, models: [], error: nil)

        XCTAssertEqual(outcome, .undetermined)
    }

    /// RED: treat an empty-string error as a real one → `.noAnswer(detail: "")` renders as a
    /// dangling "no answer — " with nothing after it.
    func testEmptyErrorString_isNotTreatedAsAFailure() {
        let outcome = BenchmarkDiscoveryClassifier.classify(
            refreshed: false, hasLoaded: false, models: [], error: "")

        XCTAssertEqual(outcome, .undetermined)
    }
}
