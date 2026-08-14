import XCTest

@testable import NanoTeams

final class SeatbeltSandboxTests: XCTestCase {

    /// The kernel's own answer for a path, which is what Seatbelt matches a `(subpath …)`
    /// against. Used as the ORACLE for the two temp-dir assertions below rather than
    /// re-deriving production's rule: both used to compute the expected value with
    /// `resolvingSymlinksInPath()`, i.e. they mirrored the very bug they were supposed to
    /// catch. See `SeatbeltCanonicalPathCoverageTests` for the measurements.
    private func kernelPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func testProfile_allowsWriteToWorkFolderSubpath() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-sbtest-work").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(workFolderRoot: work)
        XCTAssertTrue(profile.contains("(deny default)"))
        XCTAssertTrue(profile.contains("(allow file-write*"))
        XCTAssertTrue(profile.contains(work.path), "profile must allow writes under the canonical work folder path")
    }

    func testProfile_deniesCredentialReads() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-sbtest-work")
        let profile = SeatbeltSandbox.profile(workFolderRoot: work)
        XCTAssertTrue(profile.contains("(deny file-read*"))
        XCTAssertTrue(profile.contains(".ssh"))
        XCTAssertTrue(profile.contains("Keychains"))
    }

    func testProfile_defaultReadsAreBroad() {
        let profile = SeatbeltSandbox.profile(workFolderRoot: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertTrue(profile.contains("(allow file-read*)"), "default reads must be broad")
    }

    func testProfile_broadReadWithWorkReadOff_addsReadDeny() {
        // credentialRead on isolates the deny to the work-read carve-out (not creds).
        let perms = BashSandboxPermissions(workFolderRead: false, credentialRead: true)
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: URL(fileURLWithPath: "/tmp/nanoteams-sbtest-wf"), permissions: perms)
        XCTAssertTrue(profile.contains("(allow file-read*)"), "still broad reads")
        XCTAssertTrue(profile.contains("(deny file-read*"),
                      "turning work-folder read off must carve it out of the broad read")
    }

    func testProfile_everythingElseReadOff_narrowsReadsToScopes() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-sbtest-narrow").resolvingSymlinksInPath()
        let perms = BashSandboxPermissions(everythingElseRead: false) // work/temp read still on
        let profile = SeatbeltSandbox.profile(workFolderRoot: work, permissions: perms)
        XCTAssertFalse(profile.contains("(allow file-read*)"),
                       "reads must NOT be broad when everything-else read is off")
        XCTAssertTrue(profile.contains("(allow file-read*\n"),
                      "narrow read allow lists the enabled scopes")
        XCTAssertTrue(profile.contains(work.path), "work-folder read stays allowed in narrow mode")
    }

    func testProfile_allReadsOff_emitsNoReadAllow() {
        let perms = BashSandboxPermissions(
            workFolderRead: false, tempRead: false, credentialRead: false, everythingElseRead: false)
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: URL(fileURLWithPath: "/tmp/x"), permissions: perms)
        XCTAssertFalse(profile.contains("(allow file-read*"),
                       "no read-allow clause when every read scope is off (deny-default blocks reads)")
    }

    func testProfile_canonicalizesSymlinkedRoot() throws {
        // The profile must embed the RESOLVED real path so Seatbelt's real-path
        // matching doesn't escape the allow. Drive it with a REAL symlinked work
        // folder: user-created symlinks are the case `resolvingSymlinksInPath()` DOES
        // traverse, which is why this test passed while the well-known `/tmp` and
        // `/var` symlinks — left in short form by that same resolver — silently escaped
        // both the allow-list and the denies. That parenthetical used to read as a test
        // inconvenience; it was the defect. `SeatbeltCanonicalPathCoverageTests` covers
        // the root-level symlinks and `canonical(_:)` now uses `realpath(3)`. The old
        // assertion here used `|| "/tmp/x"`, a substring of "/private/tmp/x", and so
        // passed even if canonicalization regressed.
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-canon-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        let resolvedReal = kernelPath(real.standardizedFileURL.path)
        let profile = SeatbeltSandbox.profile(workFolderRoot: link)
        XCTAssertTrue(
            profile.contains("(subpath \"\(resolvedReal)\")"),
            "profile must embed the resolved symlink target, not the link path")
        XCTAssertFalse(
            profile.contains("(subpath \"\(link.path)\")"),
            "profile must NOT embed the unresolved symlink path")
    }

    func testWrap_buildsSandboxExecInvocation() {
        let (exe, args) = SeatbeltSandbox.wrap(profile: "(version 1)", shell: "/bin/zsh", command: "ls")
        XCTAssertEqual(exe, BashConstants.sandboxExecPath)
        XCTAssertEqual(args, ["-p", "(version 1)", "/bin/zsh", "-lc", "ls"])
    }

    func testProfile_regexLiteralsHaveNoTrailingHash() {
        // Regression: `#"...$"#` (a Swift raw-string trailing `#`, which is literal
        // text inside the `"""` profile) is INVALID SBPL — sandbox-exec rejects it
        // with "undefined sharp expression", breaking every sandboxed command. The
        // valid SBPL regex literal is `#"..."` with NO trailing `#`.
        let profile = SeatbeltSandbox.profile(workFolderRoot: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertTrue(profile.contains("(regex #\""), "profile should use SBPL regex literals")
        // The malformed form `(regex #"...$"#)` produces the exact token `"#)` — a
        // quoted literal closed immediately by `#)`. No subpath/literal can produce
        // that sequence, so this won't false-trip on a path containing '#'.
        XCTAssertFalse(profile.contains("\"#)"), "SBPL regex literal must not carry a trailing '#'")
    }

    /// Gold-standard regression for the trailing-`#` bug: the generated profile
    /// must actually compile under the real `sandbox-exec`. (The buggy profile
    /// exited 65 with "undefined sharp expression".)
    func testProfile_compilesAndRunsUnderSandboxExec() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-sbcompile-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let profile = SeatbeltSandbox.profile(workFolderRoot: work)
        let (exe, args) = SeatbeltSandbox.wrap(profile: profile, shell: "/bin/zsh", command: "echo SBX_OK")
        let result = try ProcessRunner.run(
            executable: exe, arguments: args, currentDirectory: work, timeout: 20)
        XCTAssertEqual(result.exitCode, 0, "profile must compile + run; stderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("SBX_OK"))
    }

    /// The confinement guarantee: writes land inside the work folder, are denied
    /// outside it. Uses home-dir-based paths because the profile intentionally
    /// also allows the temp dirs (so a /var/folders sibling wouldn't be "outside").
    func testProfile_confinesWritesToWorkFolder() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let token = UUID().uuidString
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let work = home.appendingPathComponent(".nanoteams-sbtest-work-\(token)")
        let outside = home.appendingPathComponent(".nanoteams-sbtest-outside-\(token)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: outside)
        }

        let profile = SeatbeltSandbox.profile(workFolderRoot: work)
        func run(_ command: String) throws -> ProcessRunner.Result {
            let (exe, args) = SeatbeltSandbox.wrap(profile: profile, shell: "/bin/zsh", command: command)
            return try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: work, timeout: 20)
        }

        let inside = try run("echo x > inside.txt && echo INSIDE_OK")
        XCTAssertTrue(inside.stdout.contains("INSIDE_OK"), "write inside the work folder must succeed; stderr=\(inside.stderr)")

        let outsideFile = outside.appendingPathComponent("nope.txt")
        let blocked = try run("echo x > \(outsideFile.path)")
        XCTAssertNotEqual(blocked.exitCode, 0, "write outside the work folder must be denied")
        XCTAssertFalse(fm.fileExists(atPath: outsideFile.path))
    }

    // MARK: - Per-folder permissions

    func testProfile_workFolderWriteOff_omitsWorkSubpathButKeepsTemp() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-perm-nowork").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(workFolderWrite: false))
        XCTAssertFalse(
            profile.contains("(subpath \"\(work.path)\")"),
            "work folder must NOT be writable when its write grant is off")
        // Assert the exact temp GRANT clause, not a bare `/private/tmp` substring — a
        // work folder that canonicalizes under /private/tmp would otherwise collide.
        XCTAssertTrue(profile.contains("(subpath \"/private/tmp\")"), "temp writes remain by default")
    }

    func testProfile_tempWriteOff_omitsTempSubpathsButKeepsWork() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-perm-notemp").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(tempWrite: false))
        XCTAssertFalse(profile.contains("(subpath \"/private/tmp\")"), "temp dirs must NOT be writable when temp write is off")
        XCTAssertTrue(profile.contains("(subpath \"\(work.path)\")"), "work folder remains writable")
    }

    func testProfile_credentialReadAllowed_omitsReadDeny() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-perm-credread")
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(credentialRead: true))
        XCTAssertFalse(
            profile.contains("(deny file-read*"),
            "the credential read-deny must be dropped when credential reads are allowed")
        XCTAssertFalse(profile.contains(".ssh"))
    }

    func testProfile_everythingElseWrite_isBroadAndStillDeniesCredentialWrites() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-perm-broad")
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(everythingElseWrite: true))
        XCTAssertTrue(profile.contains("(subpath \"/\")"), "broad write must allow the whole filesystem")
        XCTAssertTrue(
            profile.contains("(deny file-write*"),
            "credential writes must stay denied even under broad write")
        XCTAssertTrue(profile.contains(".ssh"))
    }

    func testProfile_broadWriteWithWorkOff_deniesWorkPath() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-perm-broadnowork").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(workFolderWrite: false, everythingElseWrite: true))
        XCTAssertTrue(profile.contains("(subpath \"/\")"), "broad write allows the whole filesystem")
        // The work path must be RE-DENIED so the disabled toggle still means something.
        XCTAssertTrue(
            profile.contains("(deny file-write*"),
            "a disabled inner scope must be denied even under broad write")
        XCTAssertTrue(
            profile.contains("(subpath \"\(work.path)\")"),
            "the work path must appear in the write-deny block")
    }

    /// Behavioral: broad write ON but work-folder write OFF → a write to the work
    /// folder is denied while a write OUTSIDE it succeeds. Proves the per-scope
    /// toggle is honored even under the broad escape hatch.
    func testProfile_broadWriteHonorsWorkFolderToggle_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let token = UUID().uuidString
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let work = home.appendingPathComponent(".nanoteams-sbtest-broadnowork-\(token)")
        let outside = home.appendingPathComponent(".nanoteams-sbtest-broadout-\(token)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work); try? fm.removeItem(at: outside) }

        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(workFolderWrite: false, everythingElseWrite: true))
        func run(_ command: String) throws -> ProcessRunner.Result {
            let (exe, args) = SeatbeltSandbox.wrap(profile: profile, shell: "/bin/zsh", command: command)
            return try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: work, timeout: 20)
        }

        let blockedInside = try run("echo x > inside.txt")
        XCTAssertNotEqual(blockedInside.exitCode, 0, "work-folder write must be denied despite broad write")
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("inside.txt").path))

        let outFile = outside.appendingPathComponent("ok.txt")
        let allowedOutside = try run("echo OUT_OK > \(outFile.path) && echo DONE")
        XCTAssertTrue(allowedOutside.stdout.contains("DONE"), "broad write must allow an outside write; stderr=\(allowedOutside.stderr)")
        XCTAssertTrue(fm.fileExists(atPath: outFile.path))
    }

    /// Every permission variant must still compile + run under the real
    /// `sandbox-exec` — a malformed conditional clause would exit 65.
    func testProfile_allPermissionVariants_compileUnderSandboxExec() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-permcompile-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let variants: [BashSandboxPermissions] = [
            BashSandboxPermissions(),
            BashSandboxPermissions(workFolderWrite: false),
            BashSandboxPermissions(tempWrite: false),
            BashSandboxPermissions(workFolderWrite: false, tempWrite: false),
            BashSandboxPermissions(credentialRead: true),
            BashSandboxPermissions(everythingElseWrite: true),
            BashSandboxPermissions(
                workFolderWrite: false, tempWrite: false, credentialRead: true, everythingElseWrite: true),
            // Home-scope variants — exercise the home deny / re-allow / carve clauses
            // live. Narrow SYSTEM reads are deliberately NOT run here: denying system
            // reads stops the login shell from loading at all (a documented read
            // footgun, not a profile bug), so that profile's structure is pinned by
            // the static `testProfile_systemReadOff_homeReadOn_*` test instead.
            BashSandboxPermissions(homeWrite: true, everythingElseWrite: false),
            BashSandboxPermissions(homeRead: false, everythingElseRead: true),
            BashSandboxPermissions(homeWrite: false, everythingElseWrite: true),
            BashSandboxPermissions(
                workFolderWrite: false, homeWrite: true, everythingElseWrite: false),
            BashSandboxPermissions(
                workFolderRead: false, homeRead: false, homeWrite: true,
                everythingElseRead: true, everythingElseWrite: true),
        ]
        for perms in variants {
            let profile = SeatbeltSandbox.profile(workFolderRoot: work, permissions: perms)
            let (exe, args) = SeatbeltSandbox.wrap(profile: profile, shell: "/bin/zsh", command: "echo SBX_OK")
            let result = try ProcessRunner.run(
                executable: exe, arguments: args, currentDirectory: work, timeout: 20)
            XCTAssertEqual(result.exitCode, 0, "variant \(perms) must compile + run; stderr=\(result.stderr)")
            XCTAssertTrue(result.stdout.contains("SBX_OK"))
        }
    }

    /// Behavioral inverse of `testProfile_confinesWritesToWorkFolder`: with the
    /// work-folder write grant OFF, a write INSIDE the work folder is denied.
    /// Uses a home-based work folder so the temp-dir allow (still on by default)
    /// doesn't cover it.
    func testProfile_workFolderWriteOff_blocksInsideWrite() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let token = UUID().uuidString
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let work = home.appendingPathComponent(".nanoteams-sbtest-nowrite-\(token)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(workFolderWrite: false))
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh", command: "echo x > inside.txt")
        let result = try ProcessRunner.run(
            executable: exe, arguments: args, currentDirectory: work, timeout: 20)
        XCTAssertNotEqual(result.exitCode, 0, "write must be denied when the work-folder write grant is off")
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("inside.txt").path))
    }

    func testIsSandboxDenialFailure() {
        XCTAssertTrue(SeatbeltSandbox.isSandboxDenialFailure(
            exitCode: 1, stderr: "sandbox-exec: execvp() failed"))
        XCTAssertTrue(SeatbeltSandbox.isSandboxDenialFailure(
            exitCode: 65, stderr: "sandbox_apply: Operation not permitted"))
        // A normal non-zero exit (the command itself failed) is NOT a sandbox failure.
        XCTAssertFalse(SeatbeltSandbox.isSandboxDenialFailure(
            exitCode: 1, stderr: "ls: no such file or directory"))
        // exit 0 is never a sandbox failure.
        XCTAssertFalse(SeatbeltSandbox.isSandboxDenialFailure(exitCode: 0, stderr: ""))
    }

    // MARK: - Temp directory trim

    func testProfile_tempTrim_keepsPreciseTmpAndSlashTmp_dropsBroadParents() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-temptrim").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(workFolderRoot: work) // defaults: temp write on
        let tmp = kernelPath(URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path)
        XCTAssertTrue(profile.contains("(subpath \"\(tmp)\")"), "the precise $TMPDIR stays granted")
        XCTAssertTrue(profile.contains("(subpath \"/private/tmp\")"), "/tmp stays granted")
        XCTAssertFalse(profile.contains("/private/var/tmp"), "/var/tmp must be dropped from the allow-list")
        XCTAssertFalse(
            profile.contains("(subpath \"/private/var/folders\")"),
            "the broad /private/var/folders parent must NOT be granted (only the precise $TMPDIR subpath)")
    }

    // MARK: - Home folder scope

    func testProfile_default_homeNotWritable() {
        // Defaults: homeWrite inherits everythingElseWrite=false → home not writable,
        // identical to the pre-split behavior where home rode inside "everything else".
        let work = URL(fileURLWithPath: "/tmp/nanoteams-home-default").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(workFolderRoot: work)
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertFalse(profile.contains("(subpath \"\(home)\")"), "home is not in any allow-list by default")
    }

    func testProfile_homeWriteOn_systemWriteOff_grantsHomeNotSystem() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-homewrite").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(homeWrite: true, everythingElseWrite: false))
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertTrue(profile.contains("(subpath \"\(home)\")"), "home folder is writable")
        XCTAssertFalse(profile.contains("(subpath \"/\")"), "system is NOT broadly writable")
        XCTAssertTrue(profile.contains("(deny file-write*"), "credential writes carved out of the home grant")
        XCTAssertTrue(profile.contains(".ssh"))
    }

    func testProfile_homeReadOff_systemReadOn_deniesHomeButReallowsWork() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL
        let work = home.appendingPathComponent(".nanoteams-readoff-work") // project inside home
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(homeRead: false, everythingElseRead: true))
        XCTAssertTrue(profile.contains("(allow file-read*)"), "system reads stay broad")
        XCTAssertTrue(profile.contains("(deny file-read*"), "home read carved out of the broad read")
        XCTAssertTrue(profile.contains("(subpath \"\(home.path)\")"), "home appears in the read-deny")
        // The project lives inside home — it must be re-allowed AFTER the home deny.
        XCTAssertTrue(
            profile.contains("(allow file-read*\n    (subpath \"\(work.path)\"))"),
            "the work folder is re-allowed after the home read-deny")
    }

    func testProfile_systemReadOff_homeReadOn_narrowReadIncludesHomeDeniesCreds() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-narrowhome").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(homeRead: true, everythingElseRead: false))
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertFalse(profile.contains("(allow file-read*)"), "reads are not broad")
        XCTAssertTrue(profile.contains("(allow file-read*\n"), "narrow read allow-list")
        XCTAssertTrue(profile.contains("(subpath \"\(home)\")"), "home is in the narrow read allow-list")
        XCTAssertTrue(profile.contains("(deny file-read*"), "credentials carved out of the home read grant")
        XCTAssertTrue(profile.contains(".ssh"))
    }

    /// Behavioral: with ONLY the home folder write granted (system write off), a write
    /// inside the home folder (outside the project) succeeds while a write to a system
    /// path is denied.
    func testProfile_homeWriteOn_confinesToHome_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let token = UUID().uuidString
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let work = home.appendingPathComponent(".nanoteams-sbtest-homew-\(token)")
        let homeProbe = home.appendingPathComponent(".nanoteams-sbtest-homeprobe-\(token).txt")
        // /private/var/tmp is user-writable but was DROPPED from the temp allow-list,
        // so it's a clean "system, not home, not temp" target.
        let sysProbe = URL(fileURLWithPath: "/private/var/tmp/nanoteams-sysprobe-\(token).txt")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: homeProbe)
            try? fm.removeItem(at: sysProbe)
        }

        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(homeWrite: true, everythingElseWrite: false))
        func run(_ command: String) throws -> ProcessRunner.Result {
            let (exe, args) = SeatbeltSandbox.wrap(profile: profile, shell: "/bin/zsh", command: command)
            return try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: work, timeout: 20)
        }

        let homeWrite = try run("echo HOME_OK > \(homeProbe.path) && echo DONE")
        XCTAssertTrue(homeWrite.stdout.contains("DONE"), "home write must succeed; stderr=\(homeWrite.stderr)")
        XCTAssertTrue(fm.fileExists(atPath: homeProbe.path))

        let sysWrite = try run("echo x > \(sysProbe.path)")
        XCTAssertNotEqual(sysWrite.exitCode, 0, "a system write must be denied when only home write is granted")
        XCTAssertFalse(fm.fileExists(atPath: sysProbe.path))
    }

    // MARK: - Credential ordering (credentials are the most-specific, last clause)

    func testProfile_credentialReadOn_homeReadOff_credentialsRemainReadable() {
        // An explicit credential-read grant must survive a home-read deny — every
        // credential store lives under ~, so the home deny would otherwise silently
        // negate credentialRead=true. Credentials are re-allowed after the home deny.
        let work = URL(fileURLWithPath: "/tmp/nanoteams-credread-homeoff").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(credentialRead: true, homeRead: false, everythingElseRead: true))
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertTrue(profile.contains("(deny file-read*\n    (subpath \"\(home)\"))"), "home read is denied")
        XCTAssertTrue(
            profile.contains("(allow file-read*\n    (subpath \"\(home)/.ssh\")"),
            "credential read grant must be re-allowed after the home deny, not silently dropped")
    }

    func testProfile_workEqualsHome_broadRead_credentialDenyOverridesWorkReallow() {
        // Project root == home, system read on, home read off, credential read off.
        // The work re-allow re-opens ~, but the credential deny is emitted LAST so
        // ~/.ssh etc. stay denied (no credential read leak).
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: home,
            permissions: BashSandboxPermissions(homeRead: false, everythingElseRead: true))
        let workReallow = profile.range(of: "(allow file-read*\n    (subpath \"\(home.path)\"))")
        XCTAssertNotNil(workReallow, "work (== home) is re-allowed for read")
        if let w = workReallow {
            // A credential deny must appear AFTER the work re-allow so ~/.ssh stays denied.
            let credAfter = profile.range(of: "(subpath \"\(home.path)/.ssh\")",
                                          range: w.upperBound..<profile.endIndex)
            XCTAssertNotNil(credAfter, "credential read-deny must come AFTER the work re-allow")
        }
    }

    func testProfile_workEqualsHome_broadWrite_credentialDenyOverridesWorkReallow() {
        // Same shape for writes (the hard 'credential writes ALWAYS blocked' invariant):
        // broad write + home write off + work == home → the work re-allow must not
        // re-expose ~/.ssh; the credential write-deny is emitted LAST.
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: home,
            permissions: BashSandboxPermissions(homeWrite: false, everythingElseWrite: true))
        let workReallow = profile.range(of: "(allow file-write*\n    (subpath \"\(home.path)\"))")
        XCTAssertNotNil(workReallow, "work (== home) is re-allowed for write under broad write")
        if let w = workReallow {
            // The write credential-deny must appear AFTER the work re-allow (the read
            // credential-deny earlier in the profile also names ~/.ssh, so scope the
            // search to the text following the write re-allow).
            let credAfter = profile.range(of: "(subpath \"\(home.path)/.ssh\")",
                                          range: w.upperBound..<profile.endIndex)
            XCTAssertNotNil(credAfter, "credential write-deny must come AFTER the work re-allow")
        }
    }

    func testProfile_workEqualsHome_narrowWrite_deniesCredentialWrite() {
        // Even with no broad escape hatch: if the project IS home, the work write grant
        // covers credentials, so they must be explicitly denied.
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: home,
            permissions: BashSandboxPermissions(homeWrite: false, everythingElseWrite: false))
        XCTAssertTrue(profile.contains("(deny file-write*"), "credential writes denied even though work == home")
        XCTAssertTrue(profile.contains("\(home.path)/.ssh"), "credential paths present in the write-deny")
    }

    /// Gold-standard live proof: with the project root == home and broad write on but
    /// home write off, a write to ~/.ssh/<probe> is denied (the work re-allow must not
    /// re-expose credentials). Uniquely-named probe, removed via defer — never touches
    /// real key files. Trivially passes if ~/.ssh is absent on the host.
    func testProfile_workEqualsHome_blocksCredentialWrite_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let probe = home.appendingPathComponent(".ssh/nanoteams-credleak-probe-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: probe) }
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: home,
            permissions: BashSandboxPermissions(homeWrite: false, everythingElseWrite: true))
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh",
            command: "echo LEAK > \(probe.path) 2>/dev/null; echo done")
        _ = try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: home, timeout: 20)
        XCTAssertFalse(
            fm.fileExists(atPath: probe.path),
            "a credential write must be blocked even when project root == home and broad write is on")
    }

    // MARK: - More matrix cells

    func testProfile_tempReadOff_broadRead_carvesOutTempDeny() {
        // credentialRead on isolates the read-deny to the temp carve-out (no cred
        // deny); home read inherits everythingElseRead=true so there's no home deny.
        // Work is outside temp so the temp deny is unambiguous.
        let work = URL(fileURLWithPath: "/opt/nanoteams-notempread").resolvingSymlinksInPath()
        let perms = BashSandboxPermissions(tempRead: false, credentialRead: true)
        let profile = SeatbeltSandbox.profile(workFolderRoot: work, permissions: perms)
        let tmp = kernelPath(URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path)
        XCTAssertTrue(profile.contains("(allow file-read*)"), "system reads stay broad")
        XCTAssertTrue(
            profile.contains("(deny file-read*\n    (subpath \"\(tmp)\")"),
            "turning temp read off must carve the temp dirs out of the broad read")
        XCTAssertFalse(
            profile.contains(".ssh"),
            "credentialRead on → no credential read-deny, so the temp deny is the only one")
    }

    func testProfile_workIsCredentialDir_broadWrite_credentialDenyOverridesWorkReallow() {
        // Project root IS a credential store (~/.ssh), broad write on, home write off.
        // The work re-allow re-opens ~/.ssh exactly, but the ALWAYS-blocked credential
        // write-deny is emitted dead last so ~/.ssh stays unwritable.
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL
        let work = home.appendingPathComponent(".ssh")
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(homeWrite: false, everythingElseWrite: true))
        XCTAssertTrue(profile.contains("(subpath \"/\")"), "broad write allows the whole filesystem")
        let workReallow = profile.range(of: "(allow file-write*\n    (subpath \"\(work.path)\"))")
        XCTAssertNotNil(workReallow, "work (== ~/.ssh) is re-allowed for write under broad write")
        if let w = workReallow {
            let credAfter = profile.range(of: "(subpath \"\(work.path)\")",
                                          range: w.upperBound..<profile.endIndex)
            XCTAssertNotNil(credAfter, "the credential write-deny must come AFTER the work re-allow")
        }
    }

    func testProfile_workIsCredentialDir_narrowRead_deniesViaWorkCoverage() {
        // NARROW read (system read off) + work == ~/.ssh + credentialRead off: the narrow
        // allow lists the work folder (== ~/.ssh), so the credential read-deny must fire
        // via `workCoversCredential` — otherwise the work allow would expose ~/.ssh. (Broad
        // read denies credentials UNCONDITIONALLY, so it can't prove the coverage path;
        // narrow read is the discriminating case.)
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL
        let work = home.appendingPathComponent(".ssh")
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(workFolderRead: true, everythingElseRead: false))
        XCTAssertFalse(profile.contains("(allow file-read*)"), "reads are narrow, not broad")
        XCTAssertTrue(
            profile.contains("(allow file-read*\n    (subpath \"\(work.path)\")"),
            "narrow read lists the work folder (== ~/.ssh)")
        XCTAssertTrue(
            profile.contains("(deny file-read*\n    (subpath \"\(work.path)\")"),
            "the credential read-deny fires via workCoversCredential, overriding the work allow")
    }

    func testProfile_devNodesAndFdRegexAlwaysPresentInWrite() {
        // Even with EVERY write scope off (no subpath grant), the dev nodes + fd/tty
        // regexes a shell needs for tty / pipes are always emitted.
        let work = URL(fileURLWithPath: "/opt/nanoteams-allwriteoff")
        let perms = BashSandboxPermissions(
            workFolderWrite: false, tempWrite: false, homeWrite: false, everythingElseWrite: false)
        let profile = SeatbeltSandbox.profile(workFolderRoot: work, permissions: perms)
        XCTAssertTrue(
            profile.contains("(allow file-write*\n    (literal \"/dev/null\")"),
            "with no write subpath grant, the write-allow goes straight to the dev nodes")
        XCTAssertTrue(profile.contains("(literal \"/dev/tty\")"))
        XCTAssertTrue(profile.contains("(regex #\"^/dev/fd/[0-9]+$\")"))
        XCTAssertTrue(profile.contains("(regex #\"^/dev/ttys[0-9]+$\")"))
    }

    /// Live: project root IS a credential store (~/.ssh) with broad write on but home
    /// write off — the work re-allow targets ~/.ssh exactly, yet a write to it must
    /// still be blocked. Uniquely-named probe, removed via defer; trivially passes if
    /// ~/.ssh is absent.
    func testProfile_workIsCredentialDir_blocksCredentialWrite_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let work = home.appendingPathComponent(".ssh")
        // Without ~/.ssh the probe write fails for lack of a parent dir, which is
        // indistinguishable from a sandbox block — skip so the test can't pass vacuously.
        guard fm.fileExists(atPath: work.path) else {
            throw XCTSkip("~/.ssh absent — a blocked write is indistinguishable from a missing parent dir")
        }
        let probe = work.appendingPathComponent("nanoteams-credleak-probe-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: probe) }
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(homeWrite: false, everythingElseWrite: true))
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh",
            command: "echo LEAK > \(probe.path) 2>/dev/null; echo done")
        _ = try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: home, timeout: 20)
        XCTAssertFalse(
            fm.fileExists(atPath: probe.path),
            "a write to the project root must be blocked when the project root IS a credential store")
    }
}
