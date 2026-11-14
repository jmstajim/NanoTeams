import XCTest
@testable import NanoTeams

/// File I/O of an external agent's full call (`external_calls/<id>.json`, 2026-11-08): what goes
/// in comes back whole, only the NanoTeams agent token is taken out, and nothing that is not a
/// call is read as one.
final class ExternalAutovisorFullCallStoreTests: XCTestCase {

    private var tempDir: URL!
    private var callsDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NTMSFullCallStore-\(UUID().uuidString)", isDirectory: true)
        callsDir = tempDir.appendingPathComponent(ExternalAutovisorFullCallStore.directoryName, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        callsDir = nil
        tempDir = nil
        super.tearDown()
    }

    private func write(_ call: ExternalAutovisorFullCall) -> Bool {
        ExternalAutovisorFullCallStore.write(call, in: callsDir, fileManager: .default)
    }

    /// An issued token's shape (`HostedMCPAgentStore`): 8 lower-case hex, 43 base64url.
    private let token = "ntm_0a1b2c3d_" + String(repeating: "Ab9-_", count: 8) + "xyz"

    // MARK: - Round trip

    func testACallComesBackByteForByte() throws {
        let call = ExternalAutovisorFullCall(
            id: UUID(),
            arguments: #"{"brief":"Добавь калькулятор\nстрока 2   и «кавычки» 🧮","folder_id":"3A77"}"#,
            response: #"{"ok":true,"data":{"path":"/Users/alex/Sandbox/calc.html"}}"#
        )
        XCTAssertTrue(write(call))
        XCTAssertEqual(ExternalAutovisorFullCallStore.read(id: call.id, in: callsDir), call)
    }

    /// No byte cap: a `read_artifact` response may be half a megabyte, and it is kept whole.
    func testAHalfMegabyteResponseIsKeptWhole() throws {
        let body = String(repeating: "0123456789abcdef", count: 32 * 1024)  // 512 KiB
        let call = ExternalAutovisorFullCall(id: UUID(), arguments: "{}", response: body)
        XCTAssertTrue(write(call))
        XCTAssertEqual(ExternalAutovisorFullCallStore.read(id: call.id, in: callsDir)?.response.utf8.count, body.utf8.count)
    }

    func testTheDirectoryIsOwnerOnlyAndHoldsNothingButTheCall() throws {
        let call = ExternalAutovisorFullCall(id: UUID(), arguments: "{}", response: "{}")
        XCTAssertTrue(write(call))
        let attrs = try FileManager.default.attributesOfItem(atPath: callsDir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        // An atomic write leaves no temporary behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: callsDir.path), ["\(call.id.uuidString).json"])
    }

    // MARK: - What is scrubbed

    func testOnlyTheAgentTokenIsTakenOut() throws {
        let call = ExternalAutovisorFullCall(
            id: UUID(),
            arguments: #"{"brief":"my token is \#(token) and Bearer abcdefgh12345678"}"#,
            // The token right after a JSON escape — `\n` then the token, no word boundary.
            response: #"{"text":"line\n\#(token)","note":"a basic implementation of token streaming"}"#
        )
        XCTAssertTrue(write(call))
        let raw = try String(contentsOf: ExternalAutovisorFullCallStore.fileURL(for: call.id, in: callsDir), encoding: .utf8)
        XCTAssertFalse(raw.contains(token))
        XCTAssertFalse(raw.contains("Ab9-_Ab9-_"), "no part of the secret survives")

        let stored = try XCTUnwrap(ExternalAutovisorFullCallStore.read(id: call.id, in: callsDir))
        XCTAssertEqual(stored.arguments, #"{"brief":"my token is <redacted> and Bearer abcdefgh12345678"}"#,
                       "a Bearer value that is not ours is the agent's own text — kept")
        XCTAssertEqual(stored.response, #"{"text":"line\n<redacted>","note":"a basic implementation of token streaming"}"#,
                       "prose the generic scrub would have cut stays whole")
    }

    // MARK: - Only calls are read as calls

    func testStoredIDsSkipsWhatIsNotACall() throws {
        let a = ExternalAutovisorFullCall(id: UUID(), arguments: "{}", response: "{}")
        let b = ExternalAutovisorFullCall(id: UUID(), arguments: "{}", response: "{}")
        XCTAssertTrue(write(a))
        XCTAssertTrue(write(b))
        try Data("x".utf8).write(to: callsDir.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: callsDir.appendingPathComponent("not-a-uuid.json"))
        try Data("x".utf8).write(to: callsDir.appendingPathComponent("\(UUID().uuidString).json.tmp"))

        XCTAssertEqual(ExternalAutovisorFullCallStore.storedIDs(in: callsDir, fileManager: .default), [a.id, b.id])
    }

    func testAMissingDirectoryHoldsNoCalls() {
        XCTAssertEqual(ExternalAutovisorFullCallStore.storedIDs(in: callsDir, fileManager: .default), [])
        XCTAssertNil(ExternalAutovisorFullCallStore.read(id: UUID(), in: callsDir))
    }

    func testRemoveTakesOnlyTheNamedCalls() throws {
        let a = ExternalAutovisorFullCall(id: UUID(), arguments: "{}", response: "{}")
        let b = ExternalAutovisorFullCall(id: UUID(), arguments: "{}", response: "{}")
        XCTAssertTrue(write(a))
        XCTAssertTrue(write(b))
        ExternalAutovisorFullCallStore.remove(ids: [a.id, UUID()], in: callsDir, fileManager: .default)
        XCTAssertEqual(ExternalAutovisorFullCallStore.storedIDs(in: callsDir, fileManager: .default), [b.id])
        XCTAssertNil(ExternalAutovisorFullCallStore.read(id: a.id, in: callsDir))
        XCTAssertNotNil(ExternalAutovisorFullCallStore.read(id: b.id, in: callsDir))
    }

    // MARK: - Failure branches

    func testAWriteThatCannotCreateItsDirectoryReportsFalse() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // A regular FILE where the directory should be.
        try Data("x".utf8).write(to: callsDir)
        let call = ExternalAutovisorFullCall(id: UUID(), arguments: "{}", response: "{}")
        XCTAssertFalse(write(call))
        XCTAssertNil(ExternalAutovisorFullCallStore.read(id: call.id, in: callsDir))
    }

    func testAWriteThatCannotWriteItsFileReportsFalse() throws {
        let call = ExternalAutovisorFullCall(id: UUID(), arguments: "{}", response: "{}")
        // A DIRECTORY where the call's file should be: the atomic replace cannot land.
        try FileManager.default.createDirectory(
            at: ExternalAutovisorFullCallStore.fileURL(for: call.id, in: callsDir),
            withIntermediateDirectories: true)
        XCTAssertFalse(write(call))
    }

    func testACorruptFileIsNoCall() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: callsDir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: ExternalAutovisorFullCallStore.fileURL(for: id, in: callsDir))
        XCTAssertNil(ExternalAutovisorFullCallStore.read(id: id, in: callsDir))
    }

    func testAFileNamingAnotherCallIsNotThisCall() throws {
        let id = UUID()
        let other = ExternalAutovisorFullCall(id: UUID(), arguments: "{}", response: "{}")
        try FileManager.default.createDirectory(at: callsDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(other).write(to: ExternalAutovisorFullCallStore.fileURL(for: id, in: callsDir))
        XCTAssertNil(ExternalAutovisorFullCallStore.read(id: id, in: callsDir))
    }

    /// A later version may add a field, or a file may lack a body; either still opens.
    func testDecodingIsLenientOnEverythingButTheID() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: callsDir, withIntermediateDirectories: true)
        let url = ExternalAutovisorFullCallStore.fileURL(for: id, in: callsDir)

        try Data(#"{"id":"\#(id.uuidString)","arguments":"{}","response":"ok","durationMs":12}"#.utf8).write(to: url)
        XCTAssertEqual(ExternalAutovisorFullCallStore.read(id: id, in: callsDir),
                       ExternalAutovisorFullCall(id: id, arguments: "{}", response: "ok"))

        try Data(#"{"id":"\#(id.uuidString)"}"#.utf8).write(to: url)
        XCTAssertEqual(ExternalAutovisorFullCallStore.read(id: id, in: callsDir),
                       ExternalAutovisorFullCall(id: id, arguments: "", response: ""))

        try Data(#"{"arguments":"{}"}"#.utf8).write(to: url)
        XCTAssertNil(ExternalAutovisorFullCallStore.read(id: id, in: callsDir), "no id, no call")
    }
}
