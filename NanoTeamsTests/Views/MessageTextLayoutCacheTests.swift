import AppKit
import XCTest

@testable import NanoTeams

/// Pins the `MessageTextLayoutCache` contract: same `(length, ceil(width))`
/// hits cache; length change misses; width change misses; rebinding to a
/// different `NSTextStorage` invalidates.
///
/// The cache exists to make `SelectableMessageText.sizeThatFits` cheap
/// during `NSWindow inLiveResize`. SwiftUI proposes the same width many
/// times per gesture (60-120 Hz). Without caching, each proposal ran a
/// full TextKit shaping pass — the C arm of the 4.41 s hang lineage.
/// If a future refactor breaks the cache key (e.g. forgets to ceil the
/// width), every proposal misses and the hang returns silently.
@MainActor
final class MessageTextLayoutCacheTests: XCTestCase {

    private var cache: MessageTextLayoutCache!
    private var storage: NSTextStorage!

    override func setUp() async throws {
        try await super.setUp()
        cache = MessageTextLayoutCache()
        storage = NSTextStorage(string: "Hello, world. This is a sample bubble that should wrap onto two or three lines at a narrow width.")
    }

    override func tearDown() async throws {
        cache?.dismantle()
        cache = nil
        storage = nil
        try await super.tearDown()
    }

    // MARK: - Cache hit / miss

    func testSecondCall_sameInputs_isCacheHit() async {
        _ = cache.measure(textStorage: storage, width: 200)
        _ = cache.measure(textStorage: storage, width: 200)
        XCTAssertEqual(cache.computeCount, 1, "Identical (storage, width) must hit cache on second call.")
        XCTAssertEqual(cache.hitCount, 1)
    }

    func testSubPixelWidthJitter_doesNotInvalidate() async {
        _ = cache.measure(textStorage: storage, width: 199.4)
        _ = cache.measure(textStorage: storage, width: 199.6)
        // Both ceil to 200.
        XCTAssertEqual(cache.computeCount, 1, "Sub-pixel width jitter that ceil()s to the same int must not invalidate.")
        XCTAssertEqual(cache.hitCount, 1)
    }

    func testWidthChange_invalidatesCache() async {
        _ = cache.measure(textStorage: storage, width: 200)
        _ = cache.measure(textStorage: storage, width: 250)
        XCTAssertEqual(cache.computeCount, 2, "Width change must miss cache.")
    }

    func testLengthChange_invalidatesCache() async {
        _ = cache.measure(textStorage: storage, width: 200)
        storage.append(NSAttributedString(string: " More text appended to extend the bubble length."))
        _ = cache.measure(textStorage: storage, width: 200)
        XCTAssertEqual(cache.computeCount, 2, "Length change must miss cache.")
    }

    func testRebindToDifferentStorage_invalidates() async {
        _ = cache.measure(textStorage: storage, width: 200)
        let otherStorage = NSTextStorage(string: "Different content.")
        _ = cache.measure(textStorage: otherStorage, width: 200)
        XCTAssertEqual(cache.computeCount, 2, "Rebinding to a different textStorage must invalidate.")
    }

    // MARK: - Result correctness

    func testMeasure_returnsCeiledHeight() async {
        let height = cache.measure(textStorage: storage, width: 200)
        XCTAssertGreaterThan(height, 0, "Height must be positive for non-empty text.")
        XCTAssertEqual(height, height.rounded(.up), "Height must be ceiled (integer).")
    }

    func testMeasure_widerWidth_returnsShorterOrEqualHeight() async {
        let narrowHeight = cache.measure(textStorage: storage, width: 100)
        let wideHeight = cache.measure(textStorage: storage, width: 600)
        XCTAssertLessThanOrEqual(wideHeight, narrowHeight, "A wider container needs equal-or-fewer rows.")
    }

    // MARK: - Lifecycle

    func testDismantle_removesMeasureLayoutManager() async {
        _ = cache.measure(textStorage: storage, width: 200)
        let beforeCount = storage.layoutManagers.count
        cache.dismantle()
        XCTAssertEqual(storage.layoutManagers.count, beforeCount - 1, "dismantle() must remove the measure LM from textStorage.")
    }

    func testRebind_removesPreviousAttachment() async {
        _ = cache.measure(textStorage: storage, width: 200)
        XCTAssertEqual(storage.layoutManagers.count, 1, "Cache attached its measure LM to storage.")

        let otherStorage = NSTextStorage(string: "X")
        _ = cache.measure(textStorage: otherStorage, width: 200)
        XCTAssertEqual(storage.layoutManagers.count, 0, "Rebinding must detach from the previous storage.")
        XCTAssertEqual(otherStorage.layoutManagers.count, 1, "Rebinding must attach to the new storage.")
    }
}
