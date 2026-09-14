import XCTest

@testable import NanoTeams

/// The one rule that turns a preference and a provider's answer into a mode, plus the
/// stability of the values that are persisted (`StepExecution.toolCallingMode`, the
/// UserDefaults preference, the headless config).
final class ToolCallingModeTests: XCTestCase {

    // MARK: - Resolver truth table

    func testAuto_followsTheProvidersAnswer() {
        XCTAssertEqual(ToolCallingModeResolver.resolve(preference: .auto, providerSupport: true), .native)
        XCTAssertEqual(ToolCallingModeResolver.resolve(preference: .auto, providerSupport: false), .promptTaught)
    }

    /// The fail-closed arm, and the reason the resolver exists as a function rather than an
    /// `if`: an undeterminable answer must land on the protocol the app controls, never on a
    /// grammar-forced request to a model that may never have learned the syntax.
    func testAuto_undeterminable_isPromptTaught() {
        XCTAssertEqual(ToolCallingModeResolver.resolve(preference: .auto, providerSupport: nil), .promptTaught)
    }

    func testExplicitPreference_ignoresTheProvider() {
        for support: Bool? in [true, false, nil] {
            XCTAssertEqual(ToolCallingModeResolver.resolve(preference: .native, providerSupport: support), .native)
            XCTAssertEqual(ToolCallingModeResolver.resolve(preference: .promptTaught, providerSupport: support), .promptTaught)
        }
    }

    // MARK: - Persisted spellings

    /// These strings are on disk in `task.json` and UserDefaults; a rename is a migration.
    func testRawValues_areStable() {
        XCTAssertEqual(ToolCallingMode.native.rawValue, "native")
        XCTAssertEqual(ToolCallingMode.promptTaught.rawValue, "promptTaught")
        XCTAssertEqual(ToolCallingPreference.allCases.map(\.rawValue), ["auto", "native", "promptTaught"])
    }

    func testMode_roundTripsThroughJSON() throws {
        for mode in ToolCallingMode.allCases {
            let data = try JSONEncoder().encode([mode])
            XCTAssertEqual(try JSONDecoder().decode([ToolCallingMode].self, from: data), [mode])
        }
    }

    func testEveryPreference_hasADisplayNameAndAnExplanation() {
        for preference in ToolCallingPreference.allCases {
            XCTAssertFalse(preference.displayName.isEmpty, "\(preference) has no display name")
            XCTAssertFalse(preference.explanation.isEmpty, "\(preference) has no explanation")
            XCTAssertNotEqual(preference.displayName, preference.rawValue,
                              "\(preference) is showing its rawValue, not a written label")
        }
    }


    /// The picker identifies a preference by its raw value — the same string the store persists.
    func testPreference_identifiableByRawValue() {
        for preference in ToolCallingPreference.allCases {
            XCTAssertEqual(preference.id, preference.rawValue)
        }
    }
}
