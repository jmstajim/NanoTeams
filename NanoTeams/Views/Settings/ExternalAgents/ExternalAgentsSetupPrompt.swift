import Foundation

/// The setup prompt: one text a person pastes into whatever assistant they have — the coding
/// agent running on this Mac, or a chat with no access to it at all — which then works out what
/// they have to do and tells them, or does it itself.
///
/// It carries the facts a client needs (`ExternalAgentsConnectionFacts`: the address, the
/// header, the call that runs for an hour, the bridge and its arguments, the token file
/// NanoTeams writes) and the rules on where the token may live, and it asks the assistant to
/// map them onto the client's own configuration format. No configuration of NanoTeams' own is
/// in it: until 2026-11-09 it carried six, one per client, and an assistant pasting one of those
/// was pasting a format NanoTeams could not keep current (DEBTS D-M6). The format is the
/// assistant's job — and where it does not know it, the prompt says so is the answer, not a
/// guess.
///
/// **It never carries the token**, whichever agent it is built for. A prompt is pasted into an
/// assistant, often one that is not on this Mac at all, and that is further outside than any
/// channel #375 closes: the header keeps `<token>` where the token goes, and the text tells the
/// assistant to leave it to the person. Hence a `shortID` parameter instead of a token-carrying
/// argument — there is no way to hand this function a token.
///
/// Two of its rules are about the assistant rather than the client, and neither follows from the
/// facts, so both have to be said: an assistant asked to connect ITSELF to a loopback address
/// has one obvious move — expose the port — and an assistant that does not know a client's
/// configuration format will write one that looks right.
nonisolated enum ExternalAgentsSetupPrompt {
    typealias Facts = ExternalAgentsConnectionFacts

    /// `agentShortID` is the agent's — its token file is named after it. Always an agent's: the
    /// prompt is offered where an agent exists (the hand-over, and the agent's own sheet). Until
    /// 2026-11-12 the Settings page offered it for nobody, with `<agent-id>` in the path and a
    /// paragraph sending the assistant to have the person add an agent first.
    static func text(
        port: UInt16 = HostedMCPConstants.defaultPort,
        executablePath: String = Facts.defaultExecutablePath,
        home: URL,
        agentShortID: String
    ) -> String {
        let tokenFile = Facts.tokenFilePath(shortID: agentShortID, home: home)
        return """
        \(opening)

        ## The server
        \(server(port: port, executablePath: executablePath, tokenFile: tokenFile))

        ## The token
        \(token(tokenFile: tokenFile))

        ## Where the token may and may not go
        \(rules)

        ## What I want back
        \(request)
        """
    }

    // MARK: - The pieces

    private static let opening = """
    Set up NanoTeams' MCP server in my MCP client, on this Mac.

    NanoTeams is a macOS app that runs teams of LLM roles on a work folder. It hosts an MCP \
    server, and an agent connected to it creates tasks, starts and stops them, answers their \
    questions and reads their results — and, if I allow it, replaces the folder's Work Folder \
    Context. The app is already running.

    Work out what I have to do and tell me — or do it yourself, if you are running on this Mac.
    """

    private static func server(port: UInt16, executablePath: String, tokenFile: String) -> String {
        """
        - \(Facts.endpointURLString(port: port)) — Streamable HTTP. That literal address, not localhost.
        - Authorization: Bearer \(Facts.tokenPlaceholder) on every request — the only \
        authentication; there is no OAuth.
        - Loopback only, by design. Never propose exposing it — no tunnel, no port forwarding, \
        no proxy, no third-party bridge. If you cannot reach 127.0.0.1 yourself then you are \
        not the client, and your job is to tell me what to do in the client that runs here.
        - \(ExternalAutovisorToolNames.all.count) tools, among them \
        \(ExternalAutovisorToolNames.folderStatus) and \(ExternalAutovisorToolNames.createManagedTask).
        - One call can take \(Facts.callTimeoutSeconds) seconds: \
        \(ExternalAutovisorToolNames.waitForEvents) holds the connection until something happens \
        in the folder. If the client caps a call, raise the cap to at least that, in the unit it uses.
        - A client that speaks stdio runs the bridge inside the app bundle instead, and then its \
        configuration holds no token at all: the command is \(executablePath) and its arguments \
        are \(Facts.bridgeArguments(tokenFilePath: tokenFile)) \
        — three arguments, in that order.
        """
    }

    private static func token(tokenFile: String) -> String {
        """
        I issued it in NanoTeams: Settings → External Agents → Add agent. NanoTeams wrote it to \
        \(tokenFile) — one file per agent, the bare token, readable by me only — which is what \
        the bridge reads; and it let me copy the token once, for a client that sends it in a \
        header. If I no longer have it, I reissue it there.
        """
    }

    /// Where the token may and may not live, said to the assistant that sets the client up —
    /// the sheet keeps the two a person acts on (`ExternalAgentsConnectionFacts.placementRules`);
    /// the whole list is here. Plus the two only a prompt needs: do not ask me for the token, and
    /// do not write it anywhere yourself. Not the honest boundary
    /// (`ExternalAgentsConnectionFacts.honestBoundaryOneLiner`, on the Agents card): what the
    /// token does not keep out bears on nothing an assistant decides here.
    private static let rules = """
    Keeping these is the point. An answer that is shorter because it broke one of them is wrong.
    - In the client's own configuration, at user level, outside every NanoTeams work folder.
    - Never in an environment variable: every program I run reads other processes' \
    environments, the sandboxed bash of my own roles included.
    - Never in a file inside a work folder: my teams edit those, and a role that redirects the \
    url in one collects the bearer the client sends it.
    - Never on a command line, in shell history, or in a Keychain item made with the security tool.
    - Do not ask me to paste the token into this conversation, and do not put it in anything you \
    write. Where a configuration needs the token itself, leave \(Facts.tokenPlaceholder) standing \
    and tell me to paste it in myself.
    """

    private static let request = """
    1. Which client this is for. If you are an agent with a shell on this Mac it is probably you: \
    say which one you are, set it up, and verify it. If you cannot tell which client I mean, ask \
    me, and wait for the answer.
    2. The configuration in that client's own format, mapped from the facts above — the full path \
    of the file to open, the exact text for it, and what to do afterwards: restart, reload the \
    window, /mcp, whatever that client needs. Prefer the bridge where the client speaks stdio: \
    then no token is in its file.
    3. Do not invent the client's format. If you do not know it, tell me what you need — its MCP \
    documentation, or the file where it keeps its servers — and map these facts onto that.
    4. Remind me to finish in NanoTeams: Settings → Autovisor, pick \
    \(AutovisorDriverPicker.label(for: .externalAgent)), and turn the Autovisor on for the \
    folder. Without that an agent connects but supervises nothing.
    5. How I check it: the client lists the nanoteams tools, and \
    \(ExternalAutovisorToolNames.folderStatus) answers with the folder NanoTeams has open. A 401 \
    means the token is wrong or has been reissued; a refused connection means the server is \
    off in NanoTeams (Settings → External Agents), or its port moved.
    """
}
