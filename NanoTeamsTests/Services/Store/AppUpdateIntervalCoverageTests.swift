import XCTest

@testable import NanoTeams

/// Coverage wave 1 — `AppUpdateCheckInterval`, which nothing had ever asked a question of
/// despite being a persisted, user-selected setting.
///
/// It is 12 of `StoreConfiguration.swift`'s 12 uncovered lines. The interesting property is not
/// the strings but `seconds`: `nil` means "no background checks", and the difference between
/// `nil` and `0` at that call site is the difference between never checking and checking on
/// every tick.
final class AppUpdateIntervalCoverageTests: XCTestCase {

    /// RED: return `0` instead of `nil` from `.never` → this fails. That mutation is the one
    /// that matters: a 0-second interval is not "disabled", it is "check constantly".
    func testNeverIsTheOnlyCaseWithoutAnInterval() {
        XCTAssertNil(AppUpdateCheckInterval.never.seconds,
                     "nil is what disables the background check; 0 would mean 'every tick'")

        for interval in AppUpdateCheckInterval.allCases where interval != .never {
            guard let seconds = interval.seconds else {
                return XCTFail("\(interval) has no interval, so background checks would never fire")
            }
            XCTAssertGreaterThan(seconds, 0, "\(interval) must be a positive duration")
        }
    }

    /// RED: swap the `.weekly` and `.biweekly` values → the ordering assertion fails.
    func testIntervalsIncreaseWithTheirNames() {
        let ordered: [AppUpdateCheckInterval] = [.daily, .weekly, .biweekly, .monthly]
        let seconds = ordered.compactMap(\.seconds)
        XCTAssertEqual(seconds.count, ordered.count)
        XCTAssertEqual(seconds, seconds.sorted(),
                       "a cadence picker whose options are not monotonic is a mislabelled control: "
                           + "\(zip(ordered, seconds).map { "\($0)=\($1)" })")
        XCTAssertEqual(AppUpdateCheckInterval.daily.seconds, 86_400)
        XCTAssertEqual(AppUpdateCheckInterval.weekly.seconds, 7 * 86_400)
    }

    /// `id` is the `Identifiable` witness a SwiftUI picker uses, and `displayName` is what it
    /// shows. A duplicate id collapses two options into one row (CLAUDE.md #22); a duplicate
    /// label makes two rows indistinguishable.
    ///
    /// RED: return a constant from `displayName` → the distinctness assertion fails.
    func testEveryCaseIsDistinctlyIdentifiedAndLabelled() {
        let all = AppUpdateCheckInterval.allCases
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "a duplicate id collapses picker rows")
        XCTAssertEqual(Set(all.map(\.displayName)).count, all.count,
                       "two options share a label: \(all.map(\.displayName))")

        for interval in all {
            XCTAssertEqual(interval.id, interval.rawValue,
                           "the picker id and the persisted raw value must be the same string")
            XCTAssertFalse(interval.displayName.isEmpty)
        }
    }

    /// The raw values are a persistence surface — they are what `StoreConfiguration` writes into
    /// UserDefaults — so renaming a case silently resets the user's choice to the default.
    ///
    /// RED: rename any case → this fails, which is the intended cost of a persistence break.
    func testRawValuesAreFrozen() throws {
        XCTAssertEqual(Set(AppUpdateCheckInterval.allCases.map(\.rawValue)),
                       ["daily", "weekly", "biweekly", "monthly", "never"],
                       "these raw values are persisted; renaming one silently resets every "
                           + "existing user's update cadence to the default")

        // …and they round-trip, since that is how the setting is actually stored.
        for interval in AppUpdateCheckInterval.allCases {
            let data = try JSONEncoder().encode(interval)
            XCTAssertEqual(try JSONDecoder().decode(AppUpdateCheckInterval.self, from: data), interval)
        }
    }
}
