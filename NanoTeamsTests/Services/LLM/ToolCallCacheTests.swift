import XCTest

@testable import NanoTeams

final class ToolCallCacheRound3Tests: XCTestCase {
    private typealias TN = ToolNames

    var sut: ToolCallCache!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        sut = ToolCallCache()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Record Tests

    func testRecord_appendsCallAndIncrementsCount() {
        let args = "{\"path\":\"/foo.swift\"}"
        sut.record(toolName: TN.readFile, argumentsJSON: args, resultJSON: "{\"content\":\"hello\"}", isError: false)
        sut.record(toolName: TN.readFile, argumentsJSON: args, resultJSON: "{\"content\":\"hello\"}", isError: false)

        XCTAssertEqual(sut.calls.count, 2)
        XCTAssertEqual(sut.getCallCount(toolName: TN.readFile, argumentsJSON: args), 2)
    }

    func testRecord_scratchpadDeduplicatesByContentHash() {
        let args1 = "{\"content\":\"plan A\"}"
        let result = "{\"ok\":true}"

        sut.record(toolName: TN.updateScratchpad, argumentsJSON: args1, resultJSON: result, isError: false)
        sut.record(toolName: TN.updateScratchpad, argumentsJSON: args1, resultJSON: result, isError: false)

        let scratchpadCalls = sut.calls.filter { $0.toolName == TN.updateScratchpad }
        XCTAssertEqual(scratchpadCalls.count, 1, "Duplicate scratchpad content should be deduped")

        let args2 = "{\"content\":\"plan B\"}"
        sut.record(toolName: TN.updateScratchpad, argumentsJSON: args2, resultJSON: result, isError: false)

        let scratchpadCalls2 = sut.calls.filter { $0.toolName == TN.updateScratchpad }
        XCTAssertEqual(scratchpadCalls2.count, 2, "Different scratchpad content should be recorded")
    }

    func testRecord_respectsMaxTrackedCallsLimit() {
        let max = LLMConstants.maxTrackedToolCalls
        for i in 0..<(max + 5) {
            sut.record(
                toolName: TN.search,
                argumentsJSON: "{\"query\":\"search_\(i)\"}",
                resultJSON: "{}",
                isError: false
            )
        }

        XCTAssertEqual(sut.calls.count, max, "Should trim to maxTrackedCalls")
    }

    // MARK: - Invalidation Tests

    func testInvalidateCacheAfterWrite_fileWriteInvalidatesFileAndGitReads() {
        sut.record(toolName: TN.readFile, argumentsJSON: "{\"path\":\"/src/main.swift\"}", resultJSON: "{\"content\":\"code\"}", isError: false)
        sut.record(toolName: TN.gitStatus, argumentsJSON: "{}", resultJSON: "{\"status\":\"clean\"}", isError: false)

        sut.invalidateCacheAfterWrite(toolName: TN.writeFile, affectedPath: "/src/main.swift")

        let readCalls = sut.calls.filter { $0.toolName == TN.readFile }
        let gitCalls = sut.calls.filter { $0.toolName == TN.gitStatus }
        XCTAssertTrue(readCalls.isEmpty, "File write should invalidate matching read_file calls")
        XCTAssertTrue(gitCalls.isEmpty, "File write should invalidate git read calls")
    }

    // MARK: - Cache Lookup Tests

    func testGetCachedResultIfRedundant_returnsCachedWithFlag() {
        let args = "{\"path\":\"/foo.swift\"}"
        sut.record(toolName: TN.readFile, argumentsJSON: args, resultJSON: "{\"content\":\"data\"}", isError: false)

        let cached = sut.getCachedResultIfRedundant(toolName: TN.readFile, argumentsJSON: args)

        XCTAssertNotNil(cached, "Should return cached result for cacheable tool")
        XCTAssertTrue(cached!.contains("\"_cached\""), "Cached result should contain _cached flag")
    }

    func testGetCachedResultIfRedundant_returnsNilForNonCacheableTool() {
        let args = "{\"path\":\"/foo.swift\",\"content\":\"new\"}"
        sut.record(toolName: TN.writeFile, argumentsJSON: args, resultJSON: "{\"ok\":true}", isError: false)

        let cached = sut.getCachedResultIfRedundant(toolName: TN.writeFile, argumentsJSON: args)
        XCTAssertNil(cached, "write_file is not cacheable")
    }
}
