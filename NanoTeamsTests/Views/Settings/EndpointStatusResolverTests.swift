import XCTest
@testable import NanoTeams

/// Pins the priority rules of `EndpointStatus.resolve`.
///
/// Trivial after the catalog refactor — the resolver only suppresses
/// stale errors during in-flight fetches and collapses empty/whitespace
/// errors to nil. The "don't leak global server errors" invariant moved
/// up to the catalog level (one fetch per URL, deduped).
final class EndpointStatusResolverTests: XCTestCase {

    func testNoError_returnsNil() {
        XCTAssertNil(EndpointStatus.resolve(fetchError: nil, isFetching: false))
    }

    func testFetchInFlight_suppressesError() {
        let status = EndpointStatus.resolve(
            fetchError: "Stale error from prior attempt",
            isFetching: true
        )
        XCTAssertNil(status,
                     "While a fetch is in flight, the spinner speaks — don't flash a stale error mid-refresh")
    }

    func testFetchError_surfacesAsError() {
        XCTAssertEqual(
            EndpointStatus.resolve(
                fetchError: "Could not connect to the server.",
                isFetching: false
            ),
            .error("Could not connect to the server.")
        )
    }

    func testWhitespaceOnlyError_treatedAsEmpty() {
        XCTAssertNil(
            EndpointStatus.resolve(fetchError: "   \n\t  ", isFetching: false),
            "Whitespace-only error strings are visually empty — must not render an empty status row"
        )
    }

    func testEmptyError_returnsNil() {
        XCTAssertNil(EndpointStatus.resolve(fetchError: "", isFetching: false))
    }
}
