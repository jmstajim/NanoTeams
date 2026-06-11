import XCTest
@testable import NanoTeams

/// Pins `AutovisorTuning` — the per-folder numeric behaviour caps. Covers default
/// = constants, the construct/decode clamps (caps ≥ 1, stuck timings ≥ 30s), and
/// forward-compatible partial decode so an older settings.json never throws.
final class AutovisorTuningTests: XCTestCase {

    private let decoder = JSONCoderFactory.makeDateDecoder()
    private let encoder = JSONCoderFactory.makePersistenceEncoder()

    func testDefault_matchesConstants() {
        let t = AutovisorTuning.default
        XCTAssertEqual(t.maxConcurrentManagedTasks, AutovisorConstants.maxConcurrentManagedTasks)
        XCTAssertEqual(t.maxManagedTasksPerReview, AutovisorConstants.maxManagedTasksPerReview)
        XCTAssertEqual(t.stuckHangSeconds, AutovisorConstants.stuckHangSeconds)
        XCTAssertEqual(t.stuckLoopRecencySeconds, AutovisorConstants.stuckLoopRecencySeconds)
    }

    func testInit_clampsBelowFloor() {
        let t = AutovisorTuning(
            maxConcurrentManagedTasks: 0,
            maxManagedTasksPerReview: -3,
            stuckHangSeconds: 1,
            stuckLoopRecencySeconds: 0
        )
        XCTAssertEqual(t.maxConcurrentManagedTasks, 1, "concurrency cap floored at 1")
        XCTAssertEqual(t.maxManagedTasksPerReview, 1, "per-review cap floored at 1")
        XCTAssertEqual(t.stuckHangSeconds, 30, "hang threshold floored at 30s")
        XCTAssertEqual(t.stuckLoopRecencySeconds, 30, "loop recency floored at 30s")
    }

    func testInit_keepsValidValues() {
        let t = AutovisorTuning(
            maxConcurrentManagedTasks: 25,
            maxManagedTasksPerReview: 8,
            stuckHangSeconds: 600,
            stuckLoopRecencySeconds: 300
        )
        XCTAssertEqual(t.maxConcurrentManagedTasks, 25)
        XCTAssertEqual(t.maxManagedTasksPerReview, 8)
        XCTAssertEqual(t.stuckHangSeconds, 600)
        XCTAssertEqual(t.stuckLoopRecencySeconds, 300)
    }

    func testDecode_emptyObject_isDefault() throws {
        let t = try decoder.decode(AutovisorTuning.self, from: Data("{}".utf8))
        XCTAssertEqual(t, .default, "a missing block decodes to the default tuning")
    }

    func testDecode_partial_fillsDefaults() throws {
        let json = #"{ "maxConcurrentManagedTasks": 3 }"#
        let t = try decoder.decode(AutovisorTuning.self, from: Data(json.utf8))
        XCTAssertEqual(t.maxConcurrentManagedTasks, 3, "present field decoded")
        XCTAssertEqual(t.maxManagedTasksPerReview, AutovisorConstants.maxManagedTasksPerReview,
                       "absent field defaults")
        XCTAssertEqual(t.stuckHangSeconds, AutovisorConstants.stuckHangSeconds)
    }

    func testDecode_clampsOutOfRangeValues() throws {
        // A hand-edited settings.json with a wake-storm-y zero cap must clamp on read.
        let json = #"{ "maxConcurrentManagedTasks": 0, "stuckHangSeconds": 2 }"#
        let t = try decoder.decode(AutovisorTuning.self, from: Data(json.utf8))
        XCTAssertEqual(t.maxConcurrentManagedTasks, 1)
        XCTAssertEqual(t.stuckHangSeconds, 30)
    }

    func testClamped_reAppliesFloorsAfterDirectMutation() {
        // The settings editor mutates fields via SwiftUI `$tuning.field` bindings,
        // which bypass `init`'s clamps. `clamped()` (called at the persistence
        // boundary) must re-floor an out-of-range value, and pass a valid one through.
        var t = AutovisorTuning.default
        t.maxConcurrentManagedTasks = 0
        t.stuckHangSeconds = 5
        let clamped = t.clamped()
        XCTAssertEqual(clamped.maxConcurrentManagedTasks, 1, "below-floor cap re-floored")
        XCTAssertEqual(clamped.stuckHangSeconds, 30, "below-floor timing re-floored")

        var valid = AutovisorTuning.default
        valid.maxManagedTasksPerReview = 8
        XCTAssertEqual(valid.clamped().maxManagedTasksPerReview, 8, "valid value passes through")
    }

    func testRoundTrip_preservesValues() throws {
        let original = AutovisorTuning(
            maxConcurrentManagedTasks: 4,
            maxManagedTasksPerReview: 2,
            stuckHangSeconds: 300,
            stuckLoopRecencySeconds: 90
        )
        let data = try encoder.encode(original)
        let roundTrip = try decoder.decode(AutovisorTuning.self, from: data)
        XCTAssertEqual(roundTrip, original)

        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"maxManagedTasksPerReview\""))
        XCTAssertTrue(json.contains("\"stuckHangSeconds\""))
    }
}
