import Foundation

/// Builds a macOS Seatbelt (`sandbox-exec`) profile and wraps a shell command so
/// it runs confined: by default reads are broad (the shell needs them) but
/// credential stores are unreadable, and **writes are limited to the work folder
/// and temporary directories**. Reads and writes are both configurable per scope
/// via `BashSandboxPermissions`.
///
/// The profile is intentionally permissive on reads/process-spawn/network so that
/// real development commands (build, test, package installs, git) work — the
/// confinement that matters here is "a command cannot write outside the project
/// or read your secrets". Pair it with the `BashPermissionService` rule layer
/// and the Auto judge for behavioral safety.
///
/// All paths are canonicalized via `realpath(3)` before being embedded — Seatbelt
/// matches on the real path, so a work folder reached through a symlink (`/tmp` →
/// `/private/tmp`, `/var` → `/private/var`, a relocated `$HOME`) would otherwise
/// escape both the allow-list AND the denies. This file claimed that invariant while
/// using `URL.resolvingSymlinksInPath()`, which hands back the SHORT form for exactly
/// those root-level symlinks — see `canonical(_:)` for the measurements.
nonisolated enum SeatbeltSandbox {

    /// Builds the SBPL profile text honoring the per-scope read/write grants in
    /// `permissions`. The default `permissions` reproduces the original profile:
    /// writes confined to the work folder + temp dirs, broad reads, credential
    /// reads blocked.
    static func profile(
        workFolderRoot: URL,
        permissions: BashSandboxPermissions = BashSandboxPermissions()
    ) -> String {
        let work = canonical(workFolderRoot)
        let tmp = canonical(URL(fileURLWithPath: NSTemporaryDirectory()))
        let home = canonical(URL(fileURLWithPath: NSHomeDirectory()))
        // The app's own session temp ($TMPDIR — a subpath of /private/var/folders
        // that the sandboxed shell inherits) plus the de-facto /tmp. We deliberately
        // do NOT grant the broad /private/var/folders or /private/var/tmp: the precise
        // `tmp` already covers $TMPDIR/mktemp, and the broad parent would let commands
        // roam the whole per-user temp/cache tree.
        let tempPaths = [tmp, "/private/tmp"]

        // Credential stores — denied for reads (unless credential reads are allowed)
        // and ALWAYS denied for writes. They live under $HOME, so they must also be
        // carved out whenever the home folder itself is granted.
        let credentialSubpaths = [
            "\(home)/.ssh", "\(home)/.aws", "\(home)/.gnupg", "\(home)/.config/gh",
            "\(home)/.config/gcloud", "\(home)/.kube", "\(home)/.docker",
            "\(home)/Library/Keychains", "/Library/Keychains",
        ]
        let credentialLiterals = ["\(home)/.netrc"]

        // Does the work folder contain (or equal) any credential path? Only then can a
        // work grant / work re-allow re-expose a credential store — the canonical case
        // is the user opening `~` (or a dotfiles repo) as the project root. When it
        // does, the credential clause below must still fire so the "credential writes
        // are always blocked / reads honor the toggle" guarantee holds.
        let workURL = URL(fileURLWithPath: work)
        let workCoversCredential = (credentialSubpaths + credentialLiterals).contains {
            SandboxPathResolver.isWithin(candidate: URL(fileURLWithPath: $0), container: workURL)
        }

        // Scope nesting — SBPL is last-match-wins, so clauses are emitted in ASCENDING
        // specificity (broadest first, MOST SPECIFIC LAST):
        //   system ("everything else")  ⊃  home (~)  ⊃  work folder  ⊃  credentials
        // `temp` is independent (under /private). The work folder and the credential
        // stores live INSIDE $HOME, so a home grant/deny is overridden by the work
        // re-allow that follows it — and the credential clause is emitted DEAD LAST so
        // it overrides the broad allow, the home deny, AND the work re-allow (otherwise
        // a `work == ~` re-allow would re-expose ~/.ssh, ~/.netrc, …).
        var clauses: [String] = [
            "(version 1)",
            "(deny default)",
            "(allow process*)",
            "(allow signal)",
            "(allow sysctl-read)",
            "(allow mach-lookup)",
            "(allow ipc-posix-shm)",
            "(allow network*)",
        ]

        // ---- file-read* allow ----
        // Broad when system read is on (the default — the shell needs system reads to
        // run anything), else only the enabled scopes. An empty narrow set emits NO
        // allow clause (deny-default blocks all reads) rather than a bare
        // `(allow file-read*)`, which would be broad.
        if permissions.everythingElseRead {
            clauses.append("(allow file-read*)")
        } else {
            var readSubpaths: [String] = []
            var readLiterals: [String] = []
            if permissions.workFolderRead { readSubpaths.append(work) }
            if permissions.tempRead { readSubpaths.append(contentsOf: tempPaths) }
            if permissions.homeRead { readSubpaths.append(home) }
            if permissions.credentialRead {
                readSubpaths.append(contentsOf: credentialSubpaths)
                readLiterals.append(contentsOf: credentialLiterals)
            }
            if let allow = subpathClause(readSubpaths, literals: readLiterals) {
                clauses.append("(allow file-read*\n\(allow))")
            }
        }

        // ---- file-write* allow ----
        // System write on → broad `/` (the escape hatch). Else the enabled scopes
        // (work / temp / home) + the dev nodes every shell needs for tty / pipes.
        let writeSubpaths: [String]
        if permissions.everythingElseWrite {
            writeSubpaths = ["/"]
        } else {
            var paths: [String] = []
            if permissions.workFolderWrite { paths.append(work) }
            if permissions.tempWrite { paths.append(contentsOf: tempPaths) }
            if permissions.homeWrite { paths.append(home) }
            writeSubpaths = paths
        }
        var writeClause = "(allow file-write*"
        if let subpathClause = subpathClause(writeSubpaths) { writeClause += "\n\(subpathClause)" }
        writeClause += """
        
            (literal "/dev/null")
            (literal "/dev/zero")
            (literal "/dev/dtracehelper")
            (literal "/dev/tty")
            (literal "/dev/stdout")
            (literal "/dev/stderr")
            (regex #"^/dev/fd/[0-9]+$")
            (regex #"^/dev/ttys[0-9]+$"))
        """
        clauses.append(writeClause)

        // ---- file-read* deny + work re-allow (credentials handled DEAD LAST) ----
        if permissions.everythingElseRead {
            // Broad read: carve out every OFF scope (most-specific last). A home deny
            // also strips the project (work ⊂ home), so re-allow work AFTER the deny.
            var denySubpaths: [String] = []
            if !permissions.tempRead { denySubpaths.append(contentsOf: tempPaths) }
            if !permissions.homeRead { denySubpaths.append(home) }
            if !permissions.workFolderRead { denySubpaths.append(work) }
            if let readDeny = optionalDenyClause("file-read*", subpaths: denySubpaths) {
                clauses.append(readDeny)
            }
            if permissions.workFolderRead, !permissions.homeRead, let wc = subpathClause([work]) {
                clauses.append("(allow file-read*\n\(wc))")
            }
            // Credentials LAST — overrides the broad allow, the home deny, and the
            // work re-allow above. When read is enabled we only need to RE-allow them
            // if a home deny (or a work re-allow that doesn't cover them) would block
            // them; emitting it unconditionally-when-homeRead-off is correct + simplest.
            if !permissions.credentialRead {
                if let credDeny = optionalDenyClause("file-read*", subpaths: credentialSubpaths, literals: credentialLiterals) {
                    clauses.append(credDeny)
                }
            } else if !permissions.homeRead, let credAllow = subpathClause(credentialSubpaths, literals: credentialLiterals) {
                clauses.append("(allow file-read*\n\(credAllow))")
            }
        } else {
            // Narrow read: the allow-list above is exact, EXCEPT an allowed home (or a
            // work folder that contains them) would expose credentials and an off work
            // folder nested under an allowed home. Carve those out; credentials last.
            var denySubpaths: [String] = []
            var denyLiterals: [String] = []
            if permissions.homeRead, !permissions.workFolderRead { denySubpaths.append(work) }
            if !permissions.credentialRead, permissions.homeRead || (permissions.workFolderRead && workCoversCredential) {
                denySubpaths.append(contentsOf: credentialSubpaths)
                denyLiterals.append(contentsOf: credentialLiterals)
            }
            if let readDeny = optionalDenyClause("file-read*", subpaths: denySubpaths, literals: denyLiterals) {
                clauses.append(readDeny)
            }
        }

        // ---- file-write* deny + work re-allow (credentials handled DEAD LAST) ----
        // Credential writes are ALWAYS blocked.
        if permissions.everythingElseWrite {
            // Broad write: carve OFF scopes; re-allow work after a home deny.
            var denySubpaths: [String] = []
            if !permissions.tempWrite { denySubpaths.append(contentsOf: tempPaths) }
            if !permissions.homeWrite { denySubpaths.append(home) }
            if !permissions.workFolderWrite { denySubpaths.append(work) }
            if let writeDeny = optionalDenyClause("file-write*", subpaths: denySubpaths) {
                clauses.append(writeDeny)
            }
            if permissions.workFolderWrite, !permissions.homeWrite, let wc = subpathClause([work]) {
                clauses.append("(allow file-write*\n\(wc))")
            }
            // Credentials LAST — broad `/` covers them, so always deny (overrides the
            // work re-allow too, e.g. work == ~).
            if let credDeny = optionalDenyClause("file-write*", subpaths: credentialSubpaths, literals: credentialLiterals) {
                clauses.append(credDeny)
            }
        } else {
            // Narrow write: allow-list is exact. Carve a disabled work folder out of an
            // allowed home, then deny credentials whenever an allowed write scope (home,
            // or a work folder that contains them) could reach them — writes are blocked.
            var denySubpaths: [String] = []
            var denyLiterals: [String] = []
            if permissions.homeWrite, !permissions.workFolderWrite { denySubpaths.append(work) }
            if permissions.homeWrite || (permissions.workFolderWrite && workCoversCredential) {
                denySubpaths.append(contentsOf: credentialSubpaths)
                denyLiterals.append(contentsOf: credentialLiterals)
            }
            if let writeDeny = optionalDenyClause("file-write*", subpaths: denySubpaths, literals: denyLiterals) {
                clauses.append(writeDeny)
            }
        }

        return clauses.joined(separator: "\n")
    }

    // MARK: - SBPL clause builders

    /// Formats a list of paths as indented `(subpath …)` / `(literal …)` lines, or
    /// `nil` when both lists are empty.
    private static func subpathClause(_ subpaths: [String], literals: [String] = []) -> String? {
        let lines = subpaths.map { "    (subpath \(quote($0)))" }
            + literals.map { "    (literal \(quote($0)))" }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func denyClause(_ operation: String, subpaths: [String], literals: [String]) -> String {
        "(deny \(operation)\n\(subpathClause(subpaths, literals: literals) ?? ""))"
    }

    private static func optionalDenyClause(_ operation: String, subpaths: [String], literals: [String] = []) -> String? {
        guard subpathClause(subpaths, literals: literals) != nil else { return nil }
        return denyClause(operation, subpaths: subpaths, literals: literals)
    }

    /// Wraps a shell invocation in `sandbox-exec -p <profile>`. Returns the
    /// executable + arguments for `ProcessRunner`.
    static func wrap(
        profile: String,
        shell: String,
        command: String
    ) -> (executable: String, arguments: [String]) {
        (
            executable: BashConstants.sandboxExecPath,
            arguments: ["-p", profile, shell, "-lc", command]
        )
    }

    /// Heuristic: did a non-zero result come from Seatbelt refusing to launch /
    /// rejecting the profile (vs. the command itself failing)? Used to decide
    /// whether to honor `allowUnsandboxedFallback`.
    /// The wrapper and the child it launches write to the SAME stderr pipe, so a `contains` test
    /// cannot tell them apart — and it did not: any failing command whose stderr merely mentioned
    /// the wrapper was classified as a wrapper failure. Measured consequences were both a silent
    /// unconfined re-execution (with the fallback enabled) and a false "Command was not run"
    /// that discarded the command's real output (with it disabled, the default).
    ///
    /// The discriminator is POSITION, not vocabulary: `sandbox-exec` reports its own faults before
    /// the child produces anything, so its diagnostic is the FIRST thing on stderr. Measured on
    /// macOS 26 — every wrapper failure opens with `sandbox-exec: `:
    ///
    ///     bad profile             exit 65  `sandbox-exec: undefined sharp expression`
    ///     missing profile file    exit 65  `sandbox-exec: /tmp/x.sb: No such file or directory`
    ///     unreadable profile file exit 65  `sandbox-exec: /tmp/x.sb: Permission denied`
    ///     execvp failure          exit 71  `sandbox-exec: execvp() of '…' failed: …`
    ///
    /// while confined children that fail on their own do not:
    ///
    ///     `cat /usr/bin/sandbox-exec/nope`      exit 1  `cat: …: Not a directory`
    ///     `set -x; grep -rn "sandbox-exec" …`   exit 2  `+zsh:1> grep -rn sandbox-exec …`
    ///
    /// A profile that compiles but denies the system reads the shell needs is exit 134 with EMPTY
    /// stderr. That is a genuinely CONFINED failure, not a wrapper fault, so it must not license a
    /// retry — and the prefix rule declines it for the right reason rather than by accident.
    ///
    /// No exit-code allowlist: 65 and 71 are the codes observed today, and pinning them would make
    /// an unobserved wrapper code fail OPEN. Position plus a non-zero exit is the whole rule.
    ///
    /// `sandbox_apply:` rides alongside because it is the other wrapper-side identifier this
    /// project has recorded; it was not reproduced on macOS 26, and it is kept because the
    /// discriminator is the position of a WRAPPER identifier, not the specific spelling. Both
    /// directions of error are asymmetric and the conservative one is chosen deliberately: failing
    /// to recognise a wrapper fault means no retry and the command's real output is reported
    /// (honest), while a false positive means an unconfined execution (not).
    private static let wrapperDiagnosticPrefixes = ["sandbox-exec:", "sandbox_apply:"]

    static func isSandboxDenialFailure(exitCode: Int32, stderr: String) -> Bool {
        guard exitCode != 0 else { return false }
        let head = stderr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return wrapperDiagnosticPrefixes.contains { head.hasPrefix($0) }
    }

    // MARK: - Helpers

    /// The path the KERNEL sees — which is the only thing Seatbelt matches a
    /// `(subpath …)` against.
    ///
    /// Must be `realpath(3)`, NOT `URL.resolvingSymlinksInPath()`. Foundation's resolver
    /// does the OPPOSITE for macOS's root-level symlinks: it strips a leading `/private`
    /// when the result exists, so it hands back the SHORT form. Measured on macOS 26:
    ///
    ///     input                      resolvingSymlinksInPath   realpath(3)
    ///     /tmp                       /tmp                      /private/tmp
    ///     /var                       /var                      /private/var
    ///     $TMPDIR (/var/folders/…/T) /var/folders/…/T          /private/var/folders/…/T
    ///     /Users/alex                /Users/alex               /Users/alex   (agree)
    ///
    /// Seatbelt resolves the ACCESSED path to `/private/…` before matching, so a
    /// short-form subpath matches nothing — and it fails silently in both directions.
    /// Measured live with the profile this file generates: a work folder under `$TMPDIR`
    /// was NOT writable despite `workFolderWrite: true`, and with `everythingElseWrite:
    /// true, tempWrite: false` a write into `$TMPDIR` SUCCEEDED despite the explicit deny.
    /// The allow direction merely breaks the tool; the deny direction is a grant the user
    /// switched off still being in force, and the same arithmetic applies to the
    /// credential denies whenever `$HOME` is reached through a symlink.
    ///
    /// `FileSystemWatcher.canonicalPath(for:)` already records this trap and works around
    /// it by rewriting three known prefixes. `realpath` supersedes that here on purpose: a
    /// security boundary must not depend on a hand-maintained list of symlinks, and the
    /// same defect reaches any symlinked ancestor (`/Volumes/…`, a relocated `$HOME`).
    ///
    /// `realpath` requires every component to exist. Nothing this file embeds is
    /// hypothetical — the work folder is open, `$TMPDIR` and `$HOME` exist, `/private/tmp`
    /// is a literal, and the credential paths are interpolated from an already-canonical
    /// `home` — so the fallback is only for a folder deleted underneath us, where the
    /// grant describes a path no access can reach anyway.
    private static func canonical(_ url: URL) -> String {
        let standardized = url.standardizedFileURL.path
        if let resolved = realpath(standardized, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// SBPL double-quoted string literal with backslash + quote escaping.
    private static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
