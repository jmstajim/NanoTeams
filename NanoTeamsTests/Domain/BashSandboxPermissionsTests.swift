import XCTest

@testable import NanoTeams

/// The four user-toggleable read/write grants behind Settings → Bash → Sandbox.
/// The defaults must reproduce the prior hardcoded profile, and Codable must
/// tolerate partial / legacy JSON by filling absent keys with the safe defaults.
final class BashSandboxPermissionsTests: XCTestCase {

    func testDefaults_reproducePriorProfileBehavior() {
        let p = BashSandboxPermissions()
        // Reads broad by default (the shell needs them); credential read blocked.
        XCTAssertTrue(p.workFolderRead)
        XCTAssertTrue(p.tempRead)
        XCTAssertTrue(p.everythingElseRead)
        XCTAssertFalse(p.credentialRead)
        // Writes confined to work + temp.
        XCTAssertTrue(p.workFolderWrite)
        XCTAssertTrue(p.tempWrite)
        XCTAssertFalse(p.everythingElseWrite)
        // Home inherits the system grant when unset: readable (broad), not writable.
        XCTAssertTrue(p.homeRead)
        XCTAssertFalse(p.homeWrite)
    }

    func testCodable_roundTrip() throws {
        let p = BashSandboxPermissions(
            workFolderWrite: false, tempWrite: true, credentialRead: true, everythingElseWrite: true)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(BashSandboxPermissions.self, from: data)
        XCTAssertEqual(p, decoded)
    }

    func testCodable_missingFieldsDecodeToSafeDefaults() throws {
        // A partial JSON (older shape / hand-rolled) fills absent keys with the
        // safe defaults rather than throwing.
        let json = Data(#"{"credentialRead":true}"#.utf8)
        let decoded = try JSONDecoder().decode(BashSandboxPermissions.self, from: json)
        XCTAssertTrue(decoded.credentialRead)
        XCTAssertTrue(decoded.workFolderWrite)
        XCTAssertTrue(decoded.tempWrite)
        XCTAssertFalse(decoded.everythingElseWrite)
        // Read fields absent from a legacy blob default to the broad-read behavior.
        XCTAssertTrue(decoded.workFolderRead)
        XCTAssertTrue(decoded.tempRead)
        XCTAssertTrue(decoded.everythingElseRead)
        // Home keys absent (pre-split blob) → inherit the system grant.
        XCTAssertTrue(decoded.homeRead)
        XCTAssertFalse(decoded.homeWrite)
    }

    func testHomeGrant_inheritsSystemGrantWhenUnset() {
        // An unset home toggle mirrors the system grant — so existing configs that
        // only set everythingElse keep their exact pre-split behavior.
        XCTAssertTrue(BashSandboxPermissions(everythingElseRead: true).homeRead)
        XCTAssertFalse(BashSandboxPermissions(everythingElseRead: false).homeRead)
        XCTAssertTrue(BashSandboxPermissions(everythingElseWrite: true).homeWrite)
        XCTAssertFalse(BashSandboxPermissions(everythingElseWrite: false).homeWrite)
        // An explicit home value overrides the inheritance.
        XCTAssertTrue(BashSandboxPermissions(homeRead: true, everythingElseRead: false).homeRead)
        XCTAssertFalse(BashSandboxPermissions(homeWrite: false, everythingElseWrite: true).homeWrite)
    }

    /// Back-compat: a pre-split blob (no home keys) must produce the SAME Seatbelt
    /// profile as the post-split config where home inherits the system grant.
    func testBackCompat_legacyJSON_yieldsIdenticalProfile() throws {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-backcompat").resolvingSymlinksInPath()

        // Empty blob → all defaults → identical to BashSandboxPermissions().
        let empty = try JSONDecoder().decode(BashSandboxPermissions.self, from: Data("{}".utf8))
        XCTAssertEqual(
            SeatbeltSandbox.profile(workFolderRoot: work, permissions: empty),
            SeatbeltSandbox.profile(workFolderRoot: work, permissions: BashSandboxPermissions()))

        // Legacy broad-write blob → home inherits the broad write/read.
        let legacy = try JSONDecoder().decode(
            BashSandboxPermissions.self,
            from: Data(#"{"everythingElseRead":true,"everythingElseWrite":true}"#.utf8))
        XCTAssertTrue(legacy.homeRead)
        XCTAssertTrue(legacy.homeWrite)
        XCTAssertEqual(
            SeatbeltSandbox.profile(workFolderRoot: work, permissions: legacy),
            SeatbeltSandbox.profile(
                workFolderRoot: work,
                permissions: BashSandboxPermissions(
                    homeRead: true, homeWrite: true, everythingElseRead: true, everythingElseWrite: true)))
    }

    func testDecoder_explicitHomeOverridesInheritance() throws {
        // The DECODER path (not just the memberwise init) must honor an explicit home
        // grant over the system inheritance: homeRead:true survives everythingElseRead:false.
        let json = Data(#"{"everythingElseRead":false,"homeRead":true}"#.utf8)
        let decoded = try JSONDecoder().decode(BashSandboxPermissions.self, from: json)
        XCTAssertTrue(decoded.homeRead, "explicit homeRead must not be overwritten by inheritance")
        XCTAssertFalse(decoded.everythingElseRead)
    }

    func testHashable_differsByOneField() {
        let a = BashSandboxPermissions()
        // `credentialRead` has no inheritance, so this flips exactly ONE field
        // (unlike `everythingElseWrite`, which also flips the inherited `homeWrite`).
        let b = BashSandboxPermissions(credentialRead: true)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 2, "two permissions differing in one field are distinct set members")
    }
}
