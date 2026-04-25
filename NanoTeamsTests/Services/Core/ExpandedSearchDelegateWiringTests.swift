import XCTest
@testable import NanoTeams

/// Validates that `NTMSOrchestrator` correctly forwards the `LLMStateDelegate`
/// hooks used by `LLMExecutionService+ExpandedSearch`: `expandedSearchEnabled`,
/// `awaitSearchIndex`, and `expandSearchQuery`. These are the hooks read on
/// every `expand` call.
@MainActor
final class ExpandedSearchDelegateWiringTests: NTMSOrchestratorTestBase {

    // MARK: - expandedSearchEnabled

    func testExpandedSearchEnabled_defaultsToFalse() {
        XCTAssertFalse(sut.expandedSearchEnabled)
    }

    func testExpandedSearchEnabled_reflectsConfiguration() {
        sut.configuration.expandedSearchEnabled = true
        XCTAssertTrue(sut.expandedSearchEnabled)

        sut.configuration.expandedSearchEnabled = false
        XCTAssertFalse(sut.expandedSearchEnabled)
    }

    // MARK: - expandSearchQuery

    func testExpandSearchQuery_withoutCoordinator_returnsUnavailable() async {
        // No coordinator on the orchestrator (expanded search disabled) → the
        // delegate must return a clean `.unavailable` case rather than throw
        // or crash. `+ExpandedSearch.swift` relies on this to fall back to a
        // plain posting-list search.
        XCTAssertNil(sut.searchIndexCoordinator)
        let expansion = await sut.expandSearchQuery(query: "user", tokens: ["user"])
        XCTAssertEqual(expansion, .unavailable(reason: VocabVectorIndexService.reasonMissing))
        // Convenience accessors surface the same info — pin them so +ExpandedSearch's
        // `errorReason ?? unavailableReason` coalescing keeps working.
        XCTAssertEqual(expansion.unavailableReason, VocabVectorIndexService.reasonMissing)
        XCTAssertNil(expansion.errorReason)
        XCTAssertTrue(expansion.terms.isEmpty)
    }

    // MARK: - awaitSearchIndex

    func testAwaitSearchIndex_disabled_returnsNil() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertFalse(sut.expandedSearchEnabled)
        let idx = await sut.awaitSearchIndex()
        XCTAssertNil(idx, "Disabled feature must return nil so the processor falls back.")
    }

    func testAwaitSearchIndex_enabled_returnsBuiltIndex() async throws {
        try "class Marker {}".write(
            to: tempDir.appendingPathComponent("Marker.swift"),
            atomically: true, encoding: .utf8
        )
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()

        let idx = await sut.awaitSearchIndex()
        XCTAssertNotNil(idx)
        XCTAssertTrue(idx?.tokens.contains("marker") ?? false,
            "awaitSearchIndex must return the built index, not a fresh empty one.")
    }

    // MARK: - Multiple awaitSearchIndex calls share the same index

    func testAwaitSearchIndex_multipleCalls_returnSameIndexBetweenChanges() async throws {
        try "class Foo {}".write(
            to: tempDir.appendingPathComponent("Foo.swift"),
            atomically: true, encoding: .utf8
        )
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()

        let first = await sut.awaitSearchIndex()
        let second = await sut.awaitSearchIndex()
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.generatedAt, second?.generatedAt,
            "Repeated calls between changes must return the same cached build.")
    }

    // MARK: - Toggle off mid-flight

    func testToggleOffBetweenCalls_subsequentAwaitReturnsNil() async throws {
        try "class Foo {}".write(
            to: tempDir.appendingPathComponent("Foo.swift"),
            atomically: true, encoding: .utf8
        )
        await sut.openWorkFolder(tempDir)
        sut.configuration.expandedSearchEnabled = true
        await sut.onExpandedSearchSettingChanged()
        let idxEnabled = await sut.awaitSearchIndex()
        XCTAssertNotNil(idxEnabled)

        sut.configuration.expandedSearchEnabled = false
        await sut.onExpandedSearchSettingChanged()
        let idxDisabled = await sut.awaitSearchIndex()
        XCTAssertNil(idxDisabled,
            "After disable, the delegate must report no index available.")
    }
}
