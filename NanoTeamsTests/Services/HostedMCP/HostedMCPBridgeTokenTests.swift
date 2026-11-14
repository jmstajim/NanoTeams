import Darwin
import XCTest
@testable import NanoTeams

/// How the `--mcp-stdio` bridge gets its token without leaving it where a role's sandboxed bash
/// reads it (#375): from the file `--token-file` names, private to the user, and from nowhere
/// else — `NANOTEAMS_TOKEN` is never read, and scrubbed in place at every launch.
final class HostedMCPBridgeTokenTests: XCTestCase {
    var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanoteams-bridge-token-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        super.tearDown()
    }

    private var token: String { "ntm_a4c36525_0f3c9b1e7d2a4c6e8b0f1a3c5e7d9b2f4a6c8e0b" }

    private func tokenFile(_ contents: String, mode: Int = 0o600, name: String = "a4c36525.token") throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - --token-file

    func testTokenFilePath_readsBothSpellings() {
        XCTAssertEqual(HostedMCPStdioRelay.tokenFilePath(in: ["NanoTeams", "--mcp-stdio", "--token-file", "/a b/t"]), "/a b/t")
        XCTAssertEqual(HostedMCPStdioRelay.tokenFilePath(in: ["NanoTeams", "--token-file=/x/t", "--mcp-stdio"]), "/x/t")
        XCTAssertNil(HostedMCPStdioRelay.tokenFilePath(in: ["NanoTeams", "--mcp-stdio"]))
        XCTAssertNil(HostedMCPStdioRelay.tokenFilePath(in: ["NanoTeams", "--mcp-stdio", "--token-file"]), "no path follows")
    }

    func testReadTokenFile_acceptsAPrivateFileAndTrimsIt() throws {
        let result = HostedMCPStdioRelay.readTokenFile(atPath: try tokenFile(token + "\n"))
        XCTAssertEqual(result.value, token)
        XCTAssertNil(result.problem)
    }

    /// A looser file is one another account, or a copy elsewhere, may have read: refused, and the
    /// reason says what to do.
    func testReadTokenFile_refusesAFileOthersCanRead() throws {
        // Write and execute bits too: a group member who may rewrite the file chooses the token
        // (a `& 0o044` check would pass these).
        for mode in [0o644, 0o640, 0o604, 0o660, 0o620, 0o602, 0o610, 0o601] {
            let result = HostedMCPStdioRelay.readTokenFile(atPath: try tokenFile(token, mode: mode, name: "m\(mode).token"))
            XCTAssertNil(result.value, "mode \(String(mode, radix: 8))")
            XCTAssertTrue(result.problem?.contains("chmod 600") == true, "\(String(describing: result.problem))")
        }
    }

    func testReadTokenFile_saysWhyItHasNoToken() throws {
        let missing = HostedMCPStdioRelay.readTokenFile(atPath: folder.appendingPathComponent("absent.token").path)
        XCTAssertNil(missing.value)
        XCTAssertTrue(missing.problem?.contains("does not exist") == true, "\(String(describing: missing.problem))")
        // Revoking an agent removes its file: the answer names that, not only "reissue".
        XCTAssertTrue(missing.problem?.contains("revoked") == true, "\(String(describing: missing.problem))")

        // Something that is not an agent token — Claude Code's headers file, say — is named as such,
        // not answered with "give the bridge --token-file" when it was given one.
        let headers = HostedMCPStdioRelay.readTokenFile(
            atPath: try tokenFile(#"{"Authorization":"Bearer \#(token)"}"#, name: "headers.json"))
        XCTAssertNil(headers.value)
        XCTAssertTrue(headers.problem?.contains("does not hold an agent token") == true, "\(String(describing: headers.problem))")

        let empty = HostedMCPStdioRelay.readTokenFile(atPath: try tokenFile(" \n"))
        XCTAssertNil(empty.value)
        XCTAssertTrue(empty.problem?.contains("is empty") == true, "\(String(describing: empty.problem))")

        let directory = HostedMCPStdioRelay.readTokenFile(atPath: folder.path)
        XCTAssertNil(directory.value)
        XCTAssertNotNil(directory.problem)

        let large = HostedMCPStdioRelay.readTokenFile(
            atPath: try tokenFile(String(repeating: "a", count: HostedMCPStdioRelay.maxTokenFileBytes + 1), name: "big.token"))
        XCTAssertNil(large.value)
        XCTAssertTrue(large.problem?.contains("too large") == true, "\(String(describing: large.problem))")
    }

    /// A link is not followed: the file NanoTeams writes is a regular file, and a link could
    /// point the bridge at a token of somebody else's choosing.
    func testReadTokenFile_doesNotFollowALink() throws {
        let target = try tokenFile(token)
        let link = folder.appendingPathComponent("link.token")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        let result = HostedMCPStdioRelay.readTokenFile(atPath: link.path)
        XCTAssertNil(result.value)
        XCTAssertNotNil(result.problem)
    }

    /// The token comes from `--token-file` or not at all: the environment is never read, whatever
    /// it holds — a token there is one a role's sandboxed `bash` reads (#375).
    func testResolveToken_comesFromTheFileOnly() throws {
        let path = try tokenFile(token)
        XCTAssertEqual(HostedMCPStdioRelay.resolveToken(arguments: ["--token-file", path]).value, token)

        let refused = try tokenFile(token, mode: 0o644, name: "loose.token")
        let fromRefused = HostedMCPStdioRelay.resolveToken(arguments: ["--token-file", refused])
        XCTAssertNil(fromRefused.value)
        XCTAssertNotNil(fromRefused.problem)

        let none = HostedMCPStdioRelay.resolveToken(arguments: [])
        XCTAssertNil(none.value)
        XCTAssertNil(none.problem, "no flag: the generic missing-token answer")
        XCTAssertEqual(
            NanoTeamsLauncher.resolveLaunchMode(
                arguments: ["NanoTeams", "--mcp-stdio", "--port", "51333"],
                environment: [HostedMCPConstants.tokenEnvironmentVariable: token]),
            .mcpStdio(port: 51333, token: nil, tokenProblem: nil),
            "a token in the environment is not taken")
    }

    /// The scrub runs on every launch, the app's own included — the app is the parent of every
    /// role's `bash` — and an inherited token is noted for Settings → External Agents.
    @MainActor
    func testDispatch_scrubsAndNotesAnInheritedTokenInBothModes() async {
        for arguments in [["NanoTeams"], ["NanoTeams", "--mcp-stdio", "--port", "51333"]] {
            var effects: [String] = []
            NanoTeamsLauncher.dispatch(
                arguments: arguments,
                environment: [HostedMCPConstants.tokenEnvironmentVariable: token],
                configuredPort: 47321,
                defaults: InMemoryConfigurationStorage(),
                scrubEnvironmentVariable: { effects.append("scrub \($0)") },
                noteInheritedToken: { effects.append("noted") },
                runApp: { effects.append("app") },
                runStdioRelay: { _, token, _ in effects.append("relay \(token ?? "nil")"); return 0 },
                exitProcess: { _ in })
            XCTAssertEqual(effects.prefix(2), ["noted", "scrub NANOTEAMS_TOKEN"], "\(arguments): \(effects)")
            XCTAssertFalse(effects.contains("relay \(token)"), "the environment's token is never relayed")
        }
        var quiet: [String] = []
        NanoTeamsLauncher.dispatch(
            arguments: ["NanoTeams"], environment: [:], configuredPort: 47321,
            defaults: InMemoryConfigurationStorage(),
            scrubEnvironmentVariable: { _ in }, noteInheritedToken: { quiet.append("noted") }, runApp: {},
            exitProcess: { _ in })
        XCTAssertEqual(quiet, [], "nothing inherited, nothing noted")
    }

    func testResolveLaunchMode_carriesTheTokenFileOrItsProblem() throws {
        let path = try tokenFile(token)
        XCTAssertEqual(
            NanoTeamsLauncher.resolveLaunchMode(
                arguments: ["NanoTeams", "--mcp-stdio", "--port", "51333", "--token-file", path], environment: [:]),
            .mcpStdio(port: 51333, token: token, tokenProblem: nil))
        guard case .mcpStdio(_, nil, let problem?) = NanoTeamsLauncher.resolveLaunchMode(
            arguments: ["NanoTeams", "--mcp-stdio", "--token-file", folder.appendingPathComponent("absent").path],
            environment: [:])
        else {
            return XCTFail("a missing token file is a launch with no token and a reason")
        }
        XCTAssertTrue(problem.contains("does not exist"), problem)
    }

    // MARK: - The environment, scrubbed where the kernel keeps it

    /// The scrub in this process: the variable is gone, and scrubbing one that is not there is
    /// harmless — the launcher calls it on every `--mcp-stdio` launch, token or not. What the
    /// kernel shows of a launched bridge is the next test's business.
    func testScrubEnvironmentVariable_removesItAndToleratesAnAbsentOne() {
        let name = "NT_SCRUB_PROBE_\(UUID().uuidString.prefix(8))"
        setenv(name, "ntm_deadbeef_secret", 1)
        XCTAssertNotNil(getenv(name))
        NanoTeamsLauncher.scrubEnvironmentVariable(name)
        XCTAssertNil(getenv(name))
        NanoTeamsLauncher.scrubEnvironmentVariable(name)
        XCTAssertNil(getenv(name))
    }

    /// The bridge launched the old way — `NANOTEAMS_TOKEN` in its environment — must not leave
    /// the token where `sysctl` `KERN_PROCARGS2` reads it: that read needs no privilege and no
    /// Seatbelt clause stops it, so a role's sandboxed bash could collect it for the bridge's
    /// whole life. `unsetenv` alone left it there. Run against the real binary: the test host IS
    /// NanoTeams.app, so `--mcp-stdio` routes to the relay, which with stdin held open sends
    /// nothing anywhere.
    func testBridgeProcess_leavesNoTokenInItsKernelVisibleEnvironment() throws {
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--mcp-stdio", "--port", "1"]
        // No profile file for a coverage-instrumented child, and its cwd a folder of its own.
        var environment = ["NANOTEAMS_TOKEN": token, "NT_PROBE_KEPT": "still-here", "LLVM_PROFILE_FILE": "/dev/null"]
        environment["HOME"] = ProcessInfo.processInfo.environment["HOME"]
        process.environment = environment
        process.currentDirectoryURL = folder
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        // The probe variable proves the read works; the token must be gone from the same read —
        // every byte of it, not merely the whole string (a scrub that zeroed only the first byte,
        // or `strlen(name)` bytes, would leave the secret readable and pass a whole-token check).
        var lastRead = Data()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let read = Self.kernelArgumentsAndEnvironment(of: process.processIdentifier) {
                lastRead = read
                if read.range(of: Data("NT_PROBE_KEPT=still-here".utf8)) != nil, Self.isScrubbed(token, in: read) {
                    break
                }
            }
            usleep(50_000)
        }
        XCTAssertNotNil(lastRead.range(of: Data("NT_PROBE_KEPT=still-here".utf8)), "the read reaches the environment")
        XCTAssertTrue(Self.isScrubbed(token, in: lastRead), "the token is still where any process can read it")
        XCTAssertTrue(process.isRunning, "the bridge was alive when it was read")
    }

    /// The bytes after `NANOTEAMS_TOKEN=` are all zero for the token's whole length, and no
    /// 8-byte window of its secret survives anywhere in the block.
    static func isScrubbed(_ token: String, in block: Data) -> Bool {
        let bytes = [UInt8](block)
        let name = Array("NANOTEAMS_TOKEN=".utf8)
        if let start = (0...(max(0, bytes.count - name.count))).first(where: { Array(bytes[$0..<min(bytes.count, $0 + name.count)]) == name }) {
            let value = bytes[(start + name.count)..<min(bytes.count, start + name.count + token.utf8.count)]
            guard value.allSatisfy({ $0 == 0 }) else { return false }
        }
        let secret = Array(token.utf8.split(separator: UInt8(ascii: "_")).last ?? [])
        guard secret.count >= 8 else { return true }
        return !(0...(secret.count - 8)).contains { offset in
            block.range(of: Data(secret[offset..<(offset + 8)])) != nil
        }
    }

    /// `sysctl` `KERN_PROCARGS2`: what any process of the same user reads of another.
    static func kernelArgumentsAndEnvironment(of pid: pid_t) -> Data? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Data(buffer[..<size])
    }
}
