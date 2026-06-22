import XCTest
@testable import NanoTeams

/// Pins `AutovisorActivation.clamped()` — the persistence-boundary re-floor of the
/// sleep-timer duration. The Settings editor mutates the fields via SwiftUI bindings,
/// bypassing the `init` clamp, so `clamped()` (called by `updateAutovisorActivation`)
/// is the only thing re-flooring an out-of-range value before it reaches
/// `settings.json`. Mirrors the sibling
/// `AutovisorTuningTests.testClamped_reAppliesFloorsAfterDirectMutation`.
final class AutovisorActivationTests: XCTestCase {

    func testClamped_leavesTriggerBoolsUntouched() {
        var a = AutovisorActivation.default
        a.onTaskNeedsSupervisor = false
        a.onTaskCreated = true
        let c = a.clamped()
        XCTAssertFalse(c.onTaskNeedsSupervisor)
        XCTAssertTrue(c.onTaskCreated)
    }

    // MARK: - Auto-off sleep timer

    func testAutoDisable_defaultsOnWithDefaultDuration() {
        let a = AutovisorActivation.default
        XCTAssertTrue(a.autoDisableEnabled, "sleep timer is ON by default")
        XCTAssertEqual(a.autoDisableAfterSeconds, AutovisorConstants.defaultAutoDisableAfterSeconds)
        XCTAssertEqual(a.effectiveAutoDisableAfterSeconds, AutovisorConstants.defaultAutoDisableAfterSeconds)
    }

    func testClampAutoDisable_floorsAtMinimum() {
        XCTAssertEqual(AutovisorActivation.clampAutoDisable(5),
                       AutovisorConstants.minAutoDisableSeconds,
                       "sub-minute duration floored to the tick resolution")
        XCTAssertEqual(AutovisorActivation.clampAutoDisable(7200), 7200,
                       "valid duration passes through")
        XCTAssertEqual(AutovisorActivation(autoDisableAfterSeconds: 5).autoDisableAfterSeconds,
                       AutovisorConstants.minAutoDisableSeconds,
                       "init applies the floor")
    }

    func testClampAutoDisable_capsAtCeiling_includingDecode() throws {
        XCTAssertEqual(AutovisorActivation.clampAutoDisable(.greatestFiniteMagnitude),
                       AutovisorConstants.maxAutoDisableSeconds,
                       "huge duration capped at the steppers' ceiling")
        // A hand-edited settings.json with a non-Int64-representable Double would
        // otherwise trap the editor's Int(_:) seconds→h/m conversion on open.
        let edited = Data(#"{"autoDisableAfterSeconds": 1e19}"#.utf8)
        let a = try JSONDecoder().decode(AutovisorActivation.self, from: edited)
        XCTAssertEqual(a.autoDisableAfterSeconds, AutovisorConstants.maxAutoDisableSeconds,
                       "decode funnel applies the ceiling")
    }

    /// `clamped()` enumerates every field through `init(...)` — a field added to
    /// the struct but forgotten there would silently reset to its default on EVERY
    /// Settings persist. Identity over a fully-non-default, in-range instance
    /// catches that omission.
    func testClamped_isIdentityForInRangeValues() {
        let a = AutovisorActivation(
            onTaskNeedsSupervisor: false,
            onTaskFailed: false,
            onTaskCompleted: false,
            onTaskCreated: true,
            onTaskStuck: false,
            autoDisableEnabled: false,
            autoDisableAfterSeconds: 7200
        )
        XCTAssertEqual(a.clamped(), a, "in-range values must round-trip clamped() unchanged")
    }

    func testClamped_reFloorsAutoDisableAfterDirectMutation() {
        var a = AutovisorActivation.default
        a.autoDisableAfterSeconds = 1   // direct binding-style mutation bypasses the init clamp
        a.autoDisableEnabled = false
        let c = a.clamped()
        XCTAssertEqual(c.autoDisableAfterSeconds, AutovisorConstants.minAutoDisableSeconds,
                       "below-floor duration re-floored on persist")
        XCTAssertFalse(c.autoDisableEnabled, "the toggle passes through untouched")
        XCTAssertNil(c.effectiveAutoDisableAfterSeconds, "toggle off → no effective duration")
    }

    func testDecode_legacyJSON_autoDisableDefaultsOn() throws {
        // A settings.json written before the sleep timer existed has neither key.
        let legacy = Data(#"{"onTaskFailed": false}"#.utf8)
        let a = try JSONDecoder().decode(AutovisorActivation.self, from: legacy)
        XCTAssertFalse(a.onTaskFailed, "present legacy field decoded")
        XCTAssertTrue(a.autoDisableEnabled, "missing key → on by default")
        XCTAssertEqual(a.autoDisableAfterSeconds, AutovisorConstants.defaultAutoDisableAfterSeconds)
    }

    func testDecode_belowFloorDuration_clampedToMinimum() throws {
        // A hand-edited settings.json can carry any value — the decode funnel
        // must re-floor it so a ~1s timer can't arm.
        let edited = Data(#"{"autoDisableAfterSeconds": 1}"#.utf8)
        let a = try JSONDecoder().decode(AutovisorActivation.self, from: edited)
        XCTAssertEqual(a.autoDisableAfterSeconds, AutovisorConstants.minAutoDisableSeconds,
                       "below-floor duration re-floored at decode")
    }

    func testCodableRoundTrip_preservesExplicitOff() throws {
        // The "off" choice must survive re-encode — the reason the toggle is an
        // explicit Bool rather than an optional duration (encodeIfPresent would
        // drop a nil and decode would resurrect the on-by-default).
        var a = AutovisorActivation.default
        a.autoDisableEnabled = false
        a.autoDisableAfterSeconds = 7200
        let decoded = try JSONDecoder().decode(
            AutovisorActivation.self, from: JSONEncoder().encode(a)
        )
        XCTAssertFalse(decoded.autoDisableEnabled, "explicit off survives the round-trip")
        XCTAssertEqual(decoded.autoDisableAfterSeconds, 7200)
    }
}
