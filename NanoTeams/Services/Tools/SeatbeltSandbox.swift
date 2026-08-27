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

        // The mirror of the line above, with the containment INVERTED: there the work
        // folder contains a credential store, here the work folder is contained by a
        // temp root. Both answer the same question — "can some other grant re-expose a
        // path this scope's own flag turned off" — and only the credential half existed
        // until 2026-08-25, which is why `workFolderWrite: false, tempWrite: true` left
        // a project under `$TMPDIR` writable. `work` and `tempPaths` are already
        // realpath-canonical here, so no further canonicalization is needed.
        let workCoveredByTemp = tempPaths.contains {
            SandboxPathResolver.isWithin(candidate: workURL, container: URL(fileURLWithPath: $0))
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
            // Re-allow work after ANY deny that was emitted, not after the home deny
            // specifically. The enumerated form asked "did the HOME deny swallow the
            // work folder", and a temp deny swallows it just as completely when the
            // project lives under `$TMPDIR` — there the grant the user switched ON
            // silently did not apply, which reads as "the sandbox is broken" rather
            // than "the sandbox is leaky" and arrives through a different door.
            // Conditioning on the deny list being non-empty closes that by
            // construction rather than by a longer list (CLAUDE.md #75).
            if permissions.workFolderRead, !denySubpaths.isEmpty, let wc = subpathClause([work]) {
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
            // A work folder that is OFF stays reachable through any OTHER grant that
            // covers its path — home, or temp when the project lives under `$TMPDIR`
            // (CLAUDE.md #75: ask not "is this scope's flag off" but "is its path
            // covered by some other grant"). `workCoveredByTemp` is the mirror of
            // `workCoversCredential` above, with the containment inverted.
            if !permissions.workFolderRead,
               permissions.homeRead || (permissions.tempRead && workCoveredByTemp) {
                denySubpaths.append(work)
            }
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
            // Re-allow after ANY emitted deny — see the read side above for why the
            // enumerated `!homeWrite` form lost a grant the user had switched on.
            if permissions.workFolderWrite, !denySubpaths.isEmpty, let wc = subpathClause([work]) {
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
            // The reported D-10 shape: `workFolderWrite: false, tempWrite: true` reads
            // in Settings as "commands may not write my project", and the write
            // allow-list is a set of `(subpath …)` clauses with no work deny beneath —
            // so a project under `$TMPDIR` / `/private/tmp` stayed fully writable.
            if !permissions.workFolderWrite,
               permissions.homeWrite || (permissions.tempWrite && workCoveredByTemp) {
                denySubpaths.append(work)
            }
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

    /// Does this exit code + stderr look like `sandbox-exec` diagnosing its OWN fault?
    ///
    /// **Read the input contract first: this is applied to a PROBE's stderr, not to the
    /// stderr of the command under judgement.** The wrapper and the child it launches share
    /// one stderr pipe (`ProcessRunner` gives the single `Process` one `Pipe`), so when the
    /// wrapper does NOT fail the first bytes belong to the child — and a child can therefore
    /// author whatever this rule looks for. Measured on macOS 26:
    ///
    ///     sandbox-exec -p '(version 1)(allow default)' /bin/zsh -lc \
    ///       'echo "sandbox-exec: fake denial" >&2; exit 1'
    ///     → exit 1, stderr head exactly `sandbox-exec: fake denial`
    ///
    /// With `allowUnsandboxedFallback` on that re-ran the command with NO profile; with it off
    /// (the default) it produced a `bashDenied` envelope claiming "The command was not run"
    /// about a command that had run, discarding its real stdout and stderr.
    ///
    /// `probeSandboxLaunch` closes that by asking the wrapper the question directly — it
    /// re-launches the SAME invocation with a no-op command, so the stderr this rule reads is
    /// a stream the judged command never touched. Narrowing `contains` to `hasPrefix` (which
    /// is what the position argument below buys) killed ACCIDENTAL misclassification; only the
    /// separate stream kills the deliberate one.
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
    /// retry. It is now a NAMED state (`LaunchVerdict.confinedBeforeStart`) rather than something
    /// this prefix rule declines: the Bool could not express it, so it was reported as an ordinary
    /// command failure with an empty result — the least useful of the three available answers.
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

    /// Renamed from `isSandboxDenialFailure` on 2026-08-25. The rule is unchanged; what changed
    /// is WHOSE stderr it reads, and the old name described the question ("was this a sandbox
    /// denial?") rather than the evidence ("is this a wrapper diagnostic?"), which is what let it
    /// be pointed at a stream the command controls.
    static func isWrapperDiagnostic(exitCode: Int32, stderr: String) -> Bool {
        guard exitCode != 0 else { return false }
        let head = stderr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return wrapperDiagnosticPrefixes.contains { head.hasPrefix($0) }
    }

    /// Why a sandboxed run failed, distinguished by asking the WRAPPER rather than by reading a
    /// stream the command can write to.
    enum LaunchVerdict: Equatable {
        /// The wrapper launched the child; whatever failed is the command's own doing. Its
        /// stdout/stderr are real output and must be reported verbatim.
        case childRan
        /// `sandbox-exec` refused — bad or unreadable profile, `execvp` failure. Nothing ran.
        /// This is the only state that may license an unconfined retry.
        case wrapperRejected
        /// The profile compiled and the wrapper exec'd, but the confinement killed the shell
        /// before the command could start (measured: exit 134, empty stderr). Nothing ran, and
        /// it is a CONFINED failure — retrying unconfined would defeat the profile the user
        /// asked for.
        case confinedBeforeStart
    }

    /// What a launch verdict obliges the caller to do about it.
    enum LaunchResponse: Equatable {
        /// Report the process result as the command's own. Covers `.childRan`, every
        /// unsandboxed run, and `.confinedBeforeStart` — the last of those is a real result
        /// (exit 134, no output) that a warning explains rather than replaces.
        case reportTheResult
        /// The wrapper refused AND the policy permits it: re-run with no profile.
        case retryUnconfined
        /// The wrapper refused and no fallback is allowed. NOTHING ran, and the caller must say
        /// so instead of reporting an exit code the command never produced.
        case reportNothingRan
    }

    /// One owner for "what does a wrapper rejection oblige us to do", consulted by BOTH sites
    /// that used to decide it with hand-written conditions: the retry gate inside
    /// `BashTool.runForeground` and the envelope arm in `BashTool.handle`.
    ///
    /// They ask about the SAME verdict and the SAME policy flag, and a rule split across two
    /// sites is a rule that can disagree with itself (CLAUDE.md #51/#60) — here the disagreement
    /// would be the worst kind: a command reported as "not run" that in fact ran unconfined, or
    /// the reverse. Pure and `nonisolated` so it is reachable without a process, which is also
    /// what makes the `reportNothingRan` arm testable at all — through `BashTool` it is not,
    /// because the profile is built internally and no `BashSandboxPermissions` value can make
    /// `sandbox-exec` refuse it.
    ///
    /// `ranSandboxed` is load-bearing: after a fallback the command demonstrably DID run, and
    /// the stale verdict from the first attempt must not speak for the second.
    static func response(
        ranSandboxed: Bool,
        launch: LaunchVerdict,
        fallbackAllowed: Bool
    ) -> LaunchResponse {
        guard ranSandboxed, launch == .wrapperRejected else { return .reportTheResult }
        return fallbackAllowed ? .retryUnconfined : .reportNothingRan
    }

    /// The probe invocation: byte-identical to `wrap` except the command is a shell no-op.
    ///
    /// Derived from `wrap` rather than spelled out, so a flag added there applies here too
    /// instead of leaving the probe testing a different invocation than the one that failed.
    static func probeInvocation(profile: String, shell: String) -> (executable: String, arguments: [String]) {
        wrap(profile: profile, shell: shell, command: ":")
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
