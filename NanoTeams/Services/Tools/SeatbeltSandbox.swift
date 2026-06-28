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
/// All paths are canonicalized via `resolvingSymlinksInPath()` before being
/// embedded — Seatbelt matches on the real path, so a symlinked work folder
/// (e.g. `/tmp` → `/private/tmp`) would otherwise escape the write allow-list.
nonisolated enum SeatbeltSandbox {

    /// Builds the SBPL profile text honoring the per-scope read/write grants in
    /// `permissions`. The default `permissions` reproduces the original profile:
    /// writes confined to the work folder + temp dirs, broad reads, credential
    /// reads blocked.
    static func profile(
        workFolderRoot: URL,
        permissions: BashSandboxPermissions = BashSandboxPermissions(),
        fileManager: FileManager = .default
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
    static func isSandboxDenialFailure(exitCode: Int32, stderr: String) -> Bool {
        guard exitCode != 0 else { return false }
        let lower = stderr.lowercased()
        return lower.contains("sandbox-exec")
            || lower.contains("sandbox_apply")
            || lower.contains("failed to initialize sandbox")
            || lower.contains("profile compilation")
    }

    // MARK: - Helpers

    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// SBPL double-quoted string literal with backslash + quote escaping.
    private static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
