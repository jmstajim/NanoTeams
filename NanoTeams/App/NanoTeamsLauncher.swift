import Darwin
import Foundation
import SwiftUI

/// Application entry point (`@main`) that intercepts `--mcp-stdio` before SwiftUI starts (§7.4).
///
/// When launched normally (or as the `TEST_HOST` bundle during `xcodebuild test`), delegates
/// immediately to `NanoTeamsApp.main()`. When launched with `--mcp-stdio`, runs the native
/// `HostedMCPStdioRelay` against the local Hosted MCP server without initializing SwiftUI.
@main
enum NanoTeamsLauncher {

    nonisolated enum LaunchMode: Equatable, Sendable {
        case app
        /// `tokenProblem` says why there is no token when a `--token-file` named one that could
        /// not be used; the relay answers every request with it.
        case mcpStdio(port: UInt16, token: String?, tokenProblem: String? = nil)
    }

    nonisolated static let mcpStdioFlag = "--mcp-stdio"

    nonisolated static func resolveLaunchMode(
        arguments: [String],
        environment: [String: String],
        configuredPort: Int? = nil
    ) -> LaunchMode {
        guard arguments.contains(mcpStdioFlag) else {
            return .app
        }
        let port = HostedMCPStdioRelay.resolvePort(
            arguments: arguments,
            environment: environment,
            configuredPort: configuredPort
        )
        let token = HostedMCPStdioRelay.resolveToken(arguments: arguments)
        return .mcpStdio(port: port, token: token.value, tokenProblem: token.problem)
    }

    /// `NANOTEAMS_TOKEN` was in the environment this process started with — set for the person's
    /// whole session, most likely, by an instruction this app gave until 2026-11-08. Scrubbed
    /// here at once; Settings → External Agents says so, because every other program started in
    /// that session still carries it where a role's `bash` can read it (#375).
    nonisolated(unsafe) static var inheritedTokenAtLaunch = false

    /// Removes `name` from the process environment, and first overwrites its value where the
    /// kernel keeps it. `unsetenv` alone only unlinks the entry from `environ`: the bytes stay in
    /// the block `exec` laid out, and `sysctl` `KERN_PROCARGS2` hands that block to any process of
    /// the same user — a role's sandboxed `bash` included, no Seatbelt clause stops it (measured
    /// 2026-11-08, #375). Writing through the pointer `getenv` returns changes what that read
    /// sees, since at launch nothing has copied the value elsewhere yet.
    nonisolated static func scrubEnvironmentVariable(_ name: String) {
        if let value = getenv(name) {
            memset(value, 0, strlen(value))
        }
        unsetenv(name)
    }

    /// The port Settings → External Agents stored, if one was: the bridge's fallback when neither
    /// `--port` nor `NANOTEAMS_MCP_PORT` names a port. Read the way `StoreConfiguration` reads it,
    /// so the bridge dials the port the app binds.
    nonisolated static func storedExternalAgentsPort(in defaults: any ConfigurationStorage) -> Int? {
        guard let port = defaults.object(forKey: UserDefaultsKeys.externalAgentsPort) as? Int, port > 0 else {
            return nil
        }
        return port
    }

    /// Routes the launch. It scrubs `NANOTEAMS_TOKEN` from the process environment first, in both
    /// modes (`scrubEnvironmentVariable`): the bridge reads its token from `--token-file` only, and
    /// the app is the parent of every role's `bash`, whose processes read the app's environment
    /// like any other (review 2026-11-08). In `--mcp-stdio` mode it exits with the relay's code.
    ///
    /// Each process-wide effect is a parameter — the stored port (`defaults`), the environment
    /// scrub, the relay bound to the real standard input, the exit — because the test host is
    /// `NanoTeams.app` itself: its `UserDefaults.standard` holds the developer's live preferences,
    /// and its environment and standard input are shared by every test in the process.
    @discardableResult
    static func dispatch(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configuredPort: Int? = nil,
        defaults: any ConfigurationStorage = UserDefaults.standard,
        scrubEnvironmentVariable: (String) -> Void = { NanoTeamsLauncher.scrubEnvironmentVariable($0) },
        noteInheritedToken: () -> Void = { NanoTeamsLauncher.inheritedTokenAtLaunch = true },
        runApp: () -> Void,
        runStdioRelay: (UInt16, String?, String?) -> Int32 = { port, token, tokenProblem in
            HostedMCPStdioRelay.runWithFileDescriptors(
                port: port, rawToken: token, tokenProblem: tokenProblem, stdinFD: STDIN_FILENO)
        },
        exitProcess: (Int32) -> Void = { Darwin.exit($0) }
    ) -> LaunchMode {
        let isStdio = arguments.contains(mcpStdioFlag)
        let mode = resolveLaunchMode(
            arguments: arguments,
            environment: environment,
            configuredPort: configuredPort ?? (isStdio ? storedExternalAgentsPort(in: defaults) : nil)
        )
        if environment[HostedMCPConstants.tokenEnvironmentVariable] != nil {
            noteInheritedToken()
        }
        scrubEnvironmentVariable(HostedMCPConstants.tokenEnvironmentVariable)
        switch mode {
        case .app:
            runApp()
        case .mcpStdio(let port, let token, let tokenProblem):
            exitProcess(runStdioRelay(port, token, tokenProblem))
        }
        return mode
    }

    static func main() {
        dispatch(runApp: { NanoTeamsApp.main() })
    }
}
