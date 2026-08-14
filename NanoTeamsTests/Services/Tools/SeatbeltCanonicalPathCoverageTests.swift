import XCTest

@testable import NanoTeams

/// Pins that the Seatbelt profile embeds the path the KERNEL sees, in BOTH directions —
/// the allow-list and the denies.
///
/// `SeatbeltSandbox` canonicalized with `URL.resolvingSymlinksInPath()` under a doc comment
/// promising "Seatbelt matches on the real path, so a symlinked work folder (e.g. `/tmp` →
/// `/private/tmp`) would otherwise escape the write allow-list". That resolver does the
/// OPPOSITE for macOS's root-level symlinks — it strips a leading `/private` and hands back
/// the short form — so the one example the comment named was the case that did not work.
///
/// Measured on macOS 26, against the profile this file generates:
///   * a work folder under `$TMPDIR` was NOT writable despite `workFolderWrite: true`;
///   * with `everythingElseWrite: true, tempWrite: false`, a write into `$TMPDIR` SUCCEEDED
///     despite the explicit deny.
/// The first merely breaks the tool. The second is a switch the user turned off having no
/// effect, silently — and the same arithmetic governs the credential denies whenever `$HOME`
/// is reached through a symlink.
///
/// Why the existing suite missed it, which is the more useful half: every live write test
/// deliberately avoids the temp dirs. `testProfile_confinesWritesToWorkFolder` says so in its
/// own comment ("Uses home-dir-based paths because the profile intentionally also allows the
/// temp dirs"), and `$HOME` is the one prefix on this machine that is not symlinked.
/// `testProfile_canonicalizesSymlinkedRoot` drives a symlink it creates itself — which
/// Foundation's resolver DOES traverse — and its comment even records the well-known
/// symlinks being "left in short form on this OS" as a test inconvenience rather than as the
/// defect. And `testProfile_compilesAndRunsUnderSandboxExec` proves the profile COMPILES,
/// never that it GRANTS.
final class SeatbeltCanonicalPathCoverageTests: XCTestCase {

    private var created: [URL] = []

    override func tearDown() {
        for url in created { try? FileManager.default.removeItem(at: url) }
        created = []
        super.tearDown()
    }

    private func makeDirectory(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        created.append(url)
        return url
    }

    /// The kernel's own answer, used as the oracle rather than re-implementing production's
    /// rule. `realpath(3)` is what Seatbelt effectively resolves an accessed path through.
    private func kernelPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func requireSandboxExec() throws {
        guard FileManager.default.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
    }

    private func run(_ command: String, profile: String, cwd: URL) throws -> ProcessRunner.Result {
        let (exe, args) = SeatbeltSandbox.wrap(profile: profile, shell: "/bin/zsh", command: command)
        return try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: cwd, timeout: 20)
    }

    // MARK: - The platform fact the fix exists for

    /// Not a choice and not a defect of ours — a measured property of Foundation that decides
    /// which primitive is correct here. Pinned so a future "simplify back to
    /// `resolvingSymlinksInPath`" is refused by a test that states why.
    ///
    /// RED: none against production. This asserts platform behaviour; it fails only if
    /// Foundation starts expanding the root-level symlinks, at which point the two primitives
    /// agree and `canonical(_:)`'s justification needs rewriting rather than its code.
    func testFoundationResolver_returnsTheShortForm_whichIsWhyRealpathIsUsed() {
        for shortForm in ["/tmp", "/var", NSTemporaryDirectory()] {
            let foundation = URL(fileURLWithPath: shortForm)
                .resolvingSymlinksInPath().standardizedFileURL.path
            let kernel = kernelPath(URL(fileURLWithPath: shortForm).standardizedFileURL.path)
            XCTAssertNotEqual(
                foundation, kernel,
                "\(shortForm): the two resolvers are expected to DISAGREE on macOS — "
                    + "Foundation keeps the short form, the kernel reports /private/…")
            XCTAssertTrue(kernel.hasPrefix("/private/"), "kernel path for \(shortForm): \(kernel)")
        }
    }

    // MARK: - Allow direction

    /// RED: restore `url.resolvingSymlinksInPath().standardizedFileURL.path` in
    /// `SeatbeltSandbox.canonical` → the profile grants `/var/folders/…` while the kernel asks
    /// about `/private/var/folders/…`, and this write fails with
    /// `zsh:1: operation not permitted` even though `workFolderWrite` is on.
    func testWorkFolderUnderTMPDIR_isWritableFromInsideTheSandbox() throws {
        try requireSandboxExec()
        let work = try makeDirectory(at: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-canonwrite-\(UUID().uuidString)"))

        let profile = SeatbeltSandbox.profile(workFolderRoot: work)
        let result = try run("echo x > inside.txt && echo INSIDE_OK", profile: profile, cwd: work)

        XCTAssertTrue(
            result.stdout.contains("INSIDE_OK"),
            "a work folder under $TMPDIR must be writable when workFolderWrite is on; "
                + "stderr=\(result.stderr)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("inside.txt").path))
    }

    /// The static half of the same fact, and the one that names the mechanism: the emitted
    /// subpath is the kernel's path, and the short form appears nowhere.
    ///
    /// RED: restore the Foundation resolver → the `/private/var/folders/…` assertion fails and
    /// the "short form absent" assertion fails.
    func testProfile_embedsTheKernelPath_notFoundationsShortForm() throws {
        let work = try makeDirectory(at: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-canonstatic-\(UUID().uuidString)"))
        let shortForm = work.standardizedFileURL.path
        let kernel = kernelPath(shortForm)
        XCTAssertNotEqual(shortForm, kernel, "fixture must actually sit under a symlinked prefix")

        let profile = SeatbeltSandbox.profile(workFolderRoot: work)
        XCTAssertTrue(
            profile.contains("(subpath \"\(kernel)\")"),
            "profile must grant the path the kernel resolves to")
        XCTAssertFalse(
            profile.contains("(subpath \"\(shortForm)\")"),
            "profile must not grant the short form, which matches nothing")
    }

    /// `/tmp` is the example the file's own doc comment used. Driven through a REAL directory
    /// because `realpath` needs the path to exist — which is also why the several existing
    /// tests that pass a non-existent `/tmp/nanoteams-…` path are unaffected by the fix.
    ///
    /// RED: restore the Foundation resolver → the profile carries `/tmp/…`.
    func testProfile_workFolderUnderSlashTmp_embedsPrivateTmp() throws {
        let work = try makeDirectory(at: URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("nanoteams-canontmp-\(UUID().uuidString)"))
        let profile = SeatbeltSandbox.profile(workFolderRoot: work)
        let leaf = work.lastPathComponent

        XCTAssertTrue(profile.contains("(subpath \"/private/tmp/\(leaf)\")"), profile)
        XCTAssertFalse(profile.contains("(subpath \"/tmp/\(leaf)\")"), profile)
    }

    // MARK: - Deny direction (the security half)

    /// A grant the user switched OFF must actually be off. With the broad escape hatch on and
    /// temp writes off, the deny clause has to match — and before the fix it did not, so
    /// `$TMPDIR` stayed writable.
    ///
    /// The work folder deliberately lives under `$HOME` (the one unsymlinked prefix here) so
    /// the temp deny is the only clause in play — same reasoning as
    /// `testProfile_tempReadOff_broadRead_carvesOutTempDeny`.
    ///
    /// RED: restore the Foundation resolver → `TEMP_WRITE_SUCCEEDED` appears and the file exists.
    func testTempWriteOff_underBroadWrite_actuallyDeniesTMPDIR() throws {
        try requireSandboxExec()
        let work = try makeDirectory(at: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".nanoteams-canondeny-\(UUID().uuidString)"))
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-canondeny-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: marker) }

        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(tempWrite: false, everythingElseWrite: true))
        let result = try run(
            "echo x > \(marker.path) && echo TEMP_WRITE_SUCCEEDED", profile: profile, cwd: work)

        XCTAssertFalse(
            result.stdout.contains("TEMP_WRITE_SUCCEEDED"),
            "tempWrite: false must actually deny $TMPDIR; stderr=\(result.stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// The escape hatch itself must still work — the fix narrows nothing that was legitimately
    /// granted. Without this, "deny everything" would satisfy the test above.
    ///
    /// RED: emit the temp deny unconditionally → this fails while the test above still passes,
    /// so the pair distinguishes "honours the toggle" from "always denies".
    func testTempWriteOn_underBroadWrite_stillAllowsTMPDIR() throws {
        try requireSandboxExec()
        let work = try makeDirectory(at: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".nanoteams-canonallow-\(UUID().uuidString)"))
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-canonallow-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: marker) }

        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(everythingElseWrite: true))
        let result = try run(
            "echo x > \(marker.path) && echo TEMP_WRITE_SUCCEEDED", profile: profile, cwd: work)

        XCTAssertTrue(result.stdout.contains("TEMP_WRITE_SUCCEEDED"), "stderr=\(result.stderr)")
    }

    // MARK: - Fallback

    /// `realpath` fails on a path that does not exist. The fallback must not crash or emit an
    /// empty subpath — it degrades to Foundation's answer, which describes a path nothing can
    /// reach anyway.
    ///
    /// RED: drop the `?? Foundation` fallback and force-unwrap `realpath` → crash.
    func testNonExistentWorkFolder_stillProducesACompilableProfile() throws {
        try requireSandboxExec()
        let ghost = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-canon-ghost-\(UUID().uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghost.path))

        let profile = SeatbeltSandbox.profile(workFolderRoot: ghost)
        XCTAssertTrue(profile.contains("(subpath \"\(ghost.standardizedFileURL.path)\")"), profile)

        let result = try run("echo GHOST_OK", profile: profile, cwd: URL(fileURLWithPath: "/private/tmp"))
        XCTAssertEqual(result.exitCode, 0, "profile must still compile; stderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("GHOST_OK"))
    }

    /// The common case must not move: a work folder under `/Users` is not symlinked, so the two
    /// resolvers agree and the emitted profile is unchanged by this fix. This is what keeps the
    /// existing suite green and the change reviewable.
    ///
    /// RED: re-implement `canonical(_:)` as a string rewrite of the known root symlinks —
    /// `/var/` → `/private/var/` etc., which is exactly what `FileSystemWatcher.canonicalPath`
    /// does and therefore the most likely "simplification" of this fix — but get the prefix
    /// unconditional (`"/private" + path`) → every unsymlinked work folder is granted a path
    /// that does not exist and nothing under `$HOME` is writable any more. This reds; the
    /// symlink tests above do not.
    func testProfile_unsymlinkedWorkFolder_isUnchangedByCanonicalization() throws {
        let work = try makeDirectory(at: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".nanoteams-canonsame-\(UUID().uuidString)"))
        let profile = SeatbeltSandbox.profile(workFolderRoot: work)
        XCTAssertEqual(work.standardizedFileURL.path, kernelPath(work.standardizedFileURL.path))
        XCTAssertTrue(profile.contains("(subpath \"\(work.standardizedFileURL.path)\")"), profile)
    }
}
