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

    /// The LIMIT this profile has, pinned so nobody trusts an environment variable again (#375):
    /// from inside the profile, `sysctl` `KERN_PROCARGS2` reads another process's environment —
    /// here NanoTeams' own `--mcp-stdio` bridge started with a secret in it, the way Claude
    /// Desktop starts it. Measured 2026-11-08: no SBPL clause closes it (`process-info*` narrowed
    /// to self or same-sandbox, `sysctl-read` denied by name or entirely). The sibling must be an
    /// ordinary binary: macOS hides the environment of its own platform binaries (`/bin/sleep`
    /// reads as nothing even unsandboxed), not of a client's. If this goes red, macOS closed the
    /// channel: revisit DEBTS D-M16 and the "Never in an environment variable" rule — in
    /// `ExternalAgentsSetupPrompt.rules` and
    /// `ExternalAgentsSettingsPresentation.environmentTokenWarningText`; do not delete the test.
    func testProfile_cannotHideAnotherProcesssEnvironment() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let python = "/usr/bin/python3"
        guard (try? ProcessRunner.run(
            executable: python, arguments: ["-I", "-c", "print(1)"], currentDirectory: nil, timeout: 20))?.exitCode == 0
        else {
            throw XCTSkip("python3 unavailable on this host")
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-sbprocargs-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let script = work.appendingPathComponent("procargs.py")
        try """
        import ctypes, sys
        libc = ctypes.CDLL(None)
        mib = (ctypes.c_int * 3)(1, 49, int(sys.argv[1]))
        size = ctypes.c_size_t(0)
        libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0)
        buf = ctypes.create_string_buffer(size.value)
        libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0)
        sys.stdout.write("RESULT=SEEN" if sys.argv[2].encode() in buf.raw[:size.value] else "RESULT=HIDDEN")
        """.write(to: script, atomically: true, encoding: .utf8)

        let value = UUID().uuidString
        let secret = "NT_SECRET_PROBE=\(value)"
        let sibling = Process()
        sibling.executableURL = try XCTUnwrap(Bundle.main.executableURL)
        sibling.arguments = ["--mcp-stdio", "--port", "1"]
        // No profile file for a coverage-instrumented child, and its cwd a folder of its own.
        sibling.environment = ["NT_SECRET_PROBE": value, "HOME": NSHomeDirectory(), "LLVM_PROFILE_FILE": "/dev/null"]
        sibling.currentDirectoryURL = work
        let siblingInput = Pipe()
        sibling.standardInput = siblingInput
        sibling.standardOutput = FileHandle.nullDevice
        sibling.standardError = FileHandle.nullDevice
        try sibling.run()
        defer {
            try? siblingInput.fileHandleForWriting.close()
            if sibling.isRunning { sibling.terminate() }
            sibling.waitUntilExit()
        }
        usleep(300_000)
        XCTAssertTrue(sibling.isRunning, "the bridge waits on its open stdin")

        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [47321])
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh",
            command: "\(python) -I \(script.path) \(sibling.processIdentifier) \(secret)")
        let result = try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: work, timeout: 20)
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        // A marker, not the whole stdout: a login shell's startup files may print. Neither marker
        // means the probe itself failed — not that macOS closed the channel.
        XCTAssertTrue(
            result.stdout.contains("RESULT=SEEN") || result.stdout.contains("RESULT=HIDDEN"),
            "the probe did not run: stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("RESULT=SEEN"), "the sandboxed shell read the sibling's environment")
    }

    // MARK: - Agent token locations and the External Agents port, live (#375)

    /// With a fake home: the token file and the pasted Codex config are unreadable from inside the
    /// profile WHATEVER the grants — credential reads on included — while a work folder inside a
    /// client folder (a Claude skill) reads as a project, and the credential stores around it do not.
    func testProfile_tokenLocationsStayDenied_andAWorkFolderInsideAClientFolderReads_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let home = fm.temporaryDirectory.appendingPathComponent("nt-sbhome-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        func write(_ text: String, _ relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("TOKEN_FILE", ".config/nanoteams/a4c36525.token")
        try write("CODEX_TOKEN", ".codex/config.toml")
        try write("CLAUDE_SETTINGS", ".claude/settings.json")
        try write("SKILL_BODY", ".claude/skills/my-skill/SKILL.md")
        let skill = home.appendingPathComponent(".claude/skills/my-skill", isDirectory: true)

        func run(_ command: String, _ permissions: BashSandboxPermissions) throws -> String {
            let profile = SeatbeltSandbox.profile(
                workFolderRoot: skill, permissions: permissions, guardedLoopbackPorts: [], home: home)
            let (exe, args) = SeatbeltSandbox.wrap(profile: profile, shell: "/bin/zsh", command: command)
            return try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: skill, timeout: 20).stdout
        }
        let h = home.path
        for permissions in [BashSandboxPermissions(), BashSandboxPermissions(credentialRead: true)] {
            let out = try run(
                "cat SKILL.md; cat '\(h)/.config/nanoteams/a4c36525.token'; cat '\(h)/.codex/config.toml'; echo DONE",
                permissions)
            XCTAssertTrue(out.contains("SKILL_BODY"), "the project reads: \(out)")
            XCTAssertFalse(out.contains("TOKEN_FILE"), "token file read with \(permissions): \(out)")
            XCTAssertFalse(out.contains("CODEX_TOKEN"), "pasted config read with \(permissions): \(out)")
            XCTAssertTrue(out.contains("DONE"))
        }
        let closed = try run("cat '\(h)/.claude/settings.json'; echo DONE", BashSandboxPermissions())
        XCTAssertFalse(closed.contains("CLAUDE_SETTINGS"), "a client folder stays a credential store: \(closed)")
        let granted = try run("cat '\(h)/.claude/settings.json'; echo DONE", BashSandboxPermissions(credentialRead: true))
        XCTAssertTrue(granted.contains("CLAUDE_SETTINGS"), "credential reads granted open the folder, not its tokens: \(granted)")
    }

    /// The one shape where a work folder is INSIDE a credential store and CONTAINS one: a home
    /// under `/Library/Keychains` (the one store that is an absolute path, not `$HOME`-relative).
    /// The profile must give the project back after the credential deny and then take the store
    /// inside it away again — for reads AND for writes, which is what a project inside a client
    /// folder lost when the client folders entered every profile (#376).
    func testProfile_workInsideAStoreAndAStoreInsideWork_reallowsTheProjectAndRedeniesTheStore() {
        let home = URL(fileURLWithPath: "/Library/Keychains/fakehome", isDirectory: true)
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: home,
            permissions: BashSandboxPermissions(homeWrite: true),
            guardedLoopbackPorts: [],
            home: home)
        let work = "/Library/Keychains/fakehome"
        // Read side: deny the stores, give the project back, re-deny the store inside it.
        let readDeny = profile.range(of: "(deny file-read*")
        let readReallow = profile.range(of: "(allow file-read*\n    (subpath \"\(work)\"))")
        XCTAssertNotNil(readDeny)
        XCTAssertNotNil(readReallow, profile)
        if let readDeny, let readReallow {
            XCTAssertLessThan(readDeny.lowerBound, readReallow.lowerBound, "re-allow comes after the deny")
        }
        XCTAssertTrue(
            profile.contains("(subpath \"\(work)/.ssh\")"),
            "the store inside the project is named again: \(profile)")
        // Write side: the same shape, which had no re-allow at all until 2026-11-08.
        XCTAssertTrue(
            profile.contains("(allow file-write*\n    (subpath \"\(work)\"))"), profile)
        // And the token locations still come last.
        let tokenDeny = profile.range(of: "(deny file-read* file-write*")
        XCTAssertNotNil(tokenDeny, profile)
        if let tokenDeny, let readReallow {
            XCTAssertGreaterThan(tokenDeny.lowerBound, readReallow.lowerBound)
        }
    }

    /// A dotfiles manager links the folders themselves (`~/.config/nanoteams ->
    /// ~/dotfiles/nanoteams`, `~/.claude -> ~/dotfiles/claude`, or a single
    /// `~/.codex/config.toml`). Seatbelt matches the path the KERNEL resolved, so a deny written
    /// only on the link protected the link: `cat ~/dotfiles/…/<id>.token` and `grep -r ntm_ ~`
    /// both returned the bearer with default grants (#376).
    func testProfile_aSymlinkedClientFolder_isDeniedByBothSpellings_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let home = fm.temporaryDirectory.appendingPathComponent("nt-sblink-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        func write(_ text: String, _ relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("TOKEN_THROUGH_LINK", "dotfiles/nanoteams/a4c36525.token")
        try write("CODEX_THROUGH_LINK", "dotfiles/codex/config.toml")
        try write("KEY_THROUGH_LINK", "dotfiles/ssh/id_ed25519")
        try fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".config"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: home.appendingPathComponent(".config/nanoteams"),
            withDestinationURL: home.appendingPathComponent("dotfiles/nanoteams"))
        try fm.createSymbolicLink(
            at: home.appendingPathComponent(".claude"),
            withDestinationURL: home.appendingPathComponent("dotfiles/claude"))
        try fm.createSymbolicLink(
            at: home.appendingPathComponent(".codex/config.toml"),
            withDestinationURL: home.appendingPathComponent("dotfiles/codex/config.toml"))
        try fm.createSymbolicLink(
            at: home.appendingPathComponent(".ssh"),
            withDestinationURL: home.appendingPathComponent("dotfiles/ssh"))
        let work = home.appendingPathComponent("dev/proj", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try write("PROJECT", "dev/proj/README.md")

        let h = home.path
        for permissions in [BashSandboxPermissions(), BashSandboxPermissions(credentialRead: true)] {
            let profile = SeatbeltSandbox.profile(
                workFolderRoot: work, permissions: permissions, guardedLoopbackPorts: [], home: home)
            let (exe, args) = SeatbeltSandbox.wrap(
                profile: profile, shell: "/bin/zsh",
                command: "cat README.md; cat '\(h)/dotfiles/nanoteams/a4c36525.token'; "
                    + "cat '\(h)/dotfiles/codex/config.toml'; cat '\(h)/dotfiles/ssh/id_ed25519'; echo DONE")
            let out = try ProcessRunner.run(
                executable: exe, arguments: args, currentDirectory: work, timeout: 20).stdout
            XCTAssertTrue(out.contains("PROJECT"), "the project still reads: \(out)")
            XCTAssertTrue(out.contains("DONE"), "the probe ran: \(out)")
            XCTAssertFalse(out.contains("TOKEN_THROUGH_LINK"), "token read through its real path with \(permissions): \(out)")
            XCTAssertFalse(out.contains("CODEX_THROUGH_LINK"), "pasted config read through its real path with \(permissions): \(out)")
            // The ssh store follows the credential-read grant, like any store — what must stay
            // denied under EVERY grant is the token locations above.
            if !permissions.credentialRead {
                XCTAssertFalse(
                    out.contains("KEY_THROUGH_LINK"),
                    "store read through its real path with \(permissions): \(out)")
            }
        }
    }

    /// The global skill-root re-allow must not widen a grant: a skills root kept in a dotfiles
    /// repo (`~/.claude/skills -> ~/dotfiles`) re-allowed the whole repo as its real path, and
    /// `~/.ssh` stowed from it became readable with the DEFAULT grants (review 2026-11-08).
    func testProfile_aSymlinkedSkillRoot_doesNotReopenAStowedCredentialStore_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let home = fm.temporaryDirectory.appendingPathComponent("nt-sbskillsym-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        func write(_ text: String, _ relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("SSH_PRIVATE_KEY", "dotfiles/ssh/id_ed25519")
        try write("SKILL_BODY", "dotfiles/pdf/SKILL.md")
        try fm.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: home.appendingPathComponent(".claude/skills"),
            withDestinationURL: home.appendingPathComponent("dotfiles"))
        try fm.createSymbolicLink(
            at: home.appendingPathComponent(".ssh"),
            withDestinationURL: home.appendingPathComponent("dotfiles/ssh"))
        let work = home.appendingPathComponent("dev/proj", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let h = home.path
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [], home: home)
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh",
            command: "cat '\(h)/dotfiles/ssh/id_ed25519'; cat '\(h)/.claude/skills/pdf/SKILL.md'; "
                + "grep -rl PRIVATE_KEY '\(h)/dotfiles' 2>/dev/null; echo DONE")
        let out = try ProcessRunner.run(
            executable: exe, arguments: args, currentDirectory: work, timeout: 20).stdout
        XCTAssertTrue(out.contains("DONE"), "the probe ran: \(out)")
        XCTAssertFalse(out.contains("SSH_PRIVATE_KEY"), "a stowed store must stay denied: \(out)")
        XCTAssertFalse(out.contains("id_ed25519"), "nor found by a walk: \(out)")
    }

    /// With Home: Read OFF no grant covers the skill roots, so nothing re-allows them: the
    /// justification for the re-allow is a broader grant that would otherwise have covered them.
    func testProfile_withHomeReadOff_doesNotReopenTheSkillRoots() {
        let home = kernelPath(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: URL(fileURLWithPath: "/tmp/nanoteams-sb-skillgrant").resolvingSymlinksInPath(),
            permissions: BashSandboxPermissions(homeRead: false, everythingElseRead: false),
            guardedLoopbackPorts: [])
        XCTAssertFalse(
            profile.contains("(allow file-read*\n    (subpath \"\(home)/.claude/skills\")"), profile)
    }

    /// A project INSIDE a client folder stays writable. The client folders entered every profile
    /// in #375, and their write deny had no work re-allow beneath it — so granting Home: Write
    /// (or the system escape hatch) made a Claude skill folder read-only, `.git/index.lock`
    /// included, while Settings showed the work-folder write grant ON (#376).
    func testProfile_aWorkFolderInsideAClientFolder_staysWritable_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let home = fm.temporaryDirectory.appendingPathComponent("nt-sbwrite-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let skill = home.appendingPathComponent(".claude/skills/my-skill", isDirectory: true)
        try fm.createDirectory(at: skill, withIntermediateDirectories: true)
        let token = home.appendingPathComponent(".config/nanoteams/a4c36525.token")
        try fm.createDirectory(at: token.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "TOKEN_FILE".write(to: token, atomically: true, encoding: .utf8)

        for permissions in [
            BashSandboxPermissions(),
            BashSandboxPermissions(homeWrite: true),
            BashSandboxPermissions(everythingElseWrite: true),
        ] {
            let profile = SeatbeltSandbox.profile(
                workFolderRoot: skill, permissions: permissions, guardedLoopbackPorts: [], home: home)
            let (exe, args) = SeatbeltSandbox.wrap(
                profile: profile, shell: "/bin/zsh",
                command: "echo WROTE > made.txt && cat made.txt; "
                    + "echo CLOBBER > '\(token.path)' 2>/dev/null; cat '\(token.path)' 2>/dev/null; echo DONE")
            let out = try ProcessRunner.run(
                executable: exe, arguments: args, currentDirectory: skill, timeout: 20).stdout
            try? fm.removeItem(at: skill.appendingPathComponent("made.txt"))
            XCTAssertTrue(out.contains("WROTE"), "the project must stay writable with \(permissions): \(out)")
            XCTAssertFalse(out.contains("CLOBBER"), "a token file is never writable: \(out)")
            XCTAssertEqual(
                try String(contentsOf: token, encoding: .utf8), "TOKEN_FILE",
                "the token file survived \(permissions)")
        }
    }

    /// The global skill and command roots live inside the client folders, and their content
    /// already rides role prompts through `{roleSkills}` — so a role asked to open one by hand is
    /// not refused, while the rest of the folder stays a credential store.
    func testProfile_globalSkillRoots_stayReadable_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let home = fm.temporaryDirectory.appendingPathComponent("nt-sbskill-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        func write(_ text: String, _ relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("SKILL_BODY", ".claude/skills/pdf/SKILL.md")
        try write("COMMAND_BODY", ".claude/commands/review.md")
        try write("SETTINGS", ".claude/settings.json")
        try write("TOKEN_FILE", ".config/nanoteams/a4c36525.token")
        let work = home.appendingPathComponent("dev/proj", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let h = home.path
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [], home: home)
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh",
            command: "cat '\(h)/.claude/skills/pdf/SKILL.md'; cat '\(h)/.claude/commands/review.md'; "
                + "cat '\(h)/.claude/settings.json'; cat '\(h)/.config/nanoteams/a4c36525.token'; echo DONE")
        let out = try ProcessRunner.run(
            executable: exe, arguments: args, currentDirectory: work, timeout: 20).stdout
        XCTAssertTrue(out.contains("DONE"), "the probe ran: \(out)")
        XCTAssertTrue(out.contains("SKILL_BODY"), "a global skill stays readable: \(out)")
        XCTAssertTrue(out.contains("COMMAND_BODY"), "a global command stays readable: \(out)")
        XCTAssertFalse(out.contains("SETTINGS"), "the rest of the folder is still a store: \(out)")
        XCTAssertFalse(out.contains("TOKEN_FILE"), "the token folder is denied dead last: \(out)")
    }

    /// A work-folder file that configures a coding agent is a proxy OUTSIDE this sandbox: the
    /// client reads it with the person's own rights. Reading stays allowed; writing does not.
    func testProfile_projectAgentConfigurations_areReadOnly_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let work = fm.temporaryDirectory.appendingPathComponent("nt-sbcfg-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work.appendingPathComponent(".vscode"), withIntermediateDirectories: true)
        try "ORIGINAL".write(to: work.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try "ORIGINAL".write(to: work.appendingPathComponent(".vscode/mcp.json"), atomically: true, encoding: .utf8)

        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [])
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh",
            command: "cat .mcp.json; echo CLOBBER > .mcp.json 2>/dev/null; "
                + "echo CLOBBER > .vscode/mcp.json 2>/dev/null; echo ok > plain.txt; cat plain.txt; echo DONE")
        let out = try ProcessRunner.run(
            executable: exe, arguments: args, currentDirectory: work, timeout: 20).stdout
        XCTAssertTrue(out.contains("ORIGINAL"), "reading stays allowed: \(out)")
        XCTAssertTrue(out.contains("ok"), "an ordinary file is still writable: \(out)")
        XCTAssertTrue(out.contains("DONE"))
        for name in [".mcp.json", ".vscode/mcp.json"] {
            XCTAssertEqual(
                try String(contentsOf: work.appendingPathComponent(name), encoding: .utf8), "ORIGINAL",
                "\(name) must not be writable from bash")
        }
    }

    /// The External Agents port cannot be bound from inside the profile — not on 127.0.0.1, [::1]
    /// or the wildcards — whether or not the server is on, while another port binds as usual.
    func testProfile_externalAgentsPortCannotBeBound_live() throws {
        try assertLoopbackPortGuardedLive { guarded, work in
            SeatbeltSandbox.profile(
                workFolderRoot: work, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [guarded])
        }
    }

    /// The same two refusals for the port of a configured MCP or LLM server on this machine.
    /// Without them a role's approved `bash` could call that server directly with a bearer it
    /// read from a `security`-made Keychain item (D-M16) — past the approval gate and the tool
    /// pins — or listen on its port and receive the bearer, or every prompt, NanoTeams sends.
    func testProfile_loopbackServerPortCannotBeBoundOrReached_live() throws {
        try assertLoopbackPortGuardedLive { guarded, work in
            SeatbeltSandbox.profile(
                workFolderRoot: work, permissions: BashSandboxPermissions(),
                guardedLoopbackPorts: SeatbeltSandbox.guardedLoopbackPorts(
                    externalAgentsPort: nil, mcpServerPorts: [guarded], llmServerPorts: []))
        }
    }

    /// Two loopback ports free right now, held together while the second is chosen so they
    /// differ — the guarded port and its unguarded neighbour. Fixed ports collided with whatever
    /// else held them on the machine running the suite (review 2026-11-08).
    private func twoFreeLoopbackPorts() throws -> (UInt16, UInt16) {
        func open() throws -> Int32 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw XCTSkip("no socket on this host") }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { close(fd); throw XCTSkip("cannot bind 127.0.0.1:0") }
            return fd
        }
        func port(of fd: Int32) -> UInt16 {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            return UInt16(bigEndian: address.sin_port)
        }
        let first = try open()
        defer { close(first) }
        let second = try open()
        defer { close(second) }
        return (port(of: first), port(of: second))
    }

    /// Runs the bind and connect probes inside the profile `profileFor` builds for a scratch work
    /// folder and a guarded port this helper picks: that port refuses a bind on every loopback
    /// and wildcard address with EPERM — the sandbox's errno, not EADDRINUSE from some other
    /// listener — and a connect on 127.0.0.1 and ::1, while a second free port binds and
    /// connects as usual.
    private func assertLoopbackPortGuardedLive(
        profileFor: (_ guarded: UInt16, _ work: URL) -> String
    ) throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let python = "/usr/bin/python3"
        guard (try? ProcessRunner.run(
            executable: python, arguments: ["-I", "-c", "print(1)"], currentDirectory: nil, timeout: 20))?.exitCode == 0
        else {
            throw XCTSkip("python3 unavailable on this host")
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-sbbind-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let (guarded, neighbour) = try twoFreeLoopbackPorts()
        let script = work.appendingPathComponent("bind.py")
        try """
        import socket, sys
        port = int(sys.argv[1])
        for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1"), (socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
            s = socket.socket(family, socket.SOCK_STREAM)
            try:
                s.bind((host, port)); s.listen(1); print(f"BOUND {host}")
            except OSError as e:
                print(f"REFUSED {host} {e.errno}")
            finally:
                s.close()
        """.write(to: script, atomically: true, encoding: .utf8)
        let profile = profileFor(guarded, work)
        func run(_ port: UInt16) throws -> String {
            let (exe, args) = SeatbeltSandbox.wrap(
                profile: profile, shell: "/bin/zsh", command: "\(python) -I \(script.path) \(port)")
            return try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: work, timeout: 20).stdout
        }
        let refused = try run(guarded)
        XCTAssertFalse(refused.contains("BOUND"), refused)
        for host in ["127.0.0.1", "::1", "0.0.0.0", "::"] {
            XCTAssertTrue(refused.contains("REFUSED \(host) \(EPERM)\n"), "\(host) refused by the sandbox: \(refused)")
        }
        let open = try run(neighbour)
        XCTAssertTrue(open.contains("BOUND 127.0.0.1"), "an unguarded port binds as usual: \(open)")

        // And the outbound half: the deny is written on `*:<port>`, so one clause covers
        // 127.0.0.1, ::1 and the mapped spellings alike (EPERM = 1), while a port nobody guards
        // answers with the ordinary refusal (ECONNREFUSED = 61). Measured here rather than
        // assumed, because the `localhost:<port>` spelling it replaced let `::ffff:0.0.0.0`
        // through to the server (review 2026-11-08, #376).
        let connectScript = work.appendingPathComponent("connect.py")
        try """
        import socket, sys
        port = int(sys.argv[1])
        for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1"), (socket.AF_INET6, "::ffff:0.0.0.0"), (socket.AF_INET6, "::ffff:127.0.0.1"), (socket.AF_INET, "0.0.0.0")):
            s = socket.socket(family, socket.SOCK_STREAM)
            s.settimeout(2)
            try:
                s.connect((host, port)); print(f"CONNECTED {host}")
            except OSError as e:
                print(f"ERRNO {host} {e.errno}")
            finally:
                s.close()
        """.write(to: connectScript, atomically: true, encoding: .utf8)
        func connect(_ port: UInt16) throws -> String {
            let (exe, args) = SeatbeltSandbox.wrap(
                profile: profile, shell: "/bin/zsh", command: "\(python) -I \(connectScript.path) \(port)")
            return try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: work, timeout: 20).stdout
        }
        let blocked = try connect(guarded)
        XCTAssertFalse(blocked.contains("CONNECTED"), blocked)
        // Every route, the IPv4-mapped unspecified address included — the one a `localhost:` clause
        // let through to a server on 127.0.0.1 (review 2026-11-08, measured with stock curl).
        for host in ["127.0.0.1", "::1", "::ffff:0.0.0.0", "::ffff:127.0.0.1", "0.0.0.0"] {
            XCTAssertTrue(blocked.contains("ERRNO \(host) 1\n"), "\(host) denied by the sandbox: \(blocked)")
        }
        let reachable = try connect(neighbour)
        XCTAssertFalse(reachable.contains("ERRNO 127.0.0.1 1"), "an unguarded port is not the sandbox's business: \(reachable)")
    }

    // MARK: - `bash` reads the batch's ports, and a background command keeps its own

    private func sandboxedBashTool(_ work: URL) -> BashTool {
        BashTool(
            workFolderRoot: work, resolver: SandboxPathResolver(workFolderRoot: work), fileManager: .default)
    }

    private func envelope(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// The port comes from the CONTEXT, per call: the same tool refuses a bind on a port this
    /// batch reserves and allows it when the batch does not — and says why it refused, naming
    /// the reserved ports, because `Operation not permitted` alone reads as a file permission
    /// or a reason for `sudo` (review 2026-11-08).
    func testBashTool_refusesAPortTheBatchReserves_andSaysWhy_live() async throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-sbbash-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let (port, _) = try twoFreeLoopbackPorts()
        // Another suite in this process may have reserved ports; this one must not be among them.
        LoopbackPortReservations.shared._testForget()
        let tool = sandboxedBashTool(work)
        let command = "/usr/bin/python3 -I -c \"import socket; s=socket.socket(); s.bind(('127.0.0.1', \(port))); print('BOUND')\""
        func context(_ ports: [UInt16]) -> ToolExecutionContext {
            ToolExecutionContext(workFolderRoot: work, taskID: 1, runID: 0, roleID: "r", guardedLoopbackPorts: ports)
        }

        let refused = envelope(await tool.handle(context: context([port]), args: ["command": command]).outputJSON)
        let data = refused["data"] as? [String: Any] ?? [:]
        XCTAssertNotEqual(data["exit_code"] as? Int, 0, "\(refused)")
        XCTAssertTrue((data["stderr"] as? String ?? "").contains("Operation not permitted"), "\(refused)")
        let warnings = (refused["meta"] as? [String: Any])?["warnings"] as? [String] ?? []
        XCTAssertTrue(warnings.contains { $0.contains("\(port)") && $0.contains("sandbox") }, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("47321") }, "the floor is named too: \(warnings)")

        let allowed = envelope(await tool.handle(context: context([]), args: ["command": command]).outputJSON)
        XCTAssertEqual((allowed["data"] as? [String: Any])?["exit_code"] as? Int, 0, "\(allowed)")
        XCTAssertTrue((allowed["meta"] as? [String: Any])?["warnings"] == nil
            || ((allowed["meta"] as? [String: Any])?["warnings"] as? [String] ?? []).isEmpty, "\(allowed)")
    }

    /// A role's command may signal only processes of its own sandbox: SIGUSR1 to a user's `node`
    /// opens its inspector and SIGQUIT plus an attach file loads an agent into a JVM — code outside
    /// the sandbox either way (review 2026-11-08) — so the profile allows `(target same-sandbox)`
    /// only. Measured live: the command's own child is reachable; a process outside the sandbox,
    /// and another `sandbox-exec` instance with this very profile, are not. The last is the cost —
    /// a later `bash` call cannot `kill` what an earlier one started, which is why `bash_output`
    /// stops a background command's whole group.
    func testProfile_signalsReachOnlyTheCommandsOwnSandbox_live() throws {
        guard FileManager.default.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let work = URL(fileURLWithPath: "/tmp/nanoteams-sb-signal").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(workFolderRoot: work)
        XCTAssertTrue(profile.contains("(allow signal (target same-sandbox))\n"), "the profile's rule")
        XCTAssertFalse(profile.contains("(allow signal)\n"), "and not the broad one")

        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/bin/sleep")
        outside.arguments = ["30"]
        try outside.run()
        defer { if outside.isRunning { outside.terminate() } }
        let otherInstance = Process()
        otherInstance.executableURL = URL(fileURLWithPath: BashConstants.sandboxExecPath)
        otherInstance.arguments = ["-p", profile, "/bin/sleep", "30"]
        try otherInstance.run()
        defer { if otherInstance.isRunning { otherInstance.terminate() } }
        Thread.sleep(forTimeInterval: 0.3)

        func probe(_ command: String) throws -> String {
            let (exe, args) = SeatbeltSandbox.wrap(profile: profile, shell: "/bin/zsh", command: command)
            return try ProcessRunner.run(executable: exe, arguments: args, currentDirectory: nil, timeout: 20).stdout
        }
        XCTAssertFalse(try probe("kill -0 \(outside.processIdentifier) 2>&1 && echo REACHED").contains("REACHED"),
                       "a process outside the sandbox")
        XCTAssertFalse(try probe("kill -0 \(otherInstance.processIdentifier) 2>&1 && echo REACHED").contains("REACHED"),
                       "another sandbox-exec instance with the same profile")
        XCTAssertTrue(try probe("sleep 30 & c=$!; kill $c 2>&1 && echo REACHED; wait $c 2>/dev/null").contains("REACHED"),
                      "the command's own child")
    }

    /// The decision table of the new warning: sandboxed, outside the planning phase, failed,
    /// and said `Operation not permitted` — all four, or nothing.
    func testSandboxDenialWarnings_onlyForASandboxedFailureThatSaidSo() {
        let eperm = "x: Operation not permitted"
        XCTAssertEqual(BashTool.sandboxDenialWarnings(
            ranSandboxed: true, isPlanningPhase: false, exitCode: 1, stderr: eperm, guardedPorts: [3845, 47321]).count, 1)
        XCTAssertTrue(BashTool.sandboxDenialWarnings(
            ranSandboxed: true, isPlanningPhase: false, exitCode: 1, stderr: eperm, guardedPorts: [3845, 47321])[0]
            .contains("3845, 47321"))
        XCTAssertEqual(BashTool.sandboxDenialWarnings(
            ranSandboxed: false, isPlanningPhase: false, exitCode: 1, stderr: eperm, guardedPorts: [47321]), [])
        XCTAssertEqual(BashTool.sandboxDenialWarnings(
            ranSandboxed: true, isPlanningPhase: true, exitCode: 1, stderr: eperm, guardedPorts: [47321]), [],
            "the planning phase has its own warning")
        XCTAssertEqual(BashTool.sandboxDenialWarnings(
            ranSandboxed: true, isPlanningPhase: false, exitCode: 0, stderr: eperm, guardedPorts: [47321]), [])
        XCTAssertEqual(BashTool.sandboxDenialWarnings(
            ranSandboxed: true, isPlanningPhase: false, exitCode: 1, stderr: "No such file", guardedPorts: [47321]), [])
    }

    /// D-M19 S8: a refusal on `.nanoteams/internal` gets its own warning, which names the way
    /// around it; a refusal elsewhere keeps the generic one; both kinds in one stderr get both,
    /// internal first. The same four preconditions hold for the new one.
    func testSandboxDenialWarnings_internalRefusal_getsItsOwnWarning() {
        let inside = "find: ./.nanoteams/internal: Operation not permitted"
        let absolute = "grep: /Users/x/work/.nanoteams/internal: Operation not permitted"
        let outside = "touch: /etc/x: Operation not permitted"
        func warnings(_ stderr: String, exit: Int32 = 1, sandboxed: Bool = true, planning: Bool = false) -> [String] {
            BashTool.sandboxDenialWarnings(
                ranSandboxed: sandboxed, isPlanningPhase: planning, exitCode: exit, stderr: stderr,
                guardedPorts: [47321])
        }
        XCTAssertEqual(warnings(inside), [BashTool.internalDenialWarning])
        XCTAssertEqual(warnings(absolute), [BashTool.internalDenialWarning])
        XCTAssertEqual(warnings("./src/a:1:x\n" + inside + "\n" + inside), [BashTool.internalDenialWarning],
                       "one warning however many lines")
        let both = warnings(outside + "\n" + inside)
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both.first, BashTool.internalDenialWarning)
        XCTAssertTrue(both[1].contains("47321"), "the generic warning still names the ports")
        XCTAssertEqual(warnings(outside).count, 1)
        XCTAssertFalse(warnings(outside).contains(BashTool.internalDenialWarning))
        XCTAssertEqual(warnings(inside, exit: 0), [])
        XCTAssertEqual(warnings(inside, sandboxed: false), [])
        XCTAssertEqual(warnings(inside, planning: true), [])
        XCTAssertEqual(warnings("./.nanoteams/internal: No such file or directory"), [],
                       "naming the directory is not a refusal")
        XCTAssertTrue(BashTool.internalDenialWarning.contains("--exclude-dir=.nanoteams"))
        XCTAssertTrue(BashTool.internalDenialWarning.contains("-prune"))
    }

    /// A background command records the ports its profile reserved; one launched before a port
    /// joined the list is stopped when that port is reserved, and `bash_output` says why — while
    /// a command launched after it, by a batch that still read the old list, gets the port all
    /// the same (`LoopbackPortReservations.ports`) and is left alone.
    func testBashTool_backgroundCommandLaunchedBeforeAReservationIsStopped_live() async throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let registry = BackgroundBashRegistry.shared
        let reservations = LoopbackPortReservations.shared
        reservations._testForget()
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-sbbg-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer {
            registry.terminate(taskID: 4401)
            reservations._testForget()
            try? fm.removeItem(at: work)
        }
        let (early, late) = try twoFreeLoopbackPorts()
        let tool = sandboxedBashTool(work)
        let context = ToolExecutionContext(workFolderRoot: work, taskID: 4401, runID: 0, roleID: "r", guardedLoopbackPorts: [early])
        func startBackground() async throws -> String {
            let started = envelope(await tool.handle(
                context: context, args: ["command": "sleep 30", "run_in_background": true]).outputJSON)
            return try XCTUnwrap((started["data"] as? [String: Any])?["command_id"] as? String, "\(started)")
        }
        let before = try await startBackground()

        XCTAssertEqual(reservations.reserve([late]), [before])
        XCTAssertTrue(reservations.ports.contains(late))
        // Launched after the reservation by a batch whose list predates it: the port is added anyway.
        let after = try await startBackground()
        XCTAssertEqual(reservations.reserve([late]), [], "the later command reserves the port already")

        var read = try XCTUnwrap(registry.read(commandID: before))
        for _ in 0..<100 where read.running {
            try await Task.sleep(nanoseconds: 50_000_000)
            read = try XCTUnwrap(registry.read(commandID: before))
        }
        XCTAssertFalse(read.running, "stopped with SIGKILL")
        XCTAssertEqual(read.exitCode, SIGKILL)
        XCTAssertTrue(read.stopReason?.contains("\(late)") == true, "\(String(describing: read.stopReason))")
        XCTAssertTrue(registry.read(commandID: after)?.running == true, "the later command keeps running")

        let output = envelope(await BashOutputTool().handle(context: context, args: ["command_id": before]).outputJSON)
        let data = output["data"] as? [String: Any] ?? [:]
        XCTAssertEqual(data["status"] as? String, "stopped", "\(output)")
        XCTAssertTrue((data["stop_reason"] as? String ?? "").contains("\(late)"), "\(output)")
    }

    /// The External Agents listener reserves its port BEFORE it binds: a role's background command
    /// launched earlier is listening on `[::1]` of that very port, so a bind made first would fail
    /// on that address family — or, had the listener taken IPv4 only, a client dialling
    /// `localhost` would reach the squatter first. The stale command is stopped, the bind lands on
    /// both families, and the port is reserved for every later command.
    @MainActor
    func testStartingTheExternalAgentsListenerStopsASquatterBeforeItBinds_live() async throws {
        guard FileManager.default.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let registry = BackgroundBashRegistry.shared
        let reservations = LoopbackPortReservations.shared
        reservations._testForget()
        let (port, _) = try twoFreeLoopbackPorts()
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-sbsquat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let squat = """
        /usr/bin/python3 -I -c "import socket,time; s=socket.socket(socket.AF_INET6); s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1); s.bind(('::1', \(port))); s.listen(1); print('SQUATTING', flush=True); time.sleep(30)"
        """
        let profileWithoutThePort = SeatbeltSandbox.profile(workFolderRoot: work, guardedLoopbackPorts: [])
        let stale = try registry.start(
            command: squat, directory: work,
            confinement: .init(profile: profileWithoutThePort, guardedPorts: Set(SeatbeltSandbox.effectiveGuardedPorts([]))),
            taskID: 4402)
        let orchestrator = TestOrchestrator.make()
        defer {
            registry.terminate(taskID: 4402)
            reservations._testForget()
            MCPEndpointPolicy.setConfiguredHostedServerPort(HostedMCPConstants.defaultPort)
            try? FileManager.default.removeItem(at: work)
        }
        var output = ""
        for _ in 0..<100 where !output.contains("SQUATTING") {
            output += registry.read(commandID: stale)?.newOutput ?? ""
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(output.contains("SQUATTING"), "precondition: the squatter holds [::1]:\(port) — \(output)")

        let bound = try await orchestrator.startHostedMCPServer(port: port)
        XCTAssertEqual(bound, port, "the bind lands on both families once the squatter is gone")
        XCTAssertTrue(registry.read(commandID: stale)?.stopReason?.contains("\(port)") == true)
        XCTAssertTrue(reservations.ports.contains(port))
        await orchestrator.stopHostedMCPServer()
    }

    /// Every request to an LLM server reserves the server's port on this machine before its first
    /// byte goes out — the seam every client passes (`URLRequest.applyLMStudioBearer`), token or
    /// not — and a background command launched before is stopped. A remote server reserves
    /// nothing. Until 2026-11-08 only a step's own requests reserved it, at step entry.
    func testEveryLLMRequestReservesItsServerPort_live() throws {
        guard FileManager.default.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let registry = BackgroundBashRegistry.shared
        let reservations = LoopbackPortReservations.shared
        reservations._testForget()
        let (port, _) = try twoFreeLoopbackPorts()
        let stale = try registry.start(
            command: "sleep 30", directory: FileManager.default.temporaryDirectory,
            confinement: .init(profile: "(version 1)\n(allow default)", guardedPorts: [47321]), taskID: 4403)
        defer {
            registry.terminate(taskID: 4403)
            reservations._testForget()
        }

        var remote = URLRequest(url: try XCTUnwrap(URL(string: "https://llm.example.com:\(port)/v1/models")))
        remote.applyLMStudioBearer(literal: "token")
        XCTAssertFalse(reservations.ports.contains(port), "a remote server reserves nothing")
        XCTAssertNil(registry.read(commandID: stale)?.stopReason)

        var local = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/v1/models")))
        local.applyLMStudioBearer(literal: nil)
        XCTAssertTrue(reservations.ports.contains(port), "with no token too: the prompt is the payload")
        XCTAssertTrue(registry.read(commandID: stale)?.stopReason?.contains("\(port)") == true)
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"), "the header logic is unchanged")
        local.applyLMStudioBearer(literal: "  t  ")
        XCTAssertEqual(local.value(forHTTPHeaderField: "Authorization"), "Bearer t")
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

    /// Re-aimed 2026-08-25 (CLAUDE.md #104, #89). This asserted that the work path was
    /// ABSENT from the profile, which was a proxy for "not writable" and stopped being
    /// one the moment the work folder started being explicitly DENIED: `(subpath "…")`
    /// occurs in both allow and deny clauses, so the old needle could not tell the
    /// grant being withheld from the grant being revoked, and it read the stronger
    /// profile as a regression.
    ///
    /// The fixture is the whole point and must stay under `/tmp`: it canonicalizes
    /// under `/private/tmp`, so with `tempWrite` on by default the temp grant covered
    /// it and the work folder was writable with its own grant switched OFF. The
    /// neighbouring assertion's comment already knew the two paths collide — it worked
    /// around the collision for the temp half and left the work half reading the
    /// collision as success.
    ///
    /// RED: drop the `workCoveredByTemp` term from the narrow-write deny → no deny
    /// clause names the work folder and the "explicitly denied" assertion fails.
    func testProfile_workFolderWriteOff_deniesWorkButKeepsTemp() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-perm-nowork").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(workFolderWrite: false))

        XCTAssertFalse(
            profile.contains("(allow file-write*\n    (subpath \"\(work.path)\")"),
            "work folder must not carry a WRITE GRANT when its write grant is off")
        XCTAssertTrue(
            profile.contains("(deny file-write*") && profile.contains("(subpath \"\(work.path)\")"),
            "work folder lives under /private/tmp, so the temp grant reaches it — the "
                + "profile must revoke it explicitly, not merely decline to grant it:\n\(profile)")
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

    /// Credential reads granted: the stores' read deny goes — and the one read deny left is
    /// the agent token locations', which no grant opens (#375, review 2026-11-08: the
    /// toggle's row names `~/.ssh, ~/.aws, Keychain, .netrc`, and a person granting those was
    /// granting every agent token with them).
    func testProfile_credentialReadAllowed_omitsReadDeny_butNotTheTokenDeny() throws {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-perm-credread")
        let home = kernelPath(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
        let tokens = SeatbeltSandbox.externalAgentTokenLocations(home: home)
        for permissions in [BashSandboxPermissions(credentialRead: true),
                            BashSandboxPermissions(credentialRead: true, everythingElseRead: false)] {
            let profile = SeatbeltSandbox.profile(workFolderRoot: work, permissions: permissions)
            let readDenies = profile.components(separatedBy: "(deny file-read*").count - 1
            XCTAssertEqual(readDenies, 1, "only the token deny is left:\n\(profile)")
            let start = try XCTUnwrap(profile.range(of: "(deny file-read* file-write*"), profile)
            let rest = profile[start.lowerBound...]
            let tokenDeny = rest.range(of: "\n(deny network").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            XCTAssertFalse(tokenDeny.contains(".ssh\""), "the stores' deny is dropped as granted: \(tokenDeny)")
            for location in tokens.subpaths {
                XCTAssertTrue(profile.contains("(subpath \"\(location)\")"), location)
            }
            for location in tokens.literals {
                XCTAssertTrue(profile.contains("(literal \"\(location)\")"), location)
            }
        }
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
            // The planning-phase profile: every write scope off. Must compile and RUN under the
            // real binary like every other variant — this is the profile `BashTool` builds for
            // the whole phase, so a shell that cannot start under it would take the feature down.
            BashSandboxPermissions().withWritesDisabled(),
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
    ///
    /// The fixture sits under HOME, which until 2026-08-25 was a workaround — the
    /// temp-dir allow covered a work folder under `$TMPDIR` and this test would have
    /// failed there, which is the defect it was quietly stepping around. That is fixed
    /// (`workCoveredByTemp`), so HOME is now just a second layout worth covering, and
    /// the temp layout has its own live pin in `SeatbeltCanonicalPathCoverageTests`.
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
        XCTAssertTrue(SeatbeltSandbox.isWrapperDiagnostic(
            exitCode: 1, stderr: "sandbox-exec: execvp() failed"))
        XCTAssertTrue(SeatbeltSandbox.isWrapperDiagnostic(
            exitCode: 65, stderr: "sandbox_apply: Operation not permitted"))
        // A normal non-zero exit (the command itself failed) is NOT a sandbox failure.
        XCTAssertFalse(SeatbeltSandbox.isWrapperDiagnostic(
            exitCode: 1, stderr: "ls: no such file or directory"))
        // exit 0 is never a sandbox failure.
        XCTAssertFalse(SeatbeltSandbox.isWrapperDiagnostic(exitCode: 0, stderr: ""))
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

    // MARK: - What a launch verdict obliges (D-7)

    /// The `reportNothingRan` arm is the reason this decision was extracted: through `BashTool`
    /// it is unreachable, because the profile is built internally and NO `BashSandboxPermissions`
    /// value can make `sandbox-exec` refuse it (measured — `SeatbeltSandbox.profile` always
    /// emits `(allow process*)`, so even a starved profile lands in `.confinedBeforeStart`).
    /// It is also the arm whose failure is worst: a command reported as "not run" that in fact
    /// ran unconfined, or the reverse.
    ///
    /// RED: drop `!fallbackAllowed` from the rule → a rejection with the fallback ON reports
    /// "nothing ran" instead of retrying, and the retry assertion fails.
    func testResponse_wrapperRejectedWithNoFallback_meansNothingRan() {
        XCTAssertEqual(
            SeatbeltSandbox.response(
                ranSandboxed: true, launch: .wrapperRejected, fallbackAllowed: false),
            .reportNothingRan)
    }

    func testResponse_wrapperRejectedWithFallback_licensesTheUnconfinedRetry() {
        XCTAssertEqual(
            SeatbeltSandbox.response(
                ranSandboxed: true, launch: .wrapperRejected, fallbackAllowed: true),
            .retryUnconfined)
    }

    /// The confinement doing its job is NOT a wrapper fault. Retrying it unconfined would defeat
    /// the profile the user asked for, and reporting "nothing ran" would hide a real result
    /// (exit 134, no output) behind an environment error.
    ///
    /// RED: widen the rule to `launch != .childRan` → both assertions here fail.
    func testResponse_confinedBeforeStart_isNeverRetriedAndNeverCalledNeverRun() {
        for fallback in [true, false] {
            XCTAssertEqual(
                SeatbeltSandbox.response(
                    ranSandboxed: true, launch: .confinedBeforeStart, fallbackAllowed: fallback),
                .reportTheResult,
                "fallbackAllowed: \(fallback)")
        }
    }

    /// `ranSandboxed: false` is the POST-FALLBACK path: the command demonstrably ran, so the
    /// stale verdict from the first attempt must not speak for the second. Without this guard a
    /// successful unconfined retry would report itself as never having run.
    ///
    /// RED: drop `ranSandboxed` from the rule → this returns `.retryUnconfined`, i.e. an
    /// infinite retry of a run that already happened.
    func testResponse_unsandboxedRun_carriesNoVerdictFromTheSandboxedAttempt() {
        XCTAssertEqual(
            SeatbeltSandbox.response(
                ranSandboxed: false, launch: .wrapperRejected, fallbackAllowed: true),
            .reportTheResult)
    }

    func testResponse_childRan_reportsTheResult() {
        XCTAssertEqual(
            SeatbeltSandbox.response(
                ranSandboxed: true, launch: .childRan, fallbackAllowed: true),
            .reportTheResult)
    }

    // MARK: - Hosted MCP External Agents Hardening (§10.2 п.3–4, Ш19)

    func testExternalAgentsPort_sandboxExecBlocksIPv4AndIPv6WithEPERMAndAllowsNeighborPortWithECONNREFUSED() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-sb-externalagents-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let blockedPort: UInt16 = 47321
        let neighborPort: UInt16 = 47322
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(),
            guardedLoopbackPorts: [blockedPort]
        )

        // 1. Profile compiles and runs cleanly (exit code 0)
        let (compileExe, compileArgs) = SeatbeltSandbox.wrap(
            profile: profile,
            shell: "/bin/zsh",
            command: "echo EXTERNAL_AGENTS_PROFILE_OK"
        )
        let compileResult = try ProcessRunner.run(
            executable: compileExe,
            arguments: compileArgs,
            currentDirectory: work,
            timeout: 20
        )
        XCTAssertEqual(compileResult.exitCode, 0, "stderr=\(compileResult.stderr)")
        XCTAssertTrue(compileResult.stdout.contains("EXTERNAL_AGENTS_PROFILE_OK"))

        // 2. Outbound TCP to 127.0.0.1:blockedPort and [::1]:blockedPort fails with EPERM (errno 1),
        //    while 127.0.0.1:neighborPort and [::1]:neighborPort reach the kernel loopback stack (ECONNREFUSED, errno 61).
        let perlProbe = """
        /usr/bin/perl -MSocket=:all -e '
        sub probe_v4 {
            my ($port) = @_;
            socket(my $s, PF_INET, SOCK_STREAM, getprotobyname("tcp")) or return -1;
            my $rc = connect($s, pack_sockaddr_in($port, inet_aton("127.0.0.1")));
            my $err = $rc ? 0 : ($! + 0);
            close($s);
            return $err;
        }
        sub probe_v6 {
            my ($port) = @_;
            socket(my $s, PF_INET6, SOCK_STREAM, getprotobyname("tcp")) or return -1;
            my $rc = connect($s, pack_sockaddr_in6($port, inet_pton(AF_INET6, "::1")));
            my $err = $rc ? 0 : ($! + 0);
            close($s);
            return $err;
        }
        print "v4_blocked=" . probe_v4(\(blockedPort)) . "\\n";
        print "v6_blocked=" . probe_v6(\(blockedPort)) . "\\n";
        print "v4_neighbor=" . probe_v4(\(neighborPort)) . "\\n";
        print "v6_neighbor=" . probe_v6(\(neighborPort)) . "\\n";
        '
        """
        let (probeExe, probeArgs) = SeatbeltSandbox.wrap(
            profile: profile,
            shell: "/bin/zsh",
            command: perlProbe
        )
        let probeResult = try ProcessRunner.run(
            executable: probeExe,
            arguments: probeArgs,
            currentDirectory: work,
            timeout: 20
        )
        XCTAssertEqual(probeResult.exitCode, 0, "stderr=\(probeResult.stderr)")
        XCTAssertTrue(
            probeResult.stdout.contains("v4_blocked=\(EPERM)"),
            "127.0.0.1:\(blockedPort) must be blocked by Seatbelt with EPERM (1), got: \(probeResult.stdout)"
        )
        XCTAssertTrue(
            probeResult.stdout.contains("v6_blocked=\(EPERM)"),
            "[::1]:\(blockedPort) must be blocked by Seatbelt with EPERM (1), got: \(probeResult.stdout)"
        )
        XCTAssertTrue(
            probeResult.stdout.contains("v4_neighbor=\(ECONNREFUSED)"),
            "Neighbor port \(neighborPort) on 127.0.0.1 must NOT be blocked by Seatbelt (expected ECONNREFUSED 61), got: \(probeResult.stdout)"
        )
        XCTAssertTrue(
            probeResult.stdout.contains("v6_neighbor=\(ECONNREFUSED)"),
            "Neighbor port \(neighborPort) on [::1] must NOT be blocked by Seatbelt (expected ECONNREFUSED 61), got: \(probeResult.stdout)"
        )
    }

    @MainActor
    func testExternalAgentsPort_rebuildsProfileOnPortChangeAndAddsAgentCredentialSubpaths() {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-sb-portchange").resolvingSymlinksInPath()
        let home = kernelPath(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)

        let disabledProfile = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(),
            guardedLoopbackPorts: []
        )
        // No server, no configured port handed in: the default port is still guarded — a role
        // listening there would collect the bearer of every client still configured for it (#375).
        XCTAssertTrue(disabledProfile.contains("(deny network-bind (local tcp \"*:47321\"))"), disabledProfile)
        // On EVERY host since 2026-11-08: `localhost:` alone let `[::ffff:0.0.0.0]:47321` reach the
        // listener on 127.0.0.1 (measured). The price is a role's `curl https://host:47321/…`.
        XCTAssertTrue(disabledProfile.contains("(deny network-outbound (remote tcp \"*:47321\"))"), disabledProfile)
        XCTAssertFalse(disabledProfile.contains("(remote tcp \"localhost:47321\")"), disabledProfile)
        // The client folders hold tokens with the switch off too, and a step started with it off
        // keeps that profile after it is turned on (#375): denied in every profile since 2026-11-08.
        XCTAssertTrue(disabledProfile.contains("(subpath \"\(home)/.claude.json\")"))
        XCTAssertTrue(disabledProfile.contains("(subpath \"\(home)/.codex\")"))

        let portAProfile = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(),
            guardedLoopbackPorts: [47321]
        )
        XCTAssertTrue(portAProfile.contains("(deny network-outbound (remote tcp \"*:47321\"))"))
        // The WHOLE list, so dropping one client's config location fails here: the loop below
        // only proves the profile embeds what the list holds.
        let expectedAgentConfigPaths = [
            "\(home)/.claude.json",
            "\(home)/.claude",
            "\(home)/.codex",
            "\(home)/Library/Application Support/Claude",
            "\(home)/.cursor",
            "\(home)/.gemini",
            "\(home)/Library/Application Support/Code/User",
            "\(home)/.vscode",
        ]
        XCTAssertEqual(SeatbeltSandbox.externalAgentCredentialSubpaths(home: home), expectedAgentConfigPaths)
        // The profile denies each one as written AND where it really is: a dotfiles manager links
        // these very folders, and Seatbelt matches the path the kernel resolved (#376).
        XCTAssertEqual(
            SeatbeltSandbox.bothSpellings(["\(home)/.claude"]).count,
            FileManager.default.fileExists(atPath: "\(home)/.claude")
                && (try? FileManager.default.destinationOfSymbolicLink(atPath: "\(home)/.claude")) != nil
                ? 2 : 1,
            "a linked client folder contributes both spellings, an ordinary one just itself")
        for expectedSubpath in expectedAgentConfigPaths {
            XCTAssertTrue(
                portAProfile.contains("(subpath \"\(expectedSubpath)\")"),
                "External Agents profile must protect \(expectedSubpath) in credentialSubpaths"
            )
        }

        // Changing the port rebuilds the profile with the new port and removes the old port
        let portBProfile = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(),
            guardedLoopbackPorts: [48999]
        )
        XCTAssertTrue(portBProfile.contains("(deny network-outbound (remote tcp \"*:48999\"))"))
        XCTAssertTrue(portBProfile.contains("(deny network-bind (local tcp \"*:48999\"))"))
        // The default stays guarded beside the configured one: clients set up before the port
        // moved still dial it.
        XCTAssertTrue(portBProfile.contains("(deny network-bind (local tcp \"*:47321\"))"))
        XCTAssertEqual(SeatbeltSandbox.guardedExternalAgentsPorts(48999), [47321, 48999])
        XCTAssertEqual(SeatbeltSandbox.guardedExternalAgentsPorts(47321), [47321])
        XCTAssertEqual(SeatbeltSandbox.guardedExternalAgentsPorts(nil), [47321])

        // Verify orchestrator seatbeltHostedMCPPort tracks enable/port changes
        let orchestrator = TestOrchestrator.make()
        // Guarded with External Agents off too (#375): the port the server would use.
        XCTAssertEqual(orchestrator.seatbeltHostedMCPPort, orchestrator.effectiveHostedMCPPort)
        orchestrator.configuration.externalAgentsEnabled = true
        orchestrator.configuration.externalAgentsPort = 47321
        XCTAssertEqual(orchestrator.seatbeltHostedMCPPort, 47321)
        // And it reaches every batch's list, which is what the profile is built from.
        XCTAssertTrue(orchestrator.seatbeltGuardedLoopbackPorts.contains(47321))
        orchestrator.configuration.externalAgentsPort = 48999
        XCTAssertEqual(orchestrator.seatbeltHostedMCPPort, 48999)
        XCTAssertTrue(orchestrator.seatbeltGuardedLoopbackPorts.contains(48999))
        XCTAssertTrue(orchestrator.seatbeltGuardedLoopbackPorts.contains(47321), "the default stays guarded")
        orchestrator.configuration.externalAgentsEnabled = false
        XCTAssertEqual(orchestrator.seatbeltHostedMCPPort, 48999, "switching off does not unguard the port")
    }

    /// Every reserved port gets the External Agents port's two clauses, each port once, after the
    /// `(allow network*)` they override (SBPL is last-match-wins) — and the default External Agents
    /// port whatever the list holds.
    func testProfile_guardsEveryReservedLoopbackPort() throws {
        let work = URL(fileURLWithPath: "/tmp/nanoteams-sb-mcpports").resolvingSymlinksInPath()
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(),
            guardedLoopbackPorts: [8765, 3845, 48999, 48999, 0, 1234, 443, 80])
        for port in [1234, 3845, 8765, 47321, 48999] {
            XCTAssertTrue(profile.contains("(deny network-outbound (remote tcp \"*:\(port)\"))"), "\(port)")
            XCTAssertTrue(profile.contains("(deny network-bind (local tcp \"*:\(port)\"))"), "\(port)")
            XCTAssertFalse(profile.contains("(remote tcp \"localhost:\(port)\")"), "\(port)")
        }
        // The web's own ports keep `localhost`: `*:443` would cut a role off HTTPS everywhere.
        for port in [80, 443] {
            XCTAssertTrue(profile.contains("(deny network-outbound (remote tcp \"localhost:\(port)\"))"), "\(port)")
            XCTAssertFalse(profile.contains("(remote tcp \"*:\(port)\")"), "\(port)")
            XCTAssertTrue(profile.contains("(deny network-bind (local tcp \"*:\(port)\"))"), "\(port)")
        }
        XCTAssertEqual(SeatbeltSandbox.outboundDenyHost(for: 443), "localhost")
        XCTAssertEqual(SeatbeltSandbox.outboundDenyHost(for: 80), "localhost")
        XCTAssertEqual(SeatbeltSandbox.outboundDenyHost(for: 8443), "*")
        XCTAssertEqual(SeatbeltSandbox.outboundDenyHost(for: 47321), "*")
        // A port listed twice is written once; 0 names no port.
        XCTAssertEqual(profile.components(separatedBy: "(local tcp \"*:48999\")").count - 1, 1, profile)
        XCTAssertFalse(profile.contains("localhost:0\""), profile)
        let allowNetwork = try XCTUnwrap(profile.range(of: "(allow network*)"))
        let mcpDeny = try XCTUnwrap(profile.range(of: "(remote tcp \"*:3845\")"))
        XCTAssertLessThan(allowNetwork.lowerBound, mcpDeny.lowerBound, "the deny must come after the allow")

        let empty = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [])
        XCTAssertTrue(empty.contains("(deny network-bind (local tcp \"*:47321\"))"), "the floor stays")
        XCTAssertFalse(empty.contains("localhost:8765"), empty)
        XCTAssertEqual(SeatbeltSandbox.profile(workFolderRoot: work), empty, "the short form is the empty list")
    }

    func testGuardedLoopbackPorts_mergeTheThreeSourcesAndTheFloor() {
        XCTAssertEqual(
            SeatbeltSandbox.guardedLoopbackPorts(
                externalAgentsPort: 48999, mcpServerPorts: [8765, 3845, 48999, 0], llmServerPorts: [1234, 8765]),
            [1234, 3845, 8765, 47321, 48999])
        // Nothing configured: the default External Agents port alone, as before.
        XCTAssertEqual(
            SeatbeltSandbox.guardedLoopbackPorts(externalAgentsPort: nil, mcpServerPorts: [], llmServerPorts: []),
            [47321])
        XCTAssertEqual(SeatbeltSandbox.effectiveGuardedPorts([]), [47321])
        XCTAssertEqual(SeatbeltSandbox.effectiveGuardedPorts([0, 9, 9]), [9, 47321])
    }

    private func mcpServer(_ url: String, enabled: Bool = true) throws -> MCPServerConfig {
        MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("srv")),
            displayName: "Server",
            transport: .http(MCPHTTPConfig(urlString: url)),
            isEnabled: enabled)
    }

    /// The interface list `loopbackPort(of:)` is judged against in these tests: this Mac's LAN
    /// address, so "the Mac's own address" is exercised without depending on the host running
    /// the suite.
    private let lanInterfaces: Set<[UInt8]> = [[192, 168, 1, 5]]

    func testMCPServerPort_loopbackHostsYieldTheirPort() throws {
        func port(_ url: String) throws -> UInt16? {
            SeatbeltSandbox.mcpServerPort(of: try mcpServer(url), interfaceAddresses: lanInterfaces)
        }
        XCTAssertEqual(try port("http://127.0.0.1:8765/mcp"), 8765)
        XCTAssertEqual(try port("http://localhost:3845/mcp"), 3845)
        XCTAssertEqual(try port("http://[::1]:9000/mcp"), 9000)
        XCTAssertEqual(try port("http://LOCALHOST:7001/mcp"), 7001)
        XCTAssertEqual(try port("http://127.0.0.2:7000/mcp"), 7000)
        // The spellings the transport dials over https that `isLoopback` alone did not read
        // (review 2026-11-08) — each one IS dialled (`MCPEndpointPolicy.validate` accepts it).
        for url in [
            "https://[0:0:0:0:0:0:0:1]:8443/mcp", "https://[::0001]:8443/mcp", "https://[::ffff:127.0.0.1]:8443/mcp",
            "https://[::ffff:7f00:1]:8443/mcp", "https://[::127.0.0.1]:8443/mcp", "https://[::1%25lo0]:8443/mcp",
            "https://localhost.:8443/mcp",
        ] {
            XCTAssertNotNil(MCPEndpointPolicy.allows(url) ? url : nil, "the transport dials \(url)")
            XCTAssertEqual(try port(url), 8443, url)
        }
    }

    func testMCPServerPort_missingPortIsTheSchemeDefault() throws {
        XCTAssertEqual(SeatbeltSandbox.mcpServerPort(of: try mcpServer("http://localhost/mcp")), 80)
        XCTAssertEqual(SeatbeltSandbox.mcpServerPort(of: try mcpServer("https://localhost/mcp")), 443)
        XCTAssertEqual(SeatbeltSandbox.mcpServerPort(of: try mcpServer("http://localhost:/mcp")), 80)
    }

    /// What the transport would refuse guards nothing — nobody dials it — so `0.0.0.0` (refused
    /// as 0.0.0.0/8) and a URL on the External Agents port (a self-connection) yield no MCP port;
    /// the External Agents port is guarded on its own account.
    func testMCPServerPort_remoteRefusedAndUnreadableAddressesYieldNothing() throws {
        // The self-connection rule reads the process-wide External Agents port, which another suite
        // in this process may have moved to the port its listener bound.
        MCPEndpointPolicy.setConfiguredHostedServerPort(47321)
        defer { MCPEndpointPolicy.setConfiguredHostedServerPort(HostedMCPConstants.defaultPort) }
        for url in [
            "https://mcp.example.com:8765/mcp", "https://192.168.1.20:8765/mcp", "", "not a url",
            "ftp://localhost:21", "http://localhost:0/mcp", "http://localhost:70000/mcp",
            "http://localhost:99999999999999999999/mcp", "http://0.0.0.0:5000/mcp", "http://127.1:5000/mcp",
            "http://localhost:47321/mcp",
        ] {
            XCTAssertNil(SeatbeltSandbox.mcpServerPort(of: try mcpServer(url)), url)
        }
        let stdio = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("local")),
            displayName: "Local",
            transport: .unsupported(kind: "stdio", raw: [:]),
            isEnabled: true)
        XCTAssertNil(SeatbeltSandbox.mcpServerPort(of: stdio))
    }

    /// Every configured server, switched on or off: switching one on dials it at once.
    func testMCPServerPorts_coverEveryConfiguredServer_sortedAndUnique() throws {
        let ports = SeatbeltSandbox.mcpServerPorts(of: [
            try mcpServer("http://127.0.0.1:8765/mcp"),
            try mcpServer("http://127.0.0.1:3845/mcp", enabled: false),
            try mcpServer("http://localhost:8765/other"),
            try mcpServer("https://mcp.example.com/mcp"),
        ])
        XCTAssertEqual(ports, [3845, 8765])
        XCTAssertEqual(SeatbeltSandbox.mcpServerPorts(of: []), [])
    }

    /// An LLM server is not policy-checked, so every address that lands on this machine counts:
    /// loopback in any spelling, the unspecified addresses a person copies from a server's
    /// "listening on" line, and the Mac's own LAN address.
    func testLLMServerPorts_everyAddressThatLandsOnThisMachine() {
        XCTAssertEqual(
            SeatbeltSandbox.llmServerPorts(of: [
                "http://127.0.0.1:1234", "  http://localhost:11434  ", "http://0.0.0.0:8080/v1",
                "http://[::]:8081", "http://127.1:8082", "http://192.168.1.5:8083", "https://localhost",
                "http://[::ffff:127.0.0.1]:8084",
            ], interfaceAddresses: lanInterfaces),
            [443, 1234, 8080, 8081, 8082, 8083, 8084, 11434])
        XCTAssertEqual(
            SeatbeltSandbox.llmServerPorts(of: [
                "https://api.example.com:1234", "http://192.168.1.6:1234", "", "   ", "not a url",
                "http://localhost:0", "http://localhost:99999999999999999999", "file:///tmp/x",
            ], interfaceAddresses: lanInterfaces),
            [])
    }

    /// A port written that `URL` cannot read is not the default port: nothing dials `:80` for it.
    /// A port not written is the scheme's default — for a bracketed IPv6 literal too — and a
    /// scheme NanoTeams never dials over (`ftp`) names no port at all.
    func testLoopbackPort_anUnreadableWrittenPortIsNotTheDefault() throws {
        let overflow = try XCTUnwrap(URL(string: "http://localhost:99999999999999999999/x"))
        XCTAssertNil(overflow.port, "the premise: URL drops the port without failing")
        XCTAssertNil(SeatbeltSandbox.loopbackPort(of: overflow, interfaceAddresses: []))
        XCTAssertNil(SeatbeltSandbox.loopbackPort(
            of: try XCTUnwrap(URL(string: "http://[::1]:99999999999999999999/")), interfaceAddresses: []))
        XCTAssertEqual(SeatbeltSandbox.loopbackPort(
            of: try XCTUnwrap(URL(string: "http://user@localhost/x")), interfaceAddresses: []), 80)
        XCTAssertEqual(SeatbeltSandbox.loopbackPort(
            of: try XCTUnwrap(URL(string: "ws://localhost:1234/x")), interfaceAddresses: []), 1234)
        XCTAssertEqual(SeatbeltSandbox.loopbackPort(
            of: try XCTUnwrap(URL(string: "http://[::1]/x")), interfaceAddresses: []), 80, "an IPv6 literal, no port")
        XCTAssertEqual(SeatbeltSandbox.loopbackPort(
            of: try XCTUnwrap(URL(string: "wss://localhost/x")), interfaceAddresses: []), 443)
        XCTAssertEqual(SeatbeltSandbox.loopbackPort(
            of: try XCTUnwrap(URL(string: "http://localhost:/x")), interfaceAddresses: []), 80, "an empty port is none")
        XCTAssertNil(SeatbeltSandbox.loopbackPort(
            of: try XCTUnwrap(URL(string: "ftp://127.0.0.1:2121/")), interfaceAddresses: []), "not a scheme NanoTeams dials")
    }

    /// The orchestrator's list: the External Agents ports, every configured MCP server on this
    /// machine — read from the catalogue ON DISK, so a step started before the first folder open
    /// has built the MCP manager guards them too (review 2026-11-08) — and every LLM server a
    /// setting or a role names, the providers' defaults included.
    @MainActor
    func testOrchestrator_seatbeltGuardedLoopbackPorts_readsEverySourceWithoutAManager() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-guarded-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let catalogueStore = MCPServerCatalogueStore(directory: tempDir)
        try catalogueStore.upsert(MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("telegram")), displayName: "Telegram",
            transport: .http(MCPHTTPConfig(urlString: "http://127.0.0.1:8765/mcp")), isEnabled: false))
        try catalogueStore.upsert(MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("remote")), displayName: "Remote",
            transport: .http(MCPHTTPConfig(urlString: "https://mcp.example.com/mcp")), isEnabled: true))
        let scripted = ScriptedMCPEnvironment(trustDirectory: tempDir)
        let orchestrator = TestOrchestrator.make(
            mcpEnvironment: scripted.environment, mcpCatalogueStore: catalogueStore)
        XCTAssertNil(orchestrator.mcpServerManager, "the premise: no folder opened, no manager")

        XCTAssertEqual(orchestrator.seatbeltMCPServerPorts, [8765], "read from disk, switched off or not")

        orchestrator.configuration.llmBaseURLString = "http://127.0.0.1:4321"
        orchestrator.configuration.bashJudgeLLMOverride = LLMOverride(baseURLString: "http://localhost:5555")
        let llm = orchestrator.seatbeltLLMServerPorts
        XCTAssertTrue(llm.contains(4321), "the active server: \(llm)")
        XCTAssertTrue(llm.contains(5555), "a judge override, switched on or not: \(llm)")
        XCTAssertTrue(llm.contains(1234) && llm.contains(11434), "each provider's default: \(llm)")

        let all = orchestrator.seatbeltGuardedLoopbackPorts
        for port: UInt16 in [8765, 4321, 5555, 1234, 11434, 47321] {
            XCTAssertTrue(all.contains(port), "\(port) in \(all)")
        }
        XCTAssertEqual(all, all.sorted(), "sorted")
        XCTAssertEqual(Set(all).count, all.count, "each once")
    }

    /// A role's own LLM override in the open folder's teams counts: a step of that role sends
    /// its prompts there.
    @MainActor
    func testOrchestrator_seatbeltLLMServerPorts_includeARolesOverride() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-llm-role-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let orchestrator = TestOrchestrator.make()
        await orchestrator.openWorkFolder(folder)
        let teamID = try XCTUnwrap(orchestrator.snapshot?.projection.teams.first?.id)
        await orchestrator.mutateWorkFolder { projection in
            guard let index = projection.teams.firstIndex(where: { $0.id == teamID }),
                  var role = projection.teams[index].roles.first(where: { !$0.isSupervisor }) else { return }
            role.llmOverride = LLMOverride(baseURLString: "http://127.0.0.1:6123")
            projection.teams[index].updateRole(role)
        }
        XCTAssertTrue(orchestrator.seatbeltLLMServerPorts.contains(6123), "\(orchestrator.seatbeltLLMServerPorts)")

        // The generated roster of a task in memory counts too: the team a generated task runs
        // on is nowhere in the folder's teams, and its roles send their prompts to their own
        // overrides all the same.
        let created = await orchestrator.createTask(title: "Generated", supervisorTask: "Build it")
        let taskID = try XCTUnwrap(created)
        XCTAssertEqual(orchestrator.activeTask?.id, taskID, "precondition: the task is the active one")
        var roster = try XCTUnwrap(orchestrator.snapshot?.projection.teams.first)
        var generatedRole = try XCTUnwrap(roster.roles.first(where: { !$0.isSupervisor }))
        generatedRole.llmOverride = LLMOverride(baseURLString: "http://127.0.0.1:6124")
        roster.updateRole(generatedRole)
        await orchestrator.mutateTask(taskID: taskID) { $0.adoptGeneratedTeam(roster) }
        XCTAssertTrue(orchestrator.seatbeltLLMServerPorts.contains(6124), "a generated roster's override: \(orchestrator.seatbeltLLMServerPorts)")

        // And a task in the background — switched away from, held in memory — counts the same:
        // its roles keep sending prompts to their overrides while another task is on screen.
        let foreground = await orchestrator.createTask(title: "On screen", supervisorTask: "Look at this")
        XCTAssertEqual(orchestrator.activeTask?.id, try XCTUnwrap(foreground), "precondition: the generated task left the screen")
        XCTAssertNotNil(orchestrator.snapshot?.loadedTasks[taskID], "precondition: and is held in memory")
        XCTAssertTrue(orchestrator.seatbeltLLMServerPorts.contains(6124), "a background task's roster: \(orchestrator.seatbeltLLMServerPorts)")
        await orchestrator.closeProject()
    }

    @MainActor
    func testBashSecurityWarning_surfacesExplicitWarningWhenSandboxDisabledOrUnsandboxedFallbackEnabled() async throws {
        // 1. Default safe policy -> no warnings
        let safePolicy = BashPolicy(sandboxEnabled: true, allowUnsandboxedFallback: false)
        XCTAssertEqual(
            BashSecurityWarning.evaluate(policy: safePolicy, driver: .externalAgent, externalAgentsEnabled: true),
            []
        )
        XCTAssertNil(
            BashSecurityWarning.warningMessage(policy: safePolicy, driver: .externalAgent, externalAgentsEnabled: true)
        )

        // 2. Sandbox disabled with externalAgent driver -> explicit warning naming local ports and the port external agents connect to
        let unsandboxedPolicy = BashPolicy(sandboxEnabled: false, allowUnsandboxedFallback: false)
        let disabledWarnings = BashSecurityWarning.evaluate(
            policy: unsandboxedPolicy,
            driver: .externalAgent,
            externalAgentsEnabled: false
        )
        XCTAssertEqual(disabledWarnings, [.sandboxDisabled(externalAgentActive: true)])
        let disabledMessage = try XCTUnwrap(
            BashSecurityWarning.warningMessage(
                policy: unsandboxedPolicy,
                driver: .externalAgent,
                externalAgentsEnabled: false
            )
        )
        XCTAssertTrue(disabledMessage.contains("external agents connect to"))
        XCTAssertTrue(disabledMessage.lowercased().contains("port"))

        // 3. Unsandboxed fallback enabled with externalAgent / externalAgentsEnabled -> explicit warning
        let fallbackPolicy = BashPolicy(sandboxEnabled: true, allowUnsandboxedFallback: true)
        let fallbackWarnings = BashSecurityWarning.evaluate(
            policy: fallbackPolicy,
            driver: .externalAgent,
            externalAgentsEnabled: true
        )
        XCTAssertEqual(fallbackWarnings, [.unsandboxedFallbackEnabled(externalAgentActive: true)])
        let fallbackMessage = try XCTUnwrap(
            BashSecurityWarning.warningMessage(
                policy: fallbackPolicy,
                driver: .externalAgent,
                externalAgentsEnabled: true
            )
        )
        XCTAssertTrue(fallbackMessage.contains("external agents connect to"))

        // 4. When bash mode is .off, no bash commands can run -> no warnings
        let offPolicy = BashPolicy(mode: .off, sandboxEnabled: false, allowUnsandboxedFallback: true)
        XCTAssertEqual(
            BashSecurityWarning.evaluate(policy: offPolicy, driver: .externalAgent, externalAgentsEnabled: true),
            []
        )
    }

    // MARK: - Milestone F1: Features 1 & 2 (Seatbelt Hardening & Sandboxing [V1])

    /// Feature 1: The work folder's `.nanoteams/internal` directory (including snapshots.git/config
    /// and teams.json) is completely denied for both reading and writing from sandboxed bash.
    func testProfile_internalDirectoryIsCompletelyDenied_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let work = fm.temporaryDirectory.appendingPathComponent("nt-sbinternal-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let internalDir = work.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let snapshotsGit = internalDir.appendingPathComponent("snapshots.git", isDirectory: true)
        try fm.createDirectory(at: snapshotsGit, withIntermediateDirectories: true)

        let teamsFile = internalDir.appendingPathComponent("teams.json")
        let configFile = snapshotsGit.appendingPathComponent("config")
        try "TEAMS_CONTENT".write(to: teamsFile, atomically: true, encoding: .utf8)
        try "CONFIG_CONTENT".write(to: configFile, atomically: true, encoding: .utf8)

        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [])
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh",
            command: "cat .nanoteams/internal/teams.json 2>&1; "
                + "cat .nanoteams/internal/snapshots.git/config 2>&1; "
                + "echo EVIL > .nanoteams/internal/teams.json 2>/dev/null; "
                + "echo EVIL > .nanoteams/internal/snapshots.git/config 2>/dev/null; "
                + "echo EVIL > .nanoteams/internal/new_file.txt 2>/dev/null; "
                + "echo ok > plain.txt; cat plain.txt; echo DONE")
        let out = try ProcessRunner.run(
            executable: exe, arguments: args, currentDirectory: work, timeout: 20).stdout

        XCTAssertTrue(out.contains("ok"), "work folder root stays writable: \(out)")
        XCTAssertTrue(out.contains("DONE"), "command completed: \(out)")
        XCTAssertFalse(out.contains("TEAMS_CONTENT"), "internal/teams.json reading must be denied: \(out)")
        XCTAssertFalse(out.contains("CONFIG_CONTENT"), "snapshots.git/config reading must be denied: \(out)")
        XCTAssertEqual(
            try String(contentsOf: teamsFile, encoding: .utf8), "TEAMS_CONTENT",
            "teams.json must not be modified from bash")
        XCTAssertEqual(
            try String(contentsOf: configFile, encoding: .utf8), "CONFIG_CONTENT",
            "snapshots.git/config must not be modified from bash")
        XCTAssertFalse(
            fm.fileExists(atPath: internalDir.appendingPathComponent("new_file.txt").path),
            "new files must not be created under .nanoteams/internal")
    }

    /// Feature 2: Renaming or unlinking `.nanoteams` and `.git` root nodes is denied,
    /// blocking ancestor bypass attacks while leaving inner git files writable.
    func testProfile_ancestorBypassAndSymlinkLock_forNanoteamsAndGit_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let work = fm.temporaryDirectory.appendingPathComponent("nt-sbancestor-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let internalDir = work.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let gitDir = work.appendingPathComponent(".git", isDirectory: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)

        let teamsFile = internalDir.appendingPathComponent("teams.json")
        let configFile = gitDir.appendingPathComponent("config")
        try "ORIGINAL_TEAMS".write(to: teamsFile, atomically: true, encoding: .utf8)
        try "ORIGINAL_GIT_CONFIG".write(to: configFile, atomically: true, encoding: .utf8)

        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [])
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh",
            command: "mv .nanoteams bypassed_nt 2>&1; "
                + "if [ -d bypassed_nt ]; then echo CLOBBERED > bypassed_nt/internal/teams.json 2>/dev/null; mv bypassed_nt .nanoteams 2>&1; fi; "
                + "mv .git bypassed_git 2>&1; "
                + "if [ -d bypassed_git ]; then echo CLOBBERED > bypassed_git/config 2>/dev/null; mv bypassed_git .git 2>&1; fi; "
                + "rmdir .nanoteams 2>&1; "
                + "rmdir .git 2>&1; "
                + "echo DONE")
        let out = try ProcessRunner.run(
            executable: exe, arguments: args, currentDirectory: work, timeout: 20).stdout

        XCTAssertTrue(out.contains("DONE"))
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("bypassed_nt").path), "moving .nanoteams must fail")
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("bypassed_git").path), "moving .git must fail")
        XCTAssertEqual(
            try String(contentsOf: teamsFile, encoding: .utf8), "ORIGINAL_TEAMS",
            "teams.json must be preserved through ancestor protection")
        XCTAssertEqual(
            try String(contentsOf: configFile, encoding: .utf8), "ORIGINAL_GIT_CONFIG",
            "git/config must be preserved through ancestor protection")
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent(".nanoteams").path), ".nanoteams directory must remain")
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent(".git").path), ".git directory must remain")
    }

    /// Feature 2 Pin: Verify that the existing rule in SeatbeltSandbox.swift blocking writes
    /// to `.git/hooks` and `.git/config` remains intact and effective.
    func testProfile_gitHooksAndGitConfigAreNotWritable_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let work = fm.temporaryDirectory.appendingPathComponent("nt-sbhooks-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let hooksDir = work.appendingPathComponent(".git/hooks", isDirectory: true)
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let configFile = work.appendingPathComponent(".git/config")
        let preCommitFile = hooksDir.appendingPathComponent("pre-commit")
        try "ORIGINAL_CONFIG".write(to: configFile, atomically: true, encoding: .utf8)
        try "ORIGINAL_HOOK".write(to: preCommitFile, atomically: true, encoding: .utf8)

        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [])
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh",
            command: "echo CLOBBER > .git/config 2>/dev/null; "
                + "echo CLOBBER > .git/hooks/pre-commit 2>/dev/null; "
                + "echo CLOBBER > .git/hooks/reference-transaction 2>/dev/null; "
                + "echo ok > plain.txt; echo DONE")
        let out = try ProcessRunner.run(
            executable: exe, arguments: args, currentDirectory: work, timeout: 20).stdout

        XCTAssertTrue(out.contains("DONE"))
        XCTAssertEqual(
            try String(contentsOf: configFile, encoding: .utf8), "ORIGINAL_CONFIG",
            ".git/config must not be writable")
        XCTAssertEqual(
            try String(contentsOf: preCommitFile, encoding: .utf8), "ORIGINAL_HOOK",
            ".git/hooks/pre-commit must not be writable")
        XCTAssertFalse(
            fm.fileExists(atPath: hooksDir.appendingPathComponent("reference-transaction").path),
            "new hooks must not be created")
    }

    /// Feature 1 Default Storage: When default storage is active (work folder is ~/Library/Application Support/NanoTeams),
    /// machine stores (mcp, agent-access, skills, benchmarks) cannot be read or written from sandboxed bash.
    func testProfile_defaultStorage_machineStoresCannotBeReadOrWritten_live() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let fakeHome = fm.temporaryDirectory.appendingPathComponent("nt-sbhome-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: fakeHome) }

        let defaultStorage = fakeHome.appendingPathComponent("Library/Application Support/NanoTeams", isDirectory: true)
        let mcpDir = defaultStorage.appendingPathComponent("mcp", isDirectory: true)
        let agentAccessDir = defaultStorage.appendingPathComponent("agent-access", isDirectory: true)
        try fm.createDirectory(at: mcpDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: agentAccessDir, withIntermediateDirectories: true)

        let trustFile = mcpDir.appendingPathComponent("trust.json")
        let agentsFile = agentAccessDir.appendingPathComponent("agents.json")
        try "ORIGINAL_TRUST".write(to: trustFile, atomically: true, encoding: .utf8)
        try "ORIGINAL_AGENTS".write(to: agentsFile, atomically: true, encoding: .utf8)

        let profile = SeatbeltSandbox.profile(
            workFolderRoot: defaultStorage, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [], home: fakeHome)
        let (exe, args) = SeatbeltSandbox.wrap(
            profile: profile, shell: "/bin/zsh",
            command: "cat mcp/trust.json 2>&1; "
                + "echo CLOBBER > mcp/trust.json 2>/dev/null; "
                + "echo CLOBBER > agent-access/agents.json 2>/dev/null; "
                + "echo ok > plain.txt; cat plain.txt; echo DONE")
        let out = try ProcessRunner.run(
            executable: exe, arguments: args, currentDirectory: defaultStorage, timeout: 20).stdout

        XCTAssertTrue(out.contains("ok"), "default storage plain files remain writable: \(out)")
        XCTAssertTrue(out.contains("DONE"))
        XCTAssertFalse(out.contains("ORIGINAL_TRUST"), "reading mcp/trust.json must be denied: \(out)")
        XCTAssertEqual(
            try String(contentsOf: trustFile, encoding: .utf8), "ORIGINAL_TRUST",
            "mcp/trust.json must not be modified")
        XCTAssertEqual(
            try String(contentsOf: agentsFile, encoding: .utf8), "ORIGINAL_AGENTS",
            "agent-access/agents.json must not be modified")
    }
}


