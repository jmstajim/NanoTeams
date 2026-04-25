import XCTest
@testable import NanoTeams

final class ToolSignalExpandedSearchTests: XCTestCase {

    // Smoke test: ToolSignal with expandedSearch case must remain Hashable so it
    // composes into ToolExecutionResult: Hashable.

    private func makePayload(
        query: String = "scroll",
        mode: SearchMode = .substring,
        paths: [String]? = nil,
        fileGlob: String? = nil
    ) -> ExpandedSearchPayload {
        // `try!` is deliberate — the fixture values are all valid. Tests that
        // exercise validation failures construct the init explicitly.
        // swiftlint:disable:next force_try
        try! ExpandedSearchPayload(
            query: query,
            mode: mode,
            paths: paths,
            fileGlob: fileGlob,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 20,
            maxMatchLines: 40
        )
    }

    // MARK: - I7: throwing init + clamping

    func testPayload_emptyQuery_throws() {
        XCTAssertThrowsError(try ExpandedSearchPayload(
            query: "",
            mode: .substring,
            paths: nil,
            fileGlob: nil,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 20,
            maxMatchLines: 40
        ))
    }

    func testPayload_whitespaceOnlyQuery_throws() {
        XCTAssertThrowsError(try ExpandedSearchPayload(
            query: "   \n\t  ",
            mode: .substring,
            paths: nil,
            fileGlob: nil,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 20,
            maxMatchLines: 40
        ))
    }

    func testPayload_negativeMaxResults_clamped() throws {
        let p = try ExpandedSearchPayload(
            query: "x", mode: .substring,
            paths: nil, fileGlob: nil,
            contextBefore: 0, contextAfter: 0,
            maxResults: -5, maxMatchLines: 40
        )
        XCTAssertGreaterThanOrEqual(p.maxResults, 1,
            "Negative maxResults must clamp to the positive domain.")
    }

    func testPayload_hugeMaxResults_clamped() throws {
        let p = try ExpandedSearchPayload(
            query: "x", mode: .substring,
            paths: nil, fileGlob: nil,
            contextBefore: 0, contextAfter: 0,
            maxResults: 1_000_000, maxMatchLines: 40
        )
        XCTAssertLessThanOrEqual(p.maxResults, ExpandedSearchPayload.maxAllowedResults,
            "Pathologically large maxResults must clamp.")
    }

    func testPayload_negativeContext_clampedToZero() throws {
        let p = try ExpandedSearchPayload(
            query: "x", mode: .substring,
            paths: nil, fileGlob: nil,
            contextBefore: -1, contextAfter: -1,
            maxResults: 20, maxMatchLines: 40
        )
        XCTAssertEqual(p.contextBefore, 0)
        XCTAssertEqual(p.contextAfter, 0)
    }

    func testPayload_emptyPathsArray_normalizedToNil() throws {
        let p = try ExpandedSearchPayload(
            query: "x", mode: .substring,
            paths: [], fileGlob: nil,
            contextBefore: 0, contextAfter: 0,
            maxResults: 20, maxMatchLines: 40
        )
        XCTAssertNil(p.paths, "Empty `paths` array must normalize to nil so callers don't switch on both.")
    }

    func testExpandedSearch_hashable_sameArgs_equalHash() {
        let a: ToolSignal = .expandedSearch(makePayload())
        let b: ToolSignal = .expandedSearch(makePayload())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testExpandedSearch_differsByQuery() {
        let a: ToolSignal = .expandedSearch(makePayload(query: "scroll"))
        let b: ToolSignal = .expandedSearch(makePayload(query: "view"))
        XCTAssertNotEqual(a, b)
    }

    func testExpandedSearch_differsByMode() {
        let a: ToolSignal = .expandedSearch(makePayload(mode: .substring))
        let b: ToolSignal = .expandedSearch(makePayload(mode: .regex))
        XCTAssertNotEqual(a, b)
    }

    func testExpandedSearch_differsByPaths() {
        let a: ToolSignal = .expandedSearch(makePayload(paths: ["src"]))
        let b: ToolSignal = .expandedSearch(makePayload(paths: ["docs"]))
        XCTAssertNotEqual(a, b)
    }

    // Ensures the executor result containing a expandedSearch signal can be stored
    // in a Set / compared in a test assertion without custom equatable work.
    func testToolExecutionResult_withExpandedSearchSignal_isHashable() {
        let r = ToolExecutionResult(
            toolName: ToolNames.search,
            argumentsJSON: "{}",
            outputJSON: "{}",
            isError: false,
            signal: .expandedSearch(makePayload())
        )
        let set: Set<ToolExecutionResult> = [r]
        XCTAssertTrue(set.contains(r))
    }
}
