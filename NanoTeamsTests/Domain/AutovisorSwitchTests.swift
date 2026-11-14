import XCTest
@testable import NanoTeams

/// `AutovisorSwitch` — what last switched a folder's Autovisor on or off — as settings store it
/// and as `folder_status.readiness` reads it back.
final class AutovisorSwitchTests: XCTestCase {

    private let switchedAt = Date(timeIntervalSince1970: 1_762_649_600)

    func testSettings_roundTripTheSwitch_andReadAnUnknownCauseAsNone() throws {
        var settings = ProjectSettings()
        settings.autovisorLastSwitch = AutovisorSwitch(at: switchedAt, by: .autoOff)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ProjectSettings.self, from: data).autovisorLastSwitch, settings.autovisorLastSwitch)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["autovisorLastSwitch"] = ["at": 0, "by": "solar_flare"]
        let future = try JSONDecoder().decode(ProjectSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(future.autovisorLastSwitch)

        object.removeValue(forKey: "autovisorLastSwitch")
        XCTAssertNil(try JSONDecoder().decode(ProjectSettings.self, from: JSONSerialization.data(withJSONObject: object)).autovisorLastSwitch)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(ProjectSettings()), as: UTF8.self).contains("autovisorLastSwitch"),
                       "no switch, no key")
    }

    func testCauses_haveTheirWireNames() {
        XCTAssertEqual(AutovisorSwitch.Cause.allCases.map(\.rawValue), ["person", "auto_off", "deleted"])
    }

    /// The switch is reported while it decides the state — on and ready, or off — and nowhere else.
    func testReadiness_carriesTheSwitch_onlyWhileItDecidesTheState() {
        let lastSwitch = AutovisorSwitch(at: switchedAt, by: .person)
        func readiness(enabled: Bool, driver: AutovisorDriver = .externalAgent, transition: Bool = false, folder: Bool = true)
            -> ExternalAutovisorReadiness {
            ExternalAutovisorReadiness.evaluate(
                hasRealWorkFolder: folder, isFolderTransitionInProgress: transition, isFolderInUseByAnotherProcess: false,
                autovisorEnabled: enabled, driver: driver, lastSwitch: lastSwitch)
        }
        let off = readiness(enabled: false)
        XCTAssertEqual(off.state, .autovisorDisabled)
        XCTAssertEqual(off.changedBy, "person")
        XCTAssertEqual(off.since, JSONCoderFactory.iso8601Formatter.string(from: switchedAt))
        XCTAssertEqual(readiness(enabled: true).changedBy, "person")
        for other in [readiness(enabled: true, driver: .builtInModel), readiness(enabled: true, transition: true),
                      readiness(enabled: true, folder: false)] {
            XCTAssertNil(other.since, "\(other.state)")
            XCTAssertNil(other.changedBy, "\(other.state)")
        }
        let unswitched = ExternalAutovisorReadiness.evaluate(
            hasRealWorkFolder: true, isFolderTransitionInProgress: false, isFolderInUseByAnotherProcess: false,
            autovisorEnabled: false, driver: .externalAgent)
        XCTAssertNil(unswitched.since)
    }
}
