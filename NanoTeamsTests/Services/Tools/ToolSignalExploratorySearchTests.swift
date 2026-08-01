import XCTest
@testable import NanoTeams

final class ToolSignalExploratorySearchTests: XCTestCase {

    // Smoke test: ToolSignal with exploratorySearch case must remain Hashable so it
    // composes into ToolExecutionResult: Hashable.

    private func makePayload(
        query: String = "scroll",
        mode: SearchMode = .substring,
        paths: [String]? = nil,
        fileGlob: String? = nil
    ) -> ExploratorySearchPayload {
        // `try!` is deliberate — the fixture values are all valid. Tests that
        // exercise validation failures construct the init explicitly.
        // swiftlint:disable:next force_try
        try! ExploratorySearchPayload(
            query: query,
            mode: mode,
            paths: paths,
            fileGlob: fileGlob,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 20
        )
    }

    // MARK: - I7: throwing init + clamping

    func testPayload_emptyQuery_throws() {
        XCTAssertThrowsError(try ExploratorySearchPayload(
            query: "",
            mode: .substring,
            paths: nil,
            fileGlob: nil,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 20
        ))
    }

    func testPayload_whitespaceOnlyQuery_throws() {
        XCTAssertThrowsError(try ExploratorySearchPayload(
            query: "   \n\t  ",
            mode: .substring,
            paths: nil,
            fileGlob: nil,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 20
        ))
    }

    func testPayload_negativeMaxResults_clamped() throws {
        let p = try ExploratorySearchPayload(
            query: "x", mode: .substring,
            paths: nil, fileGlob: nil,
            contextBefore: 0, contextAfter: 0,
            maxResults: -5
        )
        XCTAssertGreaterThanOrEqual(p.maxResults, 1,
            "Negative maxResults must clamp to the positive domain.")
    }

    func testPayload_hugeMaxResults_clamped() throws {
        let p = try ExploratorySearchPayload(
            query: "x", mode: .substring,
            paths: nil, fileGlob: nil,
            contextBefore: 0, contextAfter: 0,
            maxResults: 1_000_000
        )
        XCTAssertLessThanOrEqual(p.maxResults, ExploratorySearchPayload.maxAllowedResults,
            "Pathologically large maxResults must clamp.")
    }

    func testPayload_negativeContext_clampedToZero() throws {
        let p = try ExploratorySearchPayload(
            query: "x", mode: .substring,
            paths: nil, fileGlob: nil,
            contextBefore: -1, contextAfter: -1,
            maxResults: 20
        )
        XCTAssertEqual(p.contextBefore, 0)
        XCTAssertEqual(p.contextAfter, 0)
    }

    func testPayload_emptyPathsArray_normalizedToNil() throws {
        let p = try ExploratorySearchPayload(
            query: "x", mode: .substring,
            paths: [], fileGlob: nil,
            contextBefore: 0, contextAfter: 0,
            maxResults: 20
        )
        XCTAssertNil(p.paths, "Empty `paths` array must normalize to nil so callers don't switch on both.")
    }

    func testExploratorySearch_hashable_sameArgs_equalHash() {
        let a: ToolSignal = .exploratorySearch(makePayload())
        let b: ToolSignal = .exploratorySearch(makePayload())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testExploratorySearch_differsByQuery() {
        let a: ToolSignal = .exploratorySearch(makePayload(query: "scroll"))
        let b: ToolSignal = .exploratorySearch(makePayload(query: "view"))
        XCTAssertNotEqual(a, b)
    }

    func testExploratorySearch_differsByMode() {
        let a: ToolSignal = .exploratorySearch(makePayload(mode: .substring))
        let b: ToolSignal = .exploratorySearch(makePayload(mode: .regex))
        XCTAssertNotEqual(a, b)
    }

    func testExploratorySearch_differsByPaths() {
        let a: ToolSignal = .exploratorySearch(makePayload(paths: ["src"]))
        let b: ToolSignal = .exploratorySearch(makePayload(paths: ["docs"]))
        XCTAssertNotEqual(a, b)
    }

    // Ensures the executor result containing a exploratorySearch signal can be stored
    // in a Set / compared in a test assertion without custom equatable work.
    func testToolExecutionResult_withExploratorySearchSignal_isHashable() {
        let r = ToolExecutionResult(
            toolName: ToolNames.search,
            argumentsJSON: "{}",
            outputJSON: "{}",
            isError: false,
            signal: .exploratorySearch(makePayload())
        )
        let set: Set<ToolExecutionResult> = [r]
        XCTAssertTrue(set.contains(r))
    }
}
