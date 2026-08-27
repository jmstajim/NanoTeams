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

    // MARK: - withWritesDisabled (the planning phase's kernel guarantee)

    /// Every field of the narrowed value, over ALL 2^8 configurations of the eight `Bool`
    /// grants. Two properties in one sweep: writes are off unconditionally, and nothing else
    /// moved — so the transform is MONOTONE (no field can go `false → true`) and the planning
    /// phase provably narrows the user's own settings rather than substituting its own.
    ///
    /// The sweep matters more than a spot check: a per-field regression that only shows up when
    /// some OTHER field is set (e.g. clearing `credentialRead` only when `everythingElseRead`
    /// is off) survives any hand-picked fixture.
    ///
    /// RED: drop `narrowed.tempWrite = false` → fires on every configuration with temp on.
    /// RED: add `narrowed.credentialRead = true` → fires wherever the source had it off.
    func testWithWritesDisabled_clearsEveryWriteScopeAndTouchesNothingElse() {
        for bits in 0..<256 {
            func bit(_ i: Int) -> Bool { bits & (1 << i) != 0 }
            let base = BashSandboxPermissions(
                workFolderRead: bit(0), workFolderWrite: bit(1),
                tempRead: bit(2), tempWrite: bit(3),
                credentialRead: bit(4), homeRead: bit(5), homeWrite: bit(6),
                everythingElseRead: bit(7), everythingElseWrite: bit(1) && bit(3))
            let narrowed = base.withWritesDisabled()
            let ctx = "bits=\(bits)"

            XCTAssertFalse(narrowed.workFolderWrite, ctx)
            XCTAssertFalse(narrowed.tempWrite, ctx)
            XCTAssertFalse(narrowed.homeWrite, ctx)
            XCTAssertFalse(narrowed.everythingElseWrite, ctx)

            XCTAssertEqual(narrowed.workFolderRead, base.workFolderRead, ctx)
            XCTAssertEqual(narrowed.tempRead, base.tempRead, ctx)
            XCTAssertEqual(narrowed.homeRead, base.homeRead, ctx)
            XCTAssertEqual(narrowed.everythingElseRead, base.everythingElseRead, ctx)
            XCTAssertEqual(narrowed.credentialRead, base.credentialRead, ctx)
        }
    }

    /// The guarantee, read off the PROFILE rather than off the struct: with no write scope
    /// granted, `SeatbeltSandbox` emits a write clause carrying only dev-node literals, so
    /// `(deny default)` answers every real filesystem write. That is what makes "bash cannot
    /// mutate work-folder source during planning" checkable instead of argued.
    ///
    /// `tempWrite` goes off with the rest because temp writes are writes and the contract is
    /// that none survive. The rationale recorded here until 2026-08-25 was a defect instead —
    /// the narrow-write branch emitted no work-folder deny, so a temp grant covered a project
    /// under `$TMPDIR` — and that hole is now closed by `workCoveredByTemp` in
    /// `SeatbeltSandbox`, pinned by `SeatbeltCanonicalPathCoverageTests`. The fixture below
    /// still sits under `NSTemporaryDirectory()`, which after the fix is the interesting
    /// layout rather than the one to avoid.
    ///
    /// RED: restore `tempWrite` in `withWritesDisabled()` → `(subpath` reappears.
    func testWithWritesDisabled_profileGrantsNoWriteSubpathAtAll() {
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("nanoteams-planning-profile"),
            permissions: BashSandboxPermissions().withWritesDisabled())

        // Slice the write ALLOW clause only: the credential write-DENY further down legitimately
        // carries `(subpath …)`, so a whole-profile search would always find one.
        guard let start = profile.range(of: "(allow file-write*"),
              let end = profile.range(of: #"(regex #"^/dev/ttys[0-9]+$"))"#,
                                      range: start.upperBound..<profile.endIndex)
        else { return XCTFail("no write clause in:\n\(profile)") }
        let writeClause = String(profile[start.lowerBound..<end.upperBound])

        XCTAssertFalse(writeClause.contains("(subpath "),
                       "a write subpath survived the narrowing:\n\(writeClause)")
        XCTAssertTrue(writeClause.contains("/dev/null"),
                      "dev nodes must stay writable — pipes and 2>/dev/null depend on them")
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
