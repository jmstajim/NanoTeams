import Foundation

/// Environment seam for the hosted External Agents MCP server (§6, §7.1, §10.2).
nonisolated struct HostedMCPEnvironment: Sendable {
    var directoryURL: @Sendable () -> URL
    var secretStorage: @Sendable () -> any SecureTokenStorage
    var processEnvironment: @Sendable () -> [String: String]
    var allowAutoStart: Bool
    var now: @Sendable () -> Date
    /// The home folder the token folder is under (`HostedMCPClientTokenFile.folder`). The
    /// person's own only in the app: a test that wrote into the real `~/.config` would hand its
    /// token to the developer's own clients.
    var clientHomeDirectory: @Sendable () -> URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nanoteams-inert-agent-clients", isDirectory: true)
    }

    static let live = HostedMCPEnvironment(
        directoryURL: { NTMSPaths.machineStorageURL(.externalAgents) },
        secretStorage: {
            KeychainSecureTokenStorage(service: HostedMCPConstants.keychainService)
        },
        processEnvironment: {
            ProcessInfo.processInfo.environment
        },
        allowAutoStart: NSClassFromString("XCTestCase") == nil,
        now: Date.init,
        clientHomeDirectory: { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
    )

    static let inert = HostedMCPEnvironment(
        directoryURL: {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("nanoteams-inert-external-agents", isDirectory: true)
        },
        secretStorage: {
            #if DEBUG
            return InMemorySecureTokenStorage()
            #else
            return EmptySecureTokenStorage()
            #endif
        },
        processEnvironment: { [:] },
        allowAutoStart: false,
        now: Date.init
    )

    /// Scrubs `NANOTEAMS_MCP_*` and `NANOTEAMS_TOKEN` from subprocess environments (§10.2 item 1).
    static func scrubbingHostedMCPVariables(from environment: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(environment.count)
        let prefix = HostedMCPConstants.scrubbedEnvironmentPrefix.uppercased()
        let tokenVar = HostedMCPConstants.tokenEnvironmentVariable.uppercased()
        for (key, value) in environment {
            let upper = key.uppercased()
            if upper.hasPrefix(prefix) || upper == tokenVar {
                continue
            }
            result[key] = value
        }
        return result
    }

    /// Resolves the active server port from `NANOTEAMS_MCP_PORT` if valid (`1024...65535`),
    /// otherwise falls back to `configuredPort` (or `47321` if out of range) (§7.1, §10.2).
    static func resolveServerPort(
        environment: [String: String],
        configuredPort: Int
    ) -> UInt16 {
        let validRange = Int(HostedMCPConstants.minValidPort)...Int(HostedMCPConstants.maxValidPort)
        if let rawPort = environment[HostedMCPConstants.portEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let parsed = Int(rawPort),
           validRange.contains(parsed) {
            return UInt16(parsed)
        }
        if validRange.contains(configuredPort) {
            return UInt16(configuredPort)
        }
        return HostedMCPConstants.defaultPort
    }
}
