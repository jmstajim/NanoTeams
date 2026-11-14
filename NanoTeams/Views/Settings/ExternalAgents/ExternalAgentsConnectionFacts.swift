import AppKit
import Foundation

/// The facts a client needs to connect to the hosted server, as fields a person copies into
/// their own client's configuration — and the words around the token for the External Agents
/// tab and the agent sheet (§10.1, §10.2.5, §11, and Appendix C).
///
/// Until 2026-11-09 this type generated a configuration per client — Claude Code's `claude mcp
/// add-json` line with a `headersHelper`, Codex's TOML, Cursor's and Gemini CLI's `mcpServers`
/// entries, VS Code's `promptString` input, Claude Desktop's bridge entry — and the agent's
/// record kept which client it was for. That was knowledge about other people's configuration
/// formats, which change on their release schedules and which nothing here could verify (DEBTS
/// D-M6: two of the six were never run live). What NanoTeams owns is the facts: the bridge and
/// its arguments, the address, the call timeout the longest wait needs. Those are the fields;
/// the client's format is the person's or their assistant's business (`ExternalAgentsSetupPrompt`).
///
/// **Every fact is an agent's** (2026-11-12). Until then the Settings page drew the same fields
/// for nobody, with `<agent-id>` where the id goes: three of its six were templates with no Copy,
/// the other three were no use alone, and the sheet showed all of them filled in at the two
/// moments a person connects a client — after Add, and from the agent's row. The page's card
/// went, and with it the placeholder, the template flag and two fields that were never values a
/// client takes: the `Authorization` header (a sentence, now the endpoint's) and the token file
/// (a path already inside the bridge arguments).
///
/// Every route keeps the token out of an environment variable, a process's arguments and the
/// work folder (#375): the bridge reads it from a file NanoTeams writes (`HostedMCPClientTokenFile`),
/// and a client that sends it in a header gets it copied once, as a secret. The endpoint uses
/// `127.0.0.1:<port>` (never `localhost`) per Appendix C.
nonisolated enum ExternalAgentsConnectionFacts {

    /// The two ways a client reaches the server, and what both need. They are ALTERNATIVES: a
    /// flat list of every field left the person to work out that a client takes either the
    /// command and its arguments or the address and a header.
    nonisolated enum Route: String, CaseIterable, Sendable {
        case bridge
        case http
        case both

        /// The line over the route's fields: what it is, and which client takes it.
        var title: String {
            switch self {
            case .bridge: "Bridge — for a client that speaks stdio"
            case .http: "HTTP — for a client that sends the token itself"
            case .both: "Either way"
            }
        }
    }

    /// One fact, with the words a person needs to put it where their client wants it.
    nonisolated struct Field: Equatable, Identifiable, Sendable {
        nonisolated enum Kind: String, CaseIterable, Sendable {
            case bridgeCommand
            case bridgeArguments
            case endpoint
            case callTimeout

            var route: Route {
                switch self {
                case .bridgeCommand, .bridgeArguments: .bridge
                case .endpoint: .http
                case .callTimeout: .both
                }
            }
        }

        let kind: Kind
        let title: String
        /// What Copy takes, as is: nothing in a value is left to fill in.
        let value: String
        let caption: String

        var id: String { kind.rawValue }
        var route: Route { kind.route }
    }

    /// One route's fields, under its title.
    nonisolated struct Group: Equatable, Identifiable, Sendable {
        let route: Route
        let fields: [Field]

        var id: String { route.rawValue }
        var title: String { route.title }
    }

    /// Stands where the token goes in the header a client sends: the token itself is copied as a
    /// secret on its own (`ExternalAgentsPasteboard.copySecret`), and no field or prompt carries it.
    static let tokenPlaceholder = "<token>"

    static let defaultExecutablePath = "/Applications/NanoTeams.app/Contents/MacOS/NanoTeams"

    /// The binary actually running — the stdio bridge is this executable with `--mcp-stdio`, so
    /// a copy launched from anywhere but /Applications needs its own path in the field. The
    /// fixed default is only the fallback for a bundle that reports none.
    static var runningExecutablePath: String {
        Bundle.main.executablePath ?? defaultExecutablePath
    }

    static func endpointURLString(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/mcp"
    }

    /// The agent's token file by absolute path — never `~`: a client, or an assistant setting
    /// one up, may run with another HOME (review 2026-11-08). The same path
    /// `HostedMCPClientTokenFile.location(shortID:home:)` writes to, built from the folder and
    /// extension that type owns so it has no failure to carry.
    static func tokenFilePath(shortID: String, home: URL) -> String {
        HostedMCPClientTokenFile.folder(home: home)
            .appendingPathComponent("\(shortID).\(HostedMCPClientTokenFile.fileExtension)", isDirectory: false)
            .path
    }

    /// What follows the bridge command: the mode, and the token file it reads
    /// (`HostedMCPStdioRelay.tokenFileFlag`). Three words a client's `args` takes one by one; the
    /// token folder has no space in its path, so they also paste into a shell as they are.
    static func bridgeArguments(tokenFilePath: String) -> String {
        "\(NanoTeamsLauncher.mcpStdioFlag) \(HostedMCPStdioRelay.tokenFileFlag) \(tokenFilePath)"
    }

    /// The call timeout a client needs, in seconds: the relay's own ceiling, with the margin over
    /// the longest `wait_for_events` that a reply leaving after its deadline needs (#368).
    static let callTimeoutSeconds = HostedMCPConstants.clientCallTimeoutSeconds

    /// An agent's fields, route by route: the bridge first — the route that leaves no token in
    /// the client's configuration — then the address, then the one number nobody guesses.
    static func fields(
        port: UInt16 = HostedMCPConstants.defaultPort,
        executablePath: String = defaultExecutablePath,
        home: URL,
        shortID: String
    ) -> [Field] {
        [
            Field(
                kind: .bridgeCommand, title: "Command", value: executablePath,
                caption: "This copy of NanoTeams relays to the server and reads the token from its file, so the client's configuration holds no secret."),
            Field(
                kind: .bridgeArguments, title: "Arguments",
                value: bridgeArguments(tokenFilePath: tokenFilePath(shortID: shortID, home: home)),
                caption: "Three arguments, in this order. The file holds this agent's token alone, readable by you only: written when the agent is added, replaced on a reissue, removed on revoke."),
            Field(
                kind: .endpoint, title: "Endpoint", value: endpointURLString(port: port),
                caption: "Streamable HTTP, at this literal address, not localhost. Send Authorization: Bearer \(tokenPlaceholder) on every request; the token is copied once, and NanoTeams keeps only a hash of it."),
            Field(
                kind: .callTimeout, title: "Call timeout", value: String(callTimeoutSeconds),
                caption: "Seconds. \(ExternalAutovisorToolNames.waitForEvents) holds a call for up to an hour and its reply leaves after the deadline; give the client at least this per call, in its own unit."),
        ]
    }

    /// The fields under their routes, in `Route`'s order; a route with no field is left out.
    static func groups(_ fields: [Field]) -> [Group] {
        Route.allCases.compactMap { route in
            let own = fields.filter { $0.route == route }
            return own.isEmpty ? nil : Group(route: route, fields: own)
        }
    }

    // MARK: - The words around the token

    /// Under the fields a person sets up by hand: where the configuration goes and where the
    /// token never does — the rules a person keeps, said where the configuration is written
    /// (the agent sheet; on the Settings page until 2026-11-12). The setup prompt says them to
    /// the assistant (`ExternalAgentsSetupPrompt.rules`).
    static let placementRules: String =
        "Put the configuration in your client's user-level file, outside every work folder. The token never goes in an environment variable, on a command line or in a file inside a work folder: your roles' bash reads all three."

    /// The line beside Copy token: where the token went — and, for a reissue or a failed file,
    /// what is left to do. A first issue says only where: who copies the token is the sheet's
    /// one note under the blocks (`ExternalAgentSheet.tokenNote`), and until 2026-11-12 this
    /// line said it a second time, once per agent.
    static func handoffLine(delivery: HostedMCPTokenHandoff.Delivery, isReissue: Bool, home: URL) -> String {
        switch delivery {
        case .written(let url):
            let path = HostedMCPClientTokenFile.displayPath(url, home: home)
            return isReissue
                ? "New token written to \(path). A client that runs the bridge reads it at its next start; one that sends it in a header needs the new token."
                : "Token written to \(path). The bridge reads it from there."
        case .notWritten(_, let reason):
            return "\(reason) The bridge cannot connect until a reissue writes the file; copy the token now for a client that sends it in a header."
        }
    }

    /// Under the port field after Apply moved the port. An ABANDONED non-default port is no
    /// longer guarded in the step profiles (`47321` always is), so a stale client still dialling
    /// it could reach whoever holds it — which is why the hint asks for the change at once. The
    /// bridge reads the stored port (`NanoTeamsLauncher`), so a client that runs it needs nothing.
    static let portChangeHint: String =
        "Clients set up for the old port need the new address in their configuration now. A client that runs the bridge needs nothing: the bridge reads the port from Settings."

    /// Honest threat-boundary summary (§10.1 & §11): what the token does not keep out, in words —
    /// the tool identifiers that once stood in brackets here say nothing to a person.
    static let honestBoundaryOneLiner: String =
        "The token keeps out web pages and other apps, not your roles: builds, tests and git hooks they run outside the sandbox can reach this server like any local program."

    /// The Agents card's footer: what one token may change, then what no token keeps out. The
    /// boundary closed the "Where the token is safe" card until that card went (2026-11-08); it is
    /// the one fact of the card a PERSON needs, so it stays on the page (CLAUDE.md #396), while
    /// the rules on where a token may live went to the setup prompt, for the assistant that sets
    /// the client up. Until 2026-11-09 the first sentence said an agent "sees only the tasks it
    /// created": `list_tasks` and `task_status` show it every top-level task (`mine` marks its
    /// own); what ownership refuses is a change.
    ///
    /// Since 2026-11-13 the first sentence also names the one write an agent can be allowed beyond
    /// its tasks, the Work Folder Context, which the roles of the person's own tasks read too
    /// (`contextPermissionTitle`).
    static let agentsCardFooter: String =
        "Each agent has its own token and changes only the tasks it created, plus the Work Folder Context if you allow it. \(honestBoundaryOneLiner)"

    /// The switch on each agent's row (2026-11-13, decision A3 revised): off until the person turns
    /// it on, because the context is the one text an agent can write that the person's own tasks read.
    static let contextPermissionTitle = "Can replace the Work Folder Context"

    /// What turning it on means — the reach, and that nothing keeps the text it replaces. The reach
    /// is the teams whose prompt carries the context (`Team.readsWorkFolderContext`): until
    /// 2026-11-13 this said "every role of every task", and the bundled Personal Assistant and
    /// Quest Party read none of it.
    static let contextPermissionCaption =
        "Roles of your own tasks read it too, on every team whose prompt includes it. NanoTeams keeps no earlier version of it to restore."

    /// What is left to remove in the CLIENT after an agent is revoked here. NanoTeams removes
    /// what it wrote — the token file, the agent — and nothing else: the entry the person added
    /// is theirs, in their own configuration, and a client left pointing at a token that is gone
    /// reports a failed server with nothing on screen to explain it (#376).
    static let removalHint: String =
        "Remove the nanoteams entry from the client's configuration too: its token file is gone, and a client that keeps dialling it reports a failed server with nothing to explain it."
}

// MARK: - Concealed Pasteboard Helper (§10.2.5)

/// Copies one-time agent tokens to `NSPasteboard` for this Mac only (`.currentHostOnly`: no
/// Universal Clipboard) and marked `org.nspasteboard.ConcealedType`, so clipboard managers do
/// not record the secret (§10.2.5) — and takes it back off: a role's sandboxed `bash` reads the
/// clipboard (`pbpaste` through `mach-lookup`, measured 2026-11-08), so a token left there is one
/// any task can collect (#375).
///
/// Until 2026-11-08 `declareTypes` followed `prepareForNewContents`: it begins a NEW pasteboard
/// generation and so dropped the local-only option set one line before (review 2026-11-08,
/// confirmed in AppKit's disassembly). The writes now go into the generation the option marked.
@MainActor
enum ExternalAgentsPasteboard {
    /// One source with whoever puts a concealed item BACK — Quick Capture's clipboard restore,
    /// which has to keep such a generation local to this Mac.
    static let concealedPasteboardType = PasteboardItemSnapshot.concealedType

    /// How long a copied token stays on the clipboard.
    static let secretLifetime: Duration = .seconds(60)

    /// How soon the clear is retried when the token was NOT on the clipboard at the moment it
    /// fired. Short, because the case it covers is a clipboard restore landing on top of it:
    /// Quick Capture's selection grab holds the clipboard for up to half a second and then puts
    /// the token back, after which nothing would have taken it off again (#376).
    static let reclearDelay: Duration = .seconds(2)

    /// The token copied last, and where — what the timer, and a quit inside its minute, take back.
    private static var pending: (pasteboard: NSPasteboard, secret: String)?

    /// Clear only the token we put there. By content, not by `changeCount`: Quick Capture's
    /// selection grab restores a snapshot of the clipboard under a new count, token included.
    nonisolated static func shouldClear(current: String?, secret: String) -> Bool {
        current == secret
    }

    /// Copies `secret` and clears it after `lifetime` if it is still there. The returned task is
    /// that clear; nothing but a test needs to await it.
    @discardableResult
    static func copySecret(
        _ secret: String, to pasteboard: NSPasteboard = .general, lifetime: Duration = secretLifetime
    ) -> Task<Void, Never> {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: concealedPasteboardType)
        pending = (pasteboard, secret)
        return Task { @MainActor in
            try? await Task.sleep(for: lifetime)
            _ = clear(secret, from: pasteboard, forgetting: false)
            // A second pass either way, because Quick Capture's selection grab snapshots the
            // clipboard and puts the snapshot BACK: the restore can land after a clear that
            // succeeded (its span is an accessibility read plus up to half a second of polling),
            // and until 2026-11-08 the handle was dropped on that success, so nothing — not even
            // the quit-time clear — ever took the token off again.
            try? await Task.sleep(for: reclearDelay)
            _ = clear(secret, from: pasteboard, forgetting: true)
        }
    }

    /// Takes the token copied last off the clipboard if it is still there — called when the app
    /// quits, so a token copied in its last minute does not outlive it.
    static func clearPendingSecret() {
        guard let pending else { return }
        _ = clear(pending.secret, from: pending.pasteboard, forgetting: true)
    }

    /// `true` when the token is no longer on the clipboard — because this call took it off, or
    /// because it was never there.
    ///
    /// `forgetting` is what makes the handle outlive a clipboard restore: a pass that is not the
    /// last one keeps `pending`, so a snapshot put back AFTER a successful clear still has an
    /// owner to take it off again. Only the final pass — and the quit-time clear — forgets.
    @discardableResult
    private static func clear(
        _ secret: String, from pasteboard: NSPasteboard, forgetting: Bool
    ) -> Bool {
        let holdsTheToken = shouldClear(current: pasteboard.string(forType: .string), secret: secret)
        if holdsTheToken { pasteboard.clearContents() }
        if forgetting, pending?.secret == secret { pending = nil }
        return holdsTheToken || pending?.secret != secret
    }

    static func copyText(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - BashSecurityWarning Display Title (§10.2.4)

nonisolated extension BashSecurityWarning {
    var title: String {
        switch self {
        case .sandboxDisabled:
            return "Bash runs without the Seatbelt sandbox"
        case .unsandboxedFallbackEnabled:
            return "Bash may fall back to running unsandboxed"
        }
    }
}

// MARK: - External Agents Settings Presentation (§11)

nonisolated struct ExternalAgentRow: Equatable, Identifiable, Sendable {
    let id: UUID
    let shortID: String
    let label: String
    let clientHint: String?
    let lastSeenAt: Date?
    let isPresent: Bool
    let openTasksCount: Int
    /// The person's switch: whether this agent may replace the Work Folder Context
    /// (`HostedMCPAgentRecord.mayReplaceWorkFolderContext`). No default: a row built without it
    /// would show the switch off for an agent the store lets write, so leaving the record's value
    /// out does not compile.
    let mayReplaceWorkFolderContext: Bool

    var presenceLabel: String {
        if isPresent {
            return "Online"
        }
        if lastSeenAt != nil {
            return "Offline"
        }
        return "Never connected"
    }

    /// The agent's facts on one wrapping line: the client hint when there is one, when it was
    /// last seen (relative — "how long ago" is the question; an online agent is being seen now)
    /// and its open tasks when it has any. EMPTY for an agent that has none of the three — one
    /// that never connected — and the row then draws no line at all. The MCP protocol version it
    /// spoke left the line on 2026-11-08 and the day it was created on 2026-11-12, by the same
    /// test: nothing a person does here depends on either.
    var detailLine: String {
        var parts: [String] = []
        if let hint = clientHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            parts.append(hint)
        }
        if let lastSeen = lastSeenAt, !isPresent {
            parts.append("Last seen \(lastSeen.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
        }
        if openTasksCount > 0 {
            parts.append(openTasksCount == 1 ? "1 open task" : "\(openTasksCount) open tasks")
        }
        return parts.joined(separator: " · ")
    }
}

nonisolated struct ExternalAgentsSettingsPresentation: Equatable, Sendable {
    nonisolated enum ListenerStatus: Equatable, Sendable {
        case disabled
        case starting
        case listening(port: UInt16)
        case portInUse(port: UInt16)
        case failed(message: String)
        case stopped

        /// Whether a restart can repair anything: a server that refused or stopped. One that is
        /// listening or still starting has nothing a restart would change; one switched off is
        /// turned on by its switch.
        var offersRestart: Bool {
            switch self {
            case .portInUse, .failed, .stopped: true
            case .disabled, .starting, .listening: false
            }
        }
    }

    let listenerStatus: ListenerStatus
    /// The state in one or two words — what the status badge says: "Listening", "Off",
    /// "Starting…", "Port in use", "Not started", "Stopped". Until the design review of
    /// 2026-11-07 the badge spelled the whole sentence, address included, in 10pt capitals.
    let listenerStatusTitle: String
    /// Where the server is, or would be — "127.0.0.1:47321 / [::1]:47321", "port 47321" — beside the
    /// badge in the ordinary mono caption, where an address can be read and selected. `nil`
    /// when there is no address to name (switched off, or refused for a reason that is not a port).
    let listenerAddressText: String?
    /// The caption under the card: what the state means and what to do about it. `nil` for a
    /// port in use — the card's own block says it, with the risk and the button.
    let listenerStatusDetail: String?
    let recommendsTokenRotation: Bool
    let agentRows: [ExternalAgentRow]
    let bashWarnings: [BashSecurityWarning]
    /// Said when NanoTeams started with `NANOTEAMS_TOKEN` in its environment
    /// (`NanoTeamsLauncher.inheritedTokenAtLaunch`): scrubbed from this app, still in every other
    /// program of that session, where a role's `bash` reads it (#375).
    var environmentTokenWarning: String? = nil

    static let environmentTokenWarningText =
        "NANOTEAMS_TOKEN was set in the environment NanoTeams started with. Remove it where you set it (a shell profile, launchctl setenv), restart the apps that inherited it, and reissue that agent's token: any program you run, your roles' bash included, can read another's environment."

    /// The Agents card with nobody on it: what adding one gives. The page shows no connection
    /// facts of its own (2026-11-12), so this is where it says they come with the agent.
    static let noAgentsHint = "No agents yet. Add one to get its token and what a client needs to connect."

    /// Apply is offered only for a port that is not the stored one — a draft that names it,
    /// spaces around it included, has nothing to apply. A draft that is no number at all still
    /// gets the button, so pressing it says what a port is.
    static func showsApply(portDraft: String, storedPort: Int) -> Bool {
        portDraft.trimmingCharacters(in: .whitespacesAndNewlines) != String(storedPort)
    }

    /// The existing agent's label that `draft` repeats (case-insensitively), or `nil`. An empty
    /// draft repeats nothing: Add names it the default label, and the placeholder says so.
    static func duplicateLabel(_ draft: String, among rows: [ExternalAgentRow]) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return rows.first { $0.label.caseInsensitiveCompare(trimmed) == .orderedSame }?.label
    }

    /// The state as one sentence — "Listening on 127.0.0.1:47321 / [::1]:47321", "Port 47321 is in
    /// use" — for a surface that has one line for it (the External Autovisor pane's header).
    var listenerStatusSentence: String {
        switch listenerStatus {
        case .listening: "Listening on \(listenerAddressText ?? "")"
        case .starting: "Starting on \(listenerAddressText ?? "")…"
        case .portInUse(let port): "Port \(port) is in use"
        case .failed(let message): message
        case .disabled, .stopped: listenerStatusTitle
        }
    }

    static func formatListenerStatus(
        enabled: Bool,
        configuredPort: UInt16,
        state: HostedMCPListenerState
    ) -> String {
        make(
            externalAgentsEnabled: enabled,
            configuredPort: configuredPort,
            listenerState: state,
            agents: [],
            presenceByAgent: [:],
            openTasksByAgent: [:],
            bashWarnings: []
        ).listenerStatusSentence
    }

    /// The caption for a server that is up or coming up — the same words for both, so it does
    /// not jump when the sockets open, and no transport names: the connection facts carry those.
    static let reachableOnlyHere = "Reachable only from this Mac."

    static func make(
        externalAgentsEnabled: Bool,
        configuredPort: UInt16,
        listenerState: HostedMCPListenerState,
        agents: [HostedMCPAgentRecord],
        presenceByAgent: [UUID: Bool],
        openTasksByAgent: [UUID: Int],
        bashWarnings: [BashSecurityWarning],
        inheritedTokenAtLaunch: Bool = false
    ) -> ExternalAgentsSettingsPresentation {
        let status: ListenerStatus
        let title: String
        let address: String?
        let detail: String?
        let recommendsRotation: Bool

        if !externalAgentsEnabled {
            status = .disabled
            title = "Off"
            address = nil
            detail = "Turn it on to let agents on this Mac connect."
            recommendsRotation = false
        } else {
            switch listenerState {
            case .listening(let port):
                status = .listening(port: port)
                title = "Listening"
                // Each address with its OWN port. Written "127.0.0.1 / [::1]:47321" the port
                // binds visually to the IPv6 literal alone, and because `[::1]:47321` is itself
                // a complete address the eye stops there and reads the IPv4 one as portless —
                // which is wrong twice over: the listener binds both or neither, on the same
                // port. This line is what a person reads when a client will not connect, so it
                // has to compare field for field against the client's own config and against
                // the `Host` values the server accepts (`127.0.0.1:P`, `[::1]:P`).
                address = "127.0.0.1:\(port) / [::1]:\(port)"
                detail = reachableOnlyHere
                recommendsRotation = false
            case .starting:
                status = .starting
                title = "Starting…"
                address = "port \(configuredPort)"
                detail = reachableOnlyHere
                recommendsRotation = false
            case .failed(.portInUse(let port)):
                status = .portInUse(port: port)
                title = "Port in use"
                address = "port \(port)"
                detail = nil
                recommendsRotation = true
            case .failed(let error):
                status = .failed(message: error.message)
                title = "Not started"
                address = nil
                detail = "\(error.message). Try another port, or restart the server."
                recommendsRotation = false
            case .stopped:
                status = .stopped
                title = "Stopped"
                address = "port \(configuredPort)"
                detail = "Restart the server to let agents connect."
                recommendsRotation = false
            }
        }

        let rows = agents.map { record in
            ExternalAgentRow(
                id: record.id,
                shortID: record.shortID,
                label: record.label,
                clientHint: record.clientHint,
                lastSeenAt: record.lastSeenAt,
                isPresent: presenceByAgent[record.id] ?? false,
                openTasksCount: openTasksByAgent[record.id] ?? 0,
                mayReplaceWorkFolderContext: record.mayReplaceWorkFolderContext
            )
        }

        return ExternalAgentsSettingsPresentation(
            listenerStatus: status,
            listenerStatusTitle: title,
            listenerAddressText: address,
            listenerStatusDetail: detail,
            recommendsTokenRotation: recommendsRotation,
            agentRows: rows,
            bashWarnings: bashWarnings,
            environmentTokenWarning: inheritedTokenAtLaunch ? environmentTokenWarningText : nil
        )
    }
}

// MARK: - Autovisor Settings Driver Presentation (C7, §11)

nonisolated struct AutovisorSettingsPresentation: Equatable, Sendable {
    let driver: AutovisorDriver
    let readiness: ExternalAutovisorReadiness
    let showsModelCard: Bool
    let showsIntervalRowInActivationCard: Bool
    let showsRunNowInPowerCard: Bool
    let marksActivationTriggersBuiltInOnly: Bool
    let activationTriggersBuiltInBadgeText: String?
    let showsExternalLimits: Bool
    let maxExternalCreationsPerWindow: Int
    let externalCreationWindowMinutes: Int
    let maxOpenExternalTasks: Int
    let maxConcurrentManagedTasks: Int
    let isMemoryReadOnly: Bool
    let sleepTimerCountsFromAgentActivity: Bool
    let sleepTimerCaption: String
    /// What the Autovisor does in this folder, under the power switch. The built-in manager
    /// supervises every task; an external agent only the tasks it created (decision A3), and the
    /// Work Folder Context only where the person allows it (A3 revised, 2026-11-13).
    let powerCaption: String
    let showsGoalCard: Bool
    let showsTeamsCard: Bool
    let showsStuckCard: Bool
    let bashWarnings: [BashSecurityWarning]

    static func make(
        driver: AutovisorDriver,
        readiness: ExternalAutovisorReadiness,
        tuning: AutovisorTuning,
        bashWarnings: [BashSecurityWarning]
    ) -> AutovisorSettingsPresentation {
        let isExternal = (driver == .externalAgent)
        return AutovisorSettingsPresentation(
            driver: driver,
            readiness: readiness,
            showsModelCard: !isExternal,
            showsIntervalRowInActivationCard: !isExternal,
            showsRunNowInPowerCard: !isExternal,
            marksActivationTriggersBuiltInOnly: isExternal,
            activationTriggersBuiltInBadgeText: isExternal ? "built-in model only" : nil,
            showsExternalLimits: isExternal,
            maxExternalCreationsPerWindow: tuning.maxExternalCreationsPerWindow,
            externalCreationWindowMinutes: tuning.externalCreationWindowMinutes,
            maxOpenExternalTasks: tuning.maxOpenExternalTasks,
            maxConcurrentManagedTasks: tuning.maxConcurrentManagedTasks,
            isMemoryReadOnly: isExternal,
            sleepTimerCountsFromAgentActivity: isExternal,
            sleepTimerCaption: isExternal
                ? "Counts from the agent's last request. When it fires, the Autovisor turns off and the agent's open wait ends."
                : "Auto-disables Autovisor after this long running",
            powerCaption: isExternal
                ? "An external agent supervises the tasks it creates in this folder: it starts and stops them, answers their questions and reviews the results. Tasks you create stay yours; it replaces the Work Folder Context, which their roles read too, only if you allow it on its row."
                : "An autonomous supervisor for this folder: it watches all tasks, creates/runs/stops them, answers their questions, and keeps the goal, memory, and shared context current.",
            showsGoalCard: true,
            showsTeamsCard: true,
            showsStuckCard: true,
            bashWarnings: bashWarnings
        )
    }
}
