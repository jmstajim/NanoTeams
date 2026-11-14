import XCTest
@testable import NanoTeams

/// The token file NanoTeams hands an agent's token through (#375): where it lives, what it holds,
/// how it is written and removed, and that where it lives is denied to a role's bash. One folder
/// and one format for every agent since 2026-11-09 — the bridge's — instead of a folder and a
/// format per client.
final class HostedMCPClientTokenFileTests: XCTestCase {
    var home: URL!

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanoteams-token-file-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
        super.tearDown()
    }

    private var token: String { "ntm_a4c36525_0f3c9b1e7d2a4c6e8b0f1a3c5e7d9b2f4a6c8e0b" }

    private func mode(of url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    // MARK: - Where

    /// One folder, under `~/.config`, with no space in its path: the bridge's `--token-file`
    /// argument pastes into any client's configuration unquoted. Not `~/.nanoteams`, which is
    /// the per-work-folder metadata directory's name.
    func testLocation_isOneFolderForEveryAgent_withNoSpaceInItsPath() throws {
        let location = try XCTUnwrap(HostedMCPClientTokenFile.location(shortID: "a4c36525", home: home))
        XCTAssertEqual(location.path, home.appendingPathComponent(".config/nanoteams/a4c36525.token").path)
        XCTAssertEqual(HostedMCPClientTokenFile.folder(home: home).path, home.appendingPathComponent(".config/nanoteams").path)
        XCTAssertFalse(HostedMCPClientTokenFile.folderRelativePath.contains(" "))
        XCTAssertFalse(HostedMCPClientTokenFile.folderRelativePath.hasPrefix(".nanoteams"))
    }

    /// The id becomes a path component: anything but the store's eight ASCII hex digits names no
    /// file — a traversal, a separator, the fullwidth digits `Character.isHexDigit` accepts.
    func testLocation_refusesAnIdThatIsNotEightHexDigits() {
        for bad in ["", "a4c3652", "a4c365250", "../../x1", "a4c3/525", "ghijklmn", "ａ４ｃ３６５２５", "a4c36525\n"] {
            XCTAssertNil(HostedMCPClientTokenFile.location(shortID: bad, home: home), "\(bad)")
        }
    }

    /// The folder is a token location: denied to every role's bash in every profile, whatever
    /// Settings → Bash grants (`SeatbeltSandbox.externalAgentTokenLocations`), and hidden from
    /// the file tools — not merely a credential store the grant opens.
    func testTheTokenFolderIsATokenLocation_notMerelyACredentialStore() throws {
        let path = try XCTUnwrap(HostedMCPClientTokenFile.location(shortID: "a4c36525", home: home)).path
        let locations = SeatbeltSandbox.externalAgentTokenLocations(home: home.path)
        XCTAssertTrue(locations.subpaths.contains { path.hasPrefix($0 + "/") }, "\(path) is outside \(locations.subpaths)")
        XCTAssertFalse(
            SeatbeltSandbox.credentialStoreSubpaths(home: home.path).contains { path.hasPrefix($0 + "/") },
            "a grant on the credential stores must not reach a token")
        XCTAssertTrue(
            SandboxPathResolver.hiddenLocations(home: home.path, canonicalRoot: "/nowhere")
                .contains(HostedMCPClientTokenFile.folder(home: home).path),
            "hidden from the file tools wherever the work folder is")
    }

    // MARK: - What

    /// The bare token and a newline — what the bridge reads back, through its own reader.
    func testContents_areWhatTheBridgeReads() throws {
        XCTAssertEqual(HostedMCPClientTokenFile.contents(token: token), Data((token + "\n").utf8))
        let url = try HostedMCPClientTokenFile(home: home).write(token: token, shortID: "a4c36525")
        let read = HostedMCPStdioRelay.readTokenFile(atPath: url.path)
        XCTAssertEqual(read.value, token)
        XCTAssertNil(read.problem)
    }

    // MARK: - Write and remove

    func testWrite_createsAPrivateFolderAndAPrivateFile() throws {
        let file = HostedMCPClientTokenFile(home: home)
        let url = try file.write(token: token, shortID: "a4c36525")
        XCTAssertEqual(try Data(contentsOf: url), HostedMCPClientTokenFile.contents(token: token))
        XCTAssertEqual(try mode(of: url), 0o600)
        XCTAssertEqual(try mode(of: url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path).sorted(),
            [".gitignore", "a4c36525.token"],
            "the token, the ignore marker, and no temporary left beside them")
        // `~/.config` is commonly versioned, and a `git add -A` there would commit the bearer (#376).
        XCTAssertEqual(
            try String(
                contentsOf: url.deletingLastPathComponent().appendingPathComponent(".gitignore"),
                encoding: .utf8),
            "*\n")
    }

    /// The rename-into-place failing — an IMMUTABLE destination (`chflags uchg`, which a person
    /// or a backup tool can leave behind). The OLD token stays exactly as it was, no temporary
    /// file is left beside it, and the reason names the file as a person reads it.
    func testWrite_overAnImmutableFile_throwsAndKeepsTheOldTokenAndNoTemporary() throws {
        let file = HostedMCPClientTokenFile(home: home)
        let url = try file.write(token: "ntm_a4c36525_old", shortID: "a4c36525")
        let locked = try ProcessRunner.run(
            executable: "/usr/bin/chflags", arguments: ["uchg", url.path],
            currentDirectory: nil, timeout: 10)
        try XCTSkipUnless(locked.exitCode == 0, "chflags unavailable on this volume")
        defer {
            _ = try? ProcessRunner.run(
                executable: "/usr/bin/chflags", arguments: ["nouchg", url.path],
                currentDirectory: nil, timeout: 10)
        }

        XCTAssertThrowsError(try file.write(token: token, shortID: "a4c36525")) {
            guard case HostedMCPClientTokenFileError.fileNotWritable(let path) = $0 else {
                return XCTFail("\($0)")
            }
            XCTAssertTrue(path.hasPrefix("~/"), "the path is said as a person reads it: \(path)")
            XCTAssertTrue(path.hasSuffix("a4c36525.token"), path)
        }
        XCTAssertEqual(
            try Data(contentsOf: url),
            HostedMCPClientTokenFile.contents(token: "ntm_a4c36525_old"),
            "the token a client is still using must survive a failed reissue")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path).sorted(),
            [".gitignore", "a4c36525.token"],
            "the temporary file is removed when the rename fails")
    }

    /// A folder that existed with a looser mode is tightened; a reissue replaces the file whole.
    func testWrite_tightensAnExistingFolderAndReplacesTheOldToken() throws {
        let folder = HostedMCPClientTokenFile.folder(home: home)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let file = HostedMCPClientTokenFile(home: home)
        try file.write(token: "ntm_a4c36525_old", shortID: "a4c36525")
        let url = try file.write(token: token, shortID: "a4c36525")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), token + "\n")
        XCTAssertEqual(try mode(of: folder), 0o700)
        XCTAssertEqual(try mode(of: url), 0o600)
    }

    func testWrite_refusesAnIdThatNamesNoFile() {
        let file = HostedMCPClientTokenFile(home: home)
        XCTAssertThrowsError(try file.write(token: token, shortID: "../x")) {
            XCTAssertEqual($0 as? HostedMCPClientTokenFileError, .invalidAgentID)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: HostedMCPClientTokenFile.folder(home: home).path),
                       "nothing was created for an id that names no file")
    }

    /// A folder that cannot be made — here the home is a regular file — is our own sentence,
    /// naming the folder the person can look at.
    func testWrite_reportsAFolderItCannotCreate() throws {
        let notAFolder = home.appendingPathComponent("plain-file")
        try Data("x".utf8).write(to: notAFolder)
        let file = HostedMCPClientTokenFile(home: notAFolder)
        XCTAssertThrowsError(try file.write(token: token, shortID: "a4c36525")) { error in
            guard case .folderNotWritable(let path) = error as? HostedMCPClientTokenFileError else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(path.hasSuffix(".config/nanoteams"), path)
        }
    }

    func testRemove_deletesTheFileAndToleratesOneAlreadyGone() throws {
        let file = HostedMCPClientTokenFile(home: home)
        let url = try file.write(token: token, shortID: "a4c36525")
        try file.remove(shortID: "a4c36525")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNoThrow(try file.remove(shortID: "a4c36525"), "already gone")
        XCTAssertNoThrow(try file.remove(shortID: "../x"), "an id that names no file has none to remove")
    }

    /// A file that will not go — here a folder sits where it was — is our own sentence, naming the
    /// path as the person reads it; revoke reports it rather than claiming the token is gone.
    func testRemove_reportsAFileItCannotRemove() throws {
        let file = HostedMCPClientTokenFile(home: home)
        let url = try XCTUnwrap(HostedMCPClientTokenFile.location(shortID: "a4c36525", home: home))
        try FileManager.default.createDirectory(at: url.appendingPathComponent("occupied"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try file.remove(shortID: "a4c36525")) {
            XCTAssertEqual($0 as? HostedMCPClientTokenFileError, .fileNotRemovable("~/.config/nanoteams/a4c36525.token"))
            XCTAssertEqual($0.localizedDescription, "Could not remove ~/.config/nanoteams/a4c36525.token.")
        }
    }

    func testDisplayPath_abbreviatesTheHomeFolder() {
        let url = home.appendingPathComponent(".config/nanoteams/a4c36525.token")
        XCTAssertEqual(HostedMCPClientTokenFile.displayPath(url, home: home), "~/.config/nanoteams/a4c36525.token")
        XCTAssertEqual(
            HostedMCPClientTokenFile.displayPath(URL(fileURLWithPath: "/etc/x"), home: home), "/etc/x",
            "a path outside the home folder reads as itself")
    }

    /// Every message is the app's own English, naming the path as a person reads it.
    func testErrors_speakInTheAppsOwnWords() {
        XCTAssertEqual(HostedMCPClientTokenFileError.invalidAgentID.localizedDescription, "The agent's id names no token file.")
        XCTAssertEqual(HostedMCPClientTokenFileError.folderNotWritable("~/x").localizedDescription, "Could not create ~/x.")
        XCTAssertEqual(HostedMCPClientTokenFileError.fileNotWritable("~/x").localizedDescription, "Could not write ~/x.")
    }
}

/// The orchestrator issues, reissues and revokes tokens and keeps the token file in step: written
/// for every agent, rewritten on a reissue, removed on revoke; an add whose file cannot be written
/// keeps the agent and says so, since the token on the sheet still connects a client that sends
/// it in a header.
@MainActor
final class HostedMCPTokenHandoffTests: XCTestCase, @unchecked Sendable {
    var store: NTMSOrchestrator!
    var tempDir: URL!
    var secretStorage: InMemorySecureTokenStorage!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanoteams-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        secretStorage = InMemorySecureTokenStorage()
    }

    override func tearDown() async throws {
        store = nil
        secretStorage = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    private func makeStore(home: URL? = nil) {
        let agents = tempDir.appendingPathComponent("agents", isDirectory: true)
        let clientHome = home ?? tempDir.appendingPathComponent("home", isDirectory: true)
        let storage: InMemorySecureTokenStorage = secretStorage
        // The factory builds its own agent store unless handed one; this one carries the storage
        // a test can make refuse a delete.
        store = TestOrchestrator.make(
            hostedMCPEnvironment: HostedMCPEnvironment(
                directoryURL: { agents },
                secretStorage: { storage },
                processEnvironment: { [:] },
                allowAutoStart: false,
                now: { Date() },
                clientHomeDirectory: { clientHome }),
            hostedMCPAgentStore: HostedMCPAgentStore(directoryURL: agents, secretStorage: storage))
    }

    private var clientHome: URL { tempDir.appendingPathComponent("home", isDirectory: true) }

    func testAdd_writesTheTokenFile_andTheTokenAuthenticates() async throws {
        makeStore()
        let handoff = try store.addHostedMCPAgent(label: "Claude Code")
        let expected = try XCTUnwrap(HostedMCPClientTokenFile.location(
            shortID: handoff.agent.record.shortID, home: clientHome))
        XCTAssertEqual(handoff.delivery, .written(expected))
        XCTAssertEqual(try Data(contentsOf: expected), HostedMCPClientTokenFile.contents(token: handoff.agent.token))
        XCTAssertEqual(
            store.hostedMCPAgentStore.verifyBearerToken(handoff.agent.token), .authenticated(handoff.agent.record.identity))
        // What the bridge would read from that file is the token that authenticates.
        XCTAssertEqual(HostedMCPStdioRelay.readTokenFile(atPath: expected.path).value, handoff.agent.token)
    }

    /// The file failed, the agent stays: the token on the sheet connects a client that sends it
    /// in a header, and a reissue writes the file again. Until 2026-11-09 the add was undone,
    /// because the clients that read a file were never shown the token.
    func testAdd_whoseFileCannotBeWritten_keepsTheAgentAndSaysSo() async throws {
        let notAFolder = tempDir.appendingPathComponent("plain-file")
        try Data("x".utf8).write(to: notAFolder)
        makeStore(home: notAFolder)
        let handoff = try store.addHostedMCPAgent(label: "Claude Code")
        guard case .notWritten(let url, let reason) = handoff.delivery else { return XCTFail("\(handoff.delivery)") }
        XCTAssertTrue(reason.hasPrefix("Could not create"), reason)
        XCTAssertEqual(url.lastPathComponent, "\(handoff.agent.record.shortID).token", "the file that was meant")
        XCTAssertEqual(store.hostedMCPAgentStore.listAgents().map(\.label), ["Claude Code"])
        XCTAssertEqual(
            store.hostedMCPAgentStore.verifyBearerToken(handoff.agent.token), .authenticated(handoff.agent.record.identity),
            "the token on the sheet still works")
    }

    func testReissue_rewritesTheFileWithTheNewToken() async throws {
        makeStore()
        let added = try store.addHostedMCPAgent(label: "Claude Desktop")
        let reissued = try store.reissueHostedMCPAgentToken(agentID: added.agent.record.id)
        guard case .written(let url) = reissued.delivery else { return XCTFail("\(reissued.delivery)") }
        XCTAssertNotEqual(reissued.agent.token, added.agent.token)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), reissued.agent.token + "\n")
        XCTAssertEqual(store.hostedMCPAgentStore.verifyBearerToken(added.agent.token), .invalidToken)
    }

    /// The rotation already happened, so a file that cannot be written is reported, not thrown.
    func testReissue_whoseFileCannotBeWrittenSaysSo() async throws {
        makeStore()
        let added = try store.addHostedMCPAgent(label: "Claude Code")
        // A folder where the file was: the rename over it fails.
        guard case .written(let url) = added.delivery else { return XCTFail("\(added.delivery)") }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let reissued = try store.reissueHostedMCPAgentToken(agentID: added.agent.record.id)
        guard case .notWritten(let meant, let reason) = reissued.delivery else { return XCTFail("\(reissued.delivery)") }
        XCTAssertEqual(meant, url)
        XCTAssertTrue(reason.hasPrefix("Could not write"), reason)
        XCTAssertEqual(store.hostedMCPAgentStore.verifyBearerToken(added.agent.token), .invalidToken, "rotated all the same")
    }

    func testReissueAll_writesEveryFile() async throws {
        makeStore()
        _ = try store.addHostedMCPAgent(label: "Claude Code")
        _ = try store.addHostedMCPAgent(label: "Cursor")
        let rotation = store.rotateAllHostedMCPAgentTokens()
        XCTAssertTrue(rotation.failures.isEmpty)
        XCTAssertEqual(rotation.issued.count, 2)
        for issued in rotation.issued {
            guard case .written(let url) = issued.delivery else { return XCTFail("\(issued.delivery)") }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), issued.agent.token + "\n")
        }
    }

    /// Revoked either way; what was left behind is said, one line each — a token file that would
    /// not go (a folder sits where it was) and a verifier the Keychain kept.
    func testRevoke_saysWhatItLeftBehind() async throws {
        makeStore()
        let added = try store.addHostedMCPAgent(label: "Claude Code")
        guard case .written(let url) = added.delivery else { return XCTFail("\(added.delivery)") }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("occupied"), withIntermediateDirectories: true)
        let doomedKey = added.agent.record.id.uuidString
        secretStorage.writeFailure = { key, token in key == doomedKey && token == nil ? .unhandled(-25308) : nil }

        let warning = try XCTUnwrap(try store.revokeHostedMCPAgent(agentID: added.agent.record.id))
        XCTAssertTrue(warning.contains("token verifier could not be removed"), warning)
        XCTAssertTrue(warning.contains("token file is still there"), warning)
        XCTAssertTrue(warning.contains("~/.config/nanoteams/\(added.agent.record.shortID).token"), warning)
        XCTAssertTrue(store.hostedMCPAgentStore.listAgents().isEmpty, "revoked all the same")
    }

    func testRevoke_removesTheTokenFile() async throws {
        makeStore()
        let added = try store.addHostedMCPAgent(label: "Claude Code")
        guard case .written(let url) = added.delivery else { return XCTFail("\(added.delivery)") }
        XCTAssertNil(try store.revokeHostedMCPAgent(agentID: added.agent.record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.hostedMCPAgentStore.listAgents().isEmpty)
    }
}
