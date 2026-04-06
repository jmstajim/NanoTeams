import XCTest
@testable import NanoTeams

final class MonotonicClockTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Basic Tests

    func testNowReturnsValidDate() {
        let date = MonotonicClock.shared.now()
        XCTAssertNotNil(date)
    }

    func testConsecutiveCallsReturnIncreasingTimestamps() {
        let first = MonotonicClock.shared.now()
        let second = MonotonicClock.shared.now()
        let third = MonotonicClock.shared.now()

        XCTAssertLessThan(first, second, "Second timestamp should be greater than first")
        XCTAssertLessThan(second, third, "Third timestamp should be greater than second")
    }

    func testMinimum1msGapBetweenCalls() {
        let first = MonotonicClock.shared.now()
        let second = MonotonicClock.shared.now()

        let interval = second.timeIntervalSince(first)
        XCTAssertGreaterThanOrEqual(interval, 0.001, "Gap should be at least 1ms")
    }

    // MARK: - Rapid Call Tests

    func testRapidConsecutiveCalls() {
        var timestamps: [Date] = []

        for _ in 0..<100 {
            timestamps.append(MonotonicClock.shared.now())
        }

        for i in 1..<timestamps.count {
            XCTAssertLessThan(
                timestamps[i - 1],
                timestamps[i],
                "Timestamp at index \(i) should be greater than timestamp at index \(i - 1)"
            )
        }
    }

    func testAllTimestampsAreUnique() {
        var timestamps: Set<Date> = []

        for _ in 0..<1000 {
            let date = MonotonicClock.shared.now()
            XCTAssertFalse(timestamps.contains(date), "All timestamps should be unique")
            timestamps.insert(date)
        }

        XCTAssertEqual(timestamps.count, 1000, "Should have 1000 unique timestamps")
    }

    // MARK: - Thread Safety Tests

    func testConcurrentAccessProducesStrictlyIncreasingTimestamps() {
        let expectation = expectation(description: "Concurrent access")
        expectation.expectedFulfillmentCount = 10

        let lock = NSLock()
        var allTimestamps: [Date] = []

        for _ in 0..<10 {
            DispatchQueue.global().async {
                var localTimestamps: [Date] = []
                for _ in 0..<100 {
                    localTimestamps.append(MonotonicClock.shared.now())
                }

                lock.lock()
                allTimestamps.append(contentsOf: localTimestamps)
                lock.unlock()

                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)

        // Sort and verify all timestamps are unique
        let sortedTimestamps = allTimestamps.sorted()
        var uniqueTimestamps = Set<Date>()
        for timestamp in sortedTimestamps {
            XCTAssertFalse(uniqueTimestamps.contains(timestamp), "All timestamps should be unique even with concurrent access")
            uniqueTimestamps.insert(timestamp)
        }

        XCTAssertEqual(uniqueTimestamps.count, 1000, "Should have 1000 unique timestamps from 10 threads x 100 calls")
    }

    // MARK: - Reset Tests

    func testResetAllowsClockToRestartFromSystemTime() {
        // Generate some timestamps
        _ = MonotonicClock.shared.now()
        _ = MonotonicClock.shared.now()
        _ = MonotonicClock.shared.now()

        // Reset the clock
        MonotonicClock.shared.reset()

        // After reset, the clock should use system time again
        let afterReset = MonotonicClock.shared.now()
        let systemNow = Date()

        // The timestamp after reset should be very close to system time (within 100ms)
        let diff = abs(afterReset.timeIntervalSince(systemNow))
        XCTAssertLessThan(diff, 0.1, "After reset, clock should be close to system time")
    }
}
