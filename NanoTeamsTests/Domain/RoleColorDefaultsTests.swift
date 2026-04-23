import XCTest
@testable import NanoTeams

/// Tests for `RoleColorDefaults` — single source of truth for system-role
/// default background colors. Spot checks exist in `TeamRoleDefinitionTests`
/// but the full dictionary + hex-format invariants are not exercised.
///
/// Pinned behavior:
/// - Every built-in `Role` case (besides `.custom`) has an entry in
///   `backgroundHex`. Missing entries silently fall back to `defaultHex` —
///   we want that to be an explicit test failure, not a silent default.
/// - All stored hex values are well-formed `#RRGGBB` strings (7 chars,
///   hex digits only).
/// - `defaultHex` itself is well-formed.
/// - Fallback path: unknown role ID and nil both return `defaultHex`.
final class RoleColorDefaultsTests: XCTestCase {

    // MARK: - Hex format invariants

    private func assertValidHex(_ hex: String, role: String, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(hex.count, 7, "Role \(role): hex must be 7 chars (`#RRGGBB`)", file: file, line: line)
        XCTAssertEqual(hex.first, "#", "Role \(role): hex must start with `#`", file: file, line: line)
        let hexDigits = hex.dropFirst()
        let validDigits = Set("0123456789ABCDEFabcdef")
        for ch in hexDigits {
            XCTAssertTrue(validDigits.contains(ch),
                          "Role \(role): invalid hex digit `\(ch)` in `\(hex)`",
                          file: file, line: line)
        }
    }

    func testDefaultHex_isWellFormed() {
        assertValidHex(RoleColorDefaults.defaultHex, role: "defaultHex")
    }

    func testAllStoredHexValues_areWellFormed() {
        for (role, hex) in RoleColorDefaults.backgroundHex {
            assertValidHex(hex, role: role)
        }
    }

    // MARK: - Dictionary completeness

    /// Every built-in (non-`.custom`) Role must have an entry in
    /// `backgroundHex`. A missing entry would silently fall back to the
    /// generic blue, which would look wrong in the role-picker UI.
    func testAllBuiltInRoles_haveExplicitEntry() {
        for role in Role.builtInCases {
            let id = Role.builtInID(role)
            XCTAssertFalse(id.isEmpty,
                           "Built-in role \(role) has an empty builtInID — invariant broken upstream")
            XCTAssertNotNil(
                RoleColorDefaults.backgroundHex[id],
                "Built-in role `\(id)` has no default color — add it to `RoleColorDefaults.backgroundHex`"
            )
        }
    }

    // MARK: - Fallback semantics

    func testDefaultBackgroundHex_knownRole_returnsMappedValue() {
        XCTAssertEqual(
            RoleColorDefaults.defaultBackgroundHex(for: "supervisor"),
            RoleColorDefaults.backgroundHex["supervisor"]
        )
        XCTAssertEqual(
            RoleColorDefaults.defaultBackgroundHex(for: "softwareEngineer"),
            RoleColorDefaults.backgroundHex["softwareEngineer"]
        )
    }

    func testDefaultBackgroundHex_unknownRole_returnsDefaultHex() {
        XCTAssertEqual(
            RoleColorDefaults.defaultBackgroundHex(for: "__never_registered__"),
            RoleColorDefaults.defaultHex
        )
    }

    func testDefaultBackgroundHex_nilRole_returnsDefaultHex() {
        XCTAssertEqual(
            RoleColorDefaults.defaultBackgroundHex(for: nil),
            RoleColorDefaults.defaultHex
        )
    }

    func testDefaultBackgroundHex_emptyString_fallsBackToDefault() {
        // Empty is still a String (non-nil). The lookup fails → falls back.
        XCTAssertEqual(
            RoleColorDefaults.defaultBackgroundHex(for: ""),
            RoleColorDefaults.defaultHex
        )
    }

    // MARK: - Palette stability

    /// Pin the exact `defaultHex` value so inadvertent palette shifts in
    /// pull requests show up as a test failure, not a UI regression
    /// discovered in production.
    func testDefaultHex_isStableBlue() {
        XCTAssertEqual(RoleColorDefaults.defaultHex, "#5F87D9")
    }

    /// Pin a few anchor roles so a bulk palette rewrite has to deliberately
    /// update the assertions (review-gate against accidental changes).
    func testAnchorRoles_havePinnedColors() {
        XCTAssertEqual(RoleColorDefaults.backgroundHex["supervisor"], "#6D76E2")
        XCTAssertEqual(RoleColorDefaults.backgroundHex["softwareEngineer"], "#4FB985")
        XCTAssertEqual(RoleColorDefaults.backgroundHex["assistant"], "#56C999")
    }
}
