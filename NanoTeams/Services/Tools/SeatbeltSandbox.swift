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

    /// The external agents' configuration folders (§10.2.3): where their agent tokens
    /// live and, for most of these clients, their own account credentials. A credential store
    /// like `~/.ssh`, in every profile, External Agents on or off — until 2026-11-08 they joined
    /// the list only while External Agents was on, but a token outlives the switch, and a step
    /// started with the switch off keeps that profile, background commands included (#375). Like
    /// every credential store they follow Settings → Bash → Credential stores: a person who grants
    /// those reads grants these; the token locations inside them do not
    /// (`externalAgentTokenLocations`).
    ///
    /// What no clause here can deny: another process's ENVIRONMENT. `sysctl` `KERN_PROCARGS2`
    /// reads the exec-time arguments and environment of any process of the same user, and
    /// neither `process-info*` narrowed to the sandbox nor `sysctl-read` denied (by name, or
    /// entirely) stops it — measured 2026-11-08 from inside this profile, against a running
    /// Claude Code. So a token must never reach a client as an environment variable or an
    /// argument; `SeatbeltSandboxTests` pins the limit.
    static func externalAgentCredentialSubpaths(home: String) -> [String] {
        [
            "\(home)/.claude.json",
            "\(home)/.claude",
            "\(home)/.codex",
            "\(home)/Library/Application Support/Claude",
            "\(home)/.cursor",
            "\(home)/.gemini",
            "\(home)/Library/Application Support/Code/User",
            "\(home)/.vscode",
        ]
    }

    /// Every credential store a role is kept from: the user's own (`~/.ssh`, cloud CLIs, the
    /// Keychains) and the agent clients' configuration folders. The profile denies them unless
    /// Settings → Bash grants credential reads; `SandboxPathResolver` hides the ones inside a work
    /// folder from the file tools, which have no such grant.
    static func credentialStoreSubpaths(home: String) -> [String] {
        bothSpellings([
            "\(home)/.ssh", "\(home)/.aws", "\(home)/.gnupg", "\(home)/.config/gh",
            "\(home)/.config/gcloud", "\(home)/.kube", "\(home)/.docker",
            "\(home)/Library/Keychains", "/Library/Keychains",
        ] + externalAgentCredentialSubpaths(home: home))
    }

    /// The credential stores that are single files.
    static func credentialStoreLiterals(home: String) -> [String] {
        bothSpellings(["\(home)/.netrc"])
    }

    /// Internal application state and machine storage subpaths that must be completely denied
    /// from sandboxed bash for both reading and writing (Features 1 & 2 / V1).
    static func privateStateSubpaths(work: String, home: String) -> [String] {
        // Both from `NTMSPaths` (F6 S9): the deny list and the stores read one table, so a new
        // store cannot exist without being denied here.
        var subpaths: [String] = [
            (work as NSString).appendingPathComponent(NTMSPaths.internalRelativePath)
        ]
        let defaultStoragePath = canonical(
            NTMSPaths.defaultStorageURL(home: URL(fileURLWithPath: home, isDirectory: true)))
        let storeNames = NTMSPaths.MachineStore.allCases.map(\.directoryName)
        if work == defaultStoragePath || SandboxPathResolver.isWithin(realPath: work, realContainer: defaultStoragePath) {
            subpaths.append(contentsOf: storeNames.map {
                (work as NSString).appendingPathComponent($0)
            })
        }
        // Deny machine stores under home whenever home could be reached
        subpaths.append(contentsOf: storeNames.map {
            (defaultStoragePath as NSString).appendingPathComponent($0)
        })
        return bothSpellings(Array(Set(subpaths)).sorted())
    }

    /// Literal nodes protected from rename and unlink, because Seatbelt matches PATHS, not
    /// inodes — a node moved to another name leaves every rule that names it behind:
    /// - `.nanoteams` and `.git` in the work folder (Feature 2 / V1);
    /// - the work folder ITSELF and each of its ancestors up to `/` (F6 S3, D-M19, 2026-11-12):
    ///   `mv "$PWD" "$PWD-x"` moved the folder out from under every `(subpath <work> …)` deny —
    ///   `.nanoteams/internal`, `.git/hooks` — and recreating an empty folder at the old name
    ///   handed the next step a tree the app never wrote. A role has no reason to rename or
    ///   remove the folder it works in, or anything above it.
    static func ancestorLockLiterals(work: String) -> [String] {
        var nodes = [
            (work as NSString).appendingPathComponent(NTMSPaths.nanoteamsDirName),
            (work as NSString).appendingPathComponent(".git"),
        ]
        var node = (work as NSString).standardizingPath
        while true {
            nodes.append(node)
            let parent = (node as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != node else { break }
            node = parent
        }
        return bothSpellings(nodes)
    }

    /// Where git, in the work folder's own repository, reads a command to run or another
    /// repository to use — writable by nothing a role runs (F6 S2, D-M19, 2026-11-12).
    ///
    /// `.git/hooks` and `.git/config` were the first two (2026-11-08: `core.fsmonitor` is a shell
    /// command the NEXT `git status` runs, in the app's process, outside this sandbox). The live
    /// probe of the F6 acceptance found the rest open: `config.worktree` (read on top of
    /// `config` once `extensions.worktreeConfig` is set — another `core.fsmonitor`),
    /// `commondir` and `worktrees/` (redirect the repository's objects and refs elsewhere),
    /// `modules/` (a submodule's own config and hooks), the four `info/` files git reads as
    /// rules (`exclude`, `attributes` — whose `filter` / `diff` drivers name commands —,
    /// `sparse-checkout`, `grafts`) and `objects/info/{alternates,http-alternates}` (borrow
    /// objects from another store). And the `.git` NODE: created by a role, as a directory or as
    /// a gitfile `gitdir: <elsewhere>`, it points every later git in this folder — the person's
    /// own, the app's git tools — at a repository the role chose. So `git init` in the work
    /// folder's root is refused to a role; everything else under `.git` stays writable, or
    /// `git commit` / `merge` / `rebase` / `gc` (which write 25+ other entries there) would fail.
    /// A deny list of channels, not an allow list of git's own writes, for that reason.
    static func repositoryChannelDeny(work: String) -> (subpaths: [String], literals: [String]) {
        let git = (work as NSString).appendingPathComponent(".git")
        func inGit(_ relative: String) -> String { (git as NSString).appendingPathComponent(relative) }
        return (
            subpaths: bothSpellings(["hooks", "modules", "worktrees"].map(inGit)),
            literals: bothSpellings([git] + [
                "config", "config.worktree", "commondir",
                "info/exclude", "info/attributes", "info/sparse-checkout", "info/grafts",
                "objects/info/alternates", "objects/info/http-alternates",
            ].map(inGit)))
    }

    /// Each path as written AND, when it differs, where it really is.
    ///
    /// Seatbelt matches the path the KERNEL resolved, so a deny written on a link protects the
    /// link and nothing else — and a dotfiles manager (stow, dotbot, rcm, Mackup) links exactly
    /// these: `~/.claude` to `~/dotfiles/claude`, or `~/.codex/config.toml` file by file. Both
    /// spellings are emitted, so neither route reaches a store or a token (#376).
    static func bothSpellings(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths {
            for candidate in [path, SandboxPathResolver.canonicalPath(path)]
            where seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    /// The user-level files where the MCP clients people run keep their servers — and so where
    /// a bearer pasted into one by hand would sit in cleartext. Defence in depth beside the token
    /// folder, not a promise: NanoTeams generates no configuration for any of these clients
    /// (2026-11-09 — it hands out the connection facts and lets the person or their assistant
    /// write the client's own format), so a client not on this list simply keeps its file under
    /// the credential-store rule of its folder, where the folder is one. A plain list, kept
    /// short on purpose: nothing in the app reads it but the profile and the file tools.
    static func externalAgentUserConfigurationFiles(home: String) -> [String] {
        [
            "\(home)/.claude.json",
            "\(home)/.codex/config.toml",
            "\(home)/.cursor/mcp.json",
            "\(home)/.gemini/settings.json",
            "\(home)/Library/Application Support/Code/User/mcp.json",
        ]
    }

    /// Where an agent token sits on disk: the one folder NanoTeams writes token files into
    /// (`HostedMCPClientTokenFile.folder`), and the user-level client files a pasted bearer would
    /// sit in (`externalAgentUserConfigurationFiles`). Denied to every role's `bash` in EVERY
    /// profile — reads and writes, whatever Settings → Bash grants, the credential-store toggle
    /// included — and kept from the file tools by `SandboxPathResolver` (#375). One source for
    /// the folder: the token file type says where it is, so a moved folder cannot leave this
    /// list behind.
    static func externalAgentTokenLocations(home: String) -> (subpaths: [String], literals: [String]) {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        return (
            subpaths: bothSpellings([HostedMCPClientTokenFile.folder(home: homeURL).path]),
            literals: bothSpellings(externalAgentUserConfigurationFiles(home: home)))
    }

    /// The External Agents ports a role may neither connect to nor listen on: the port the server
    /// uses or would use, and the default one every client configuration starts from. Guarded
    /// whether or not External Agents is on — a role listening there while the server is off would
    /// receive the bearer of every client that connects over HTTP; only the `--mcp-stdio` bridge
    /// checks `/identify` before it sends one (#375).
    static func guardedExternalAgentsPorts(_ port: UInt16?) -> [UInt16] {
        Array(Set([port, HostedMCPConstants.defaultPort].compactMap { $0 }.filter { $0 > 0 })).sorted()
    }

    /// Every loopback port a role may neither connect to nor listen on: the External Agents ports
    /// above, the port of every configured MCP server on this machine (`mcpServerPorts(of:)`) and
    /// of every LLM server on it (`llmServerPorts(of:)`). Sorted, each port once; 0 names no port.
    static func guardedLoopbackPorts(
        externalAgentsPort: UInt16?, mcpServerPorts: [UInt16], llmServerPorts: [UInt16]
    ) -> [UInt16] {
        effectiveGuardedPorts(guardedExternalAgentsPorts(externalAgentsPort) + mcpServerPorts + llmServerPorts)
    }

    /// `ports` with the default External Agents port added — the floor no profile goes below,
    /// whoever assembled the list — sorted, each once, 0 dropped. What `profile` writes clauses
    /// for, and what a background command records it was launched under
    /// (`LoopbackPortReservations.reserve`).
    static func effectiveGuardedPorts(_ ports: [UInt16]) -> [UInt16] {
        Array(Set((ports + [HostedMCPConstants.defaultPort]).filter { $0 > 0 })).sorted()
    }

    /// The host part of a reserved port's outbound deny: `*`, every address. `localhost` covers
    /// 127.0.0.1, ::1, `0.0.0.0`, `::`, `::ffff:127.0.0.1` and this Mac's own addresses, but NOT the
    /// IPv4-mapped unspecified address: `connect([::ffff:0.0.0.0]:P)` reached a server listening on
    /// 127.0.0.1:P from inside a profile that denied `localhost:P`, stock curl included (measured
    /// 2026-11-08, review of this change). A role is therefore kept off P on every host — its
    /// `curl https://host:P/` to some remote service included, which is the price. Except the web's
    /// own ports, 80 and 443: there `*` would cut a role off HTTP and HTTPS everywhere, so a server
    /// on this machine on one of those keeps the `localhost` clause and the mapped-address route
    /// stays open (DEBTS.md D-M16). The bind deny is on every address for every port.
    static func outboundDenyHost(for port: UInt16) -> String {
        port == 80 || port == 443 ? "localhost" : "*"
    }

    /// The ports of the configured MCP servers that listen on THIS machine, sorted, each once.
    ///
    /// Why a role's `bash` must neither reach nor stand in for such a server: NanoTeams puts the
    /// server's stored bearer on every request (`MCPAuthorizer`) and redials a server that is
    /// down every 30 s, forever (`MCPConstants.reconnectBackoff`). A role listening on the port
    /// would receive that bearer — while the server is down, or beside it on the other address
    /// family, since a `localhost` URL reaches `::1` first (measured 2026-11-08 with a listener on
    /// each) — the class #375 closed for the External Agents port; and a role that can connect
    /// could call the server's tools directly, past the approval gate and the tool pins, with a
    /// token read from a `security`-made Keychain item (D-M16).
    ///
    /// Every configured server counts, switched on or off: switching one on dials it with its
    /// bearer at once, and a command a role started earlier keeps the profile it was launched
    /// with. The list is read per tool batch (`NTMSOrchestrator.seatbeltGuardedLoopbackPorts`),
    /// and a background command launched before a port joined it is stopped before that port is
    /// dialled (`LoopbackPortReservations.reserve`).
    static func mcpServerPorts(
        of configs: [MCPServerConfig],
        interfaceAddresses: Set<[UInt8]> = LoopbackHost.interfaceAddresses()
    ) -> [UInt16] {
        Array(Set(configs.compactMap { mcpServerPort(of: $0, interfaceAddresses: interfaceAddresses) })).sorted()
    }

    /// The port `config` is dialled on when that lands on this machine, or `nil` — for a remote
    /// host, a transport this build cannot run, and an address the transport would refuse: the
    /// URL is the one `MCPEndpointPolicy.validate` hands the transport (`StreamableHTTPTransport`),
    /// so what is guarded is what is dialled, and a refused URL, dialled by nobody, guards nothing.
    static func mcpServerPort(
        of config: MCPServerConfig,
        interfaceAddresses: Set<[UInt8]> = LoopbackHost.interfaceAddresses()
    ) -> UInt16? {
        guard case .http(let http) = config.transport,
              let dialled = try? MCPEndpointPolicy.validate(http.urlString)
        else { return nil }
        return loopbackPort(of: dialled, interfaceAddresses: interfaceAddresses)
    }

    /// The ports of the LLM servers on THIS machine among `baseURLStrings`, sorted, each once.
    ///
    /// Why: NanoTeams sends every prompt of every task to that server — with the LM Studio token
    /// from the Keychain — and the replies drive every role's tool calls, the Supervisor
    /// auto-answer and the Auto judges. A role listening on the port while the server is down —
    /// for its own reasons; until 2026-11-08 a role could also stop it, since `(allow signal)`
    /// reached any process of the user — would read all of it and answer as the model, the judge
    /// that approves its own next command included. Which URLs count:
    /// `NTMSOrchestrator.seatbeltLLMServerPorts`.
    static func llmServerPorts(
        of baseURLStrings: [String],
        interfaceAddresses: Set<[UInt8]> = LoopbackHost.interfaceAddresses()
    ) -> [UInt16] {
        Array(Set(baseURLStrings.compactMap { baseURLString -> UInt16? in
            let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
            return loopbackPort(of: url, interfaceAddresses: interfaceAddresses)
        })).sorted()
    }

    /// The port a connection to `url` uses when it lands on this machine
    /// (`LoopbackHost.reachesThisMachine`: loopback in any spelling, the unspecified addresses,
    /// and the Mac's own interface addresses) — the scheme's default when the address names none
    /// — or `nil`: for any other host, a scheme other than HTTP(S) or WebSocket, a port outside
    /// 1…65535, and a port written that `URL` could not read (`:99999999999999999999` parses with
    /// no port at all, measured 2026-11-08; reading that as the default would guard port 80 for a
    /// server nobody can dial).
    ///
    /// The clauses written for the port are on every host (`outboundDenyHost(for:)`), so neither a
    /// spelling of this machine nor the IPv4-mapped unspecified address reaches such a server from a
    /// role's `bash`, and no role can stand in for it on any address.
    static func loopbackPort(
        of url: URL,
        interfaceAddresses: Set<[UInt8]> = LoopbackHost.interfaceAddresses()
    ) -> UInt16? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              LoopbackHost.reachesThisMachine(host, interfaceAddresses: interfaceAddresses)
        else { return nil }
        let defaultPort: Int
        switch scheme {
        case "http", "ws": defaultPort = 80
        case "https", "wss": defaultPort = 443
        default: return nil
        }
        let port: Int
        if let written = url.port {
            port = written
        } else if URLComponents(url: url, resolvingAgainstBaseURL: false)?.rangeOfPort != nil {
            // A port was written that `URL` could not read — too large for a port, say — and
            // that is not the scheme's default: nothing dials `:80` for it. `rangeOfPort` is
            // where the written port stands, read or not (`nil` for `host:` with nothing after
            // the colon, which `URL` reads as no port) — Foundation's own parse of the
            // authority, in place of a second one here.
            return nil
        } else {
            port = defaultPort
        }
        guard (1...Int(UInt16.max)).contains(port) else { return nil }
        return UInt16(port)
    }

    /// Builds the SBPL profile text honoring the per-scope read/write grants in
    /// `permissions`. The default `permissions` reproduces the original profile:
    /// writes confined to the work folder + temp dirs, broad reads, credential
    /// reads blocked.
    static func profile(
        workFolderRoot: URL,
        permissions: BashSandboxPermissions = BashSandboxPermissions()
    ) -> String {
        profile(workFolderRoot: workFolderRoot, permissions: permissions, guardedLoopbackPorts: [])
    }

    /// `guardedLoopbackPorts` are the loopback ports no command may connect to or listen on
    /// (`guardedLoopbackPorts(externalAgentsPort:mcpServerPorts:llmServerPorts:)`); the default
    /// External Agents port is added whatever the list holds (`effectiveGuardedPorts`). `home` is
    /// the home folder whose stores and token locations are denied — `nil`, this process's own,
    /// everywhere but a test that builds a fake one to run the profile against.
    static func profile(
        workFolderRoot: URL,
        permissions: BashSandboxPermissions = BashSandboxPermissions(),
        guardedLoopbackPorts: [UInt16],
        home homeFolder: URL? = nil
    ) -> String {
        let work = canonical(workFolderRoot)
        let tmp = canonical(URL(fileURLWithPath: NSTemporaryDirectory()))
        let home = canonical(homeFolder ?? URL(fileURLWithPath: NSHomeDirectory()))
        // The app's own session temp ($TMPDIR — a subpath of /private/var/folders
        // that the sandboxed shell inherits) plus the de-facto /tmp. We deliberately
        // do NOT grant the broad /private/var/folders or /private/var/tmp: the precise
        // `tmp` already covers $TMPDIR/mktemp, and the broad parent would let commands
        // roam the whole per-user temp/cache tree.
        let tempPaths = [tmp, "/private/tmp"]

        // Credential stores — denied for reads (unless credential reads are allowed)
        // and ALWAYS denied for writes. They live under $HOME, so they must also be
        // carved out whenever the home folder itself is granted.
        let credentialSubpaths = credentialStoreSubpaths(home: home)
        let credentialLiterals = credentialStoreLiterals(home: home)

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

        // The other direction again: a work folder INSIDE a credential store — a Claude skill
        // being written at `~/.claude/skills/<name>`. The credential read deny below would take
        // the whole project with it; the project is re-allowed after it, the stores that sit
        // inside the project re-denied, and the token locations, denied dead last, stay out of
        // reach whichever way the folders nest (#375). A work folder that IS a store stays
        // denied (`workIsCredentialDir` pins).
        let tokenLocations = externalAgentTokenLocations(home: home)
        let workInsideCredential = credentialSubpaths.contains {
            $0 != work && SandboxPathResolver.isWithin(candidate: workURL, container: URL(fileURLWithPath: $0))
        }
        let credentialInsideWork = credentialSubpaths.filter {
            SandboxPathResolver.isWithin(candidate: URL(fileURLWithPath: $0), container: workURL)
        }
        let credentialLiteralsInsideWork = credentialLiterals.filter {
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
            // Only processes of THIS sandbox — the command and what it started. A role that can
            // signal any process of the user can do more than stop it: SIGUSR1 opens a running
            // `node`'s inspector on an unguarded loopback port, and a JVM answers SIGQUIT plus an
            // attach file by loading an agent — code outside this sandbox either way (review
            // 2026-11-08). Every `sandbox-exec` is its own sandbox (measured: a second instance with
            // this very profile cannot signal the first), so a later `bash` call cannot `kill` a
            // command an earlier one started; `bash_output` stops a background command instead,
            // and kills its whole process group (`BackgroundBashRegistry`).
            "(allow signal (target same-sandbox))",
            "(allow sysctl-read)",
            "(allow mach-lookup)",
            "(allow ipc-posix-shm)",
            "(allow network*)",
        ]

        // See `workInsideCredential`: after a credential deny, give the project back, then take
        // back the stores inside it. Both operations, because a project inside a client folder
        // became READ-ONLY the moment the client folders entered every profile — `git commit`
        // could not write `.git/index.lock` while Settings showed the work-folder write grant
        // ON (#376). The token deny runs after this, so a re-allowed work folder still cannot
        // reach a token file.
        func appendWorkReallowInsideCredential(_ operation: String, granted: Bool) {
            guard granted, workInsideCredential, let wc = subpathClause([work]) else { return }
            clauses.append("(allow \(operation)\n\(wc))")
            if let inner = optionalDenyClause(
                operation, subpaths: credentialInsideWork, literals: credentialLiteralsInsideWork) {
                clauses.append(inner)
            }
        }

        // The global skill and command folders NanoTeams itself reads and injects into role
        // prompts (`AgentSkillsScanner.sources`) live inside the client folders, which are
        // credential stores. Their CONTENT already reaches the model through `{roleSkills}`, so
        // a role asked to open one by hand must not be refused — while the rest of the folder,
        // credentials included, stays denied. Re-allowed only where a broader read grant would
        // otherwise have covered them.
        func appendGlobalSkillRootReallow(granted: Bool) {
            guard granted else { return }
            // As WRITTEN only. `bothSpellings` belongs on a deny, where the second spelling
            // narrows an escape; on an ALLOW it widens the grant — a skills root kept in a
            // dotfiles repo (`~/.claude/skills -> ~/dotfiles`) re-allowed the whole repo, and
            // `~/.ssh` stowed from it became readable with the default grants (review
            // 2026-11-08).
            let roots = AgentSkillsScanner.sources.compactMap(\.globalSubpath)
                .map { "\(home)/\($0)" }
            guard let allow = subpathClause(roots) else { return }
            clauses.append("(allow file-read*\n\(allow))")
            // No re-deny beneath it, and that is a property of the list rather than an
            // omission: every root is a literal `$HOME/<subpath>` of a client folder, and every
            // credential store is `$HOME/.ssh`-like or absolute — none can lie INSIDE a root.
            // The spellings are what made it possible before (a linked root resolved to a whole
            // dotfiles repository); they are gone from this allow.
        }

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
                // The justification is "a broader read grant would otherwise have covered
                // them" — with Home: Read off, no grant does (review 2026-11-08).
                appendGlobalSkillRootReallow(granted: permissions.homeRead)
                appendWorkReallowInsideCredential("file-read*", granted: permissions.workFolderRead)
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
            let credentialsDenied = !permissions.credentialRead
                && (permissions.homeRead || (permissions.workFolderRead && workCoversCredential))
            if credentialsDenied {
                denySubpaths.append(contentsOf: credentialSubpaths)
                denyLiterals.append(contentsOf: credentialLiterals)
            }
            if let readDeny = optionalDenyClause("file-read*", subpaths: denySubpaths, literals: denyLiterals) {
                clauses.append(readDeny)
            }
            if credentialsDenied {
                appendGlobalSkillRootReallow(granted: permissions.homeRead)
                appendWorkReallowInsideCredential("file-read*", granted: permissions.workFolderRead)
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
            appendWorkReallowInsideCredential("file-write*", granted: permissions.workFolderWrite)
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
            let credentialWritesDenied = permissions.homeWrite
                || (permissions.workFolderWrite && workCoversCredential)
            if credentialWritesDenied {
                denySubpaths.append(contentsOf: credentialSubpaths)
                denyLiterals.append(contentsOf: credentialLiterals)
            }
            if let writeDeny = optionalDenyClause("file-write*", subpaths: denySubpaths, literals: denyLiterals) {
                clauses.append(writeDeny)
            }
            if credentialWritesDenied {
                appendWorkReallowInsideCredential(
                    "file-write*", granted: permissions.workFolderWrite)
            }
        }

        // ---- Agent token locations & private internal state: denied whatever the grants say (#375, #V1) ----
        // After every read and write clause, so no grant — the credential-store toggle, a home
        // or `/` grant, the work re-allow above — reaches a token file or a configuration that
        // carries one, `.nanoteams/internal`, or machine stores (mcp, agent-access, skills, benchmarks).
        let privateSubpaths = privateStateSubpaths(work: work, home: home)
        if let tokenAndPrivateDeny = optionalDenyClause(
            "file-read* file-write*",
            subpaths: tokenLocations.subpaths + privateSubpaths,
            literals: tokenLocations.literals
        ) {
            clauses.append(tokenAndPrivateDeny)
        }

        // ---- Ancestor bypass lock: moving/unlinking .nanoteams and .git denied (#V1) ----
        // Seatbelt matches on paths, not inodes: moving .nanoteams or .git to a temporary
        // name would bypass subpath/literal denies. Locking unlink/rename on literal root
        // nodes blocks the bypass while leaving inner git files writable.
        let ancestorLiterals = ancestorLockLiterals(work: work)
        if let ancestorDeny = optionalDenyClause("file-write-unlink", subpaths: [], literals: ancestorLiterals) {
            clauses.append(ancestorDeny)
        }

        // ---- The work folder's own agent configurations: readable, never writable (#376) ----
        // A role that rewrites `.mcp.json` — or `.claude/settings.json`, or `.vscode/mcp.json` —
        // hands itself a proxy that is not in this sandbox at all: the next time the person runs
        // that client in this folder, it fetches the agent token the role's own tools may
        // not read, or dials a port the role is listening on. The file tools refuse the same
        // names (`SandboxPathResolver.isAgentConfiguration`), and reads stay allowed.
        // The repository's own exec and redirect channels (`repositoryChannelDeny`) ride the same
        // clause. The REST of `.git` stays writable, or `bash`'s own `git commit` could not write
        // the index (#382).
        let repositoryChannels = repositoryChannelDeny(work: work)
        if let configDeny = optionalDenyClause(
            "file-write*",
            subpaths: repositoryChannels.subpaths,
            literals: bothSpellings(
                SandboxPathResolver.projectAgentConfigurationPaths.map {
                    (work as NSString).appendingPathComponent($0)
                }) + repositoryChannels.literals
        ) {
            clauses.append(configDeny)
        }

        // ---- Reserved loopback ports: no connect, no listen (DEAD LAST, §10.2.3, #375) ----
        // SBPL is last-match-wins, and `(allow network*)` appears at the top of the profile.
        // The External Agents ports: the outbound deny keeps sandboxed bash off NanoTeams's own
        // listener; the bind deny keeps it from standing in for that listener — on every address,
        // the wildcards and both families included — while the server is off or moving, when a
        // client connecting over HTTP would hand it its bearer. The ports of the MCP and LLM servers
        // on this machine get the same two clauses for the same reason in the other direction:
        // NanoTeams is the client there, and every request it sends carries that server's bearer,
        // every prompt, or both (`mcpServerPorts(of:)`, `llmServerPorts(of:)`). The outbound
        // clause names every host (`outboundDenyHost(for:)`): `localhost` alone left the
        // IPv4-mapped unspecified address open to the server on 127.0.0.1.
        for port in effectiveGuardedPorts(guardedLoopbackPorts) {
            clauses.append("(deny network-outbound (remote tcp \"\(outboundDenyHost(for: port)):\(port)\"))")
            clauses.append("(deny network-bind (local tcp \"*:\(port)\"))")
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
    /// `realpath` requires every component to exist, and the fallback keeps the path as
    /// written — which is the right answer for a path that does not exist (no access can reach
    /// it) but was the WRONG premise about the credential paths: being interpolated from a
    /// canonical `home` does not make `$HOME/.claude` canonical, because `.claude` itself may be
    /// a link, and a deny written on a link protects the link. Those paths now go through
    /// `bothSpellings`, which canonicalizes each one in addition to keeping it (#376).
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
