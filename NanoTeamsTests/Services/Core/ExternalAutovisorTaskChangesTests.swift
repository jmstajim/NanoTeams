import XCTest
@testable import NanoTeams

/// What `task_changes` tells an external agent about the files of a page (F6, 2026-11-12):
/// - S5: a hidden-character warning names the file it was found in — a page of several files,
///   a file on another page, a name that itself hides a character — and a name is shown with
///   its hidden characters tagged, the spelling `file_path` accepts back;
/// - N8: a page's diff is decoded without loss — a binary file carries `binary`, a file that is
///   not UTF-8 carries `encoding: not_utf8` and its other bytes as `<0xNN>`, never U+FFFD.
@MainActor
final class ExternalAutovisorTaskChangesTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "dddddddd-1111-2222-3333-444444444451")!,
        label: "Claude Code"
    )
    private var team: Team!
    private var folderID: String!

    override func tearDown() async throws {
        team = nil
        folderID = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func openExternalFolder() async throws {
        await sut.openWorkFolder(tempDir)
        let pipeline = try XCTUnwrap(sut.snapshot?.workFolder.teams.first {
            !$0.isChatMode && !$0.isHiddenFromPickers && $0.nonSupervisorRoles.count >= 3
        })
        await sut.mutateWorkFolder { $0.setActiveTeam(pipeline.id) }
        team = pipeline
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    private func task() async throws -> Int {
        let created = await sut.createTask(
            title: "Calculator", supervisorTask: "Build a calculator", preferredTeamID: team.id,
            makeActive: false, origin: .externalAgent(agent), requestKey: nil)
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        return taskID
    }

    private func write(_ data: Data, _ relative: String) throws {
        let url = tempDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func write(_ text: String, _ relative: String) throws {
        try write(Data(text.utf8), relative)
    }

    private func snapshot(_ taskID: Int, _ phase: TaskSnapshotService.SnapshotPhase) async throws {
        try await sut.taskSnapshotService.takeSnapshot(workFolder: tempDir, taskID: taskID, round: 1, phase: phase)
    }

    private struct Page {
        let data: [String: Any]
        let warnings: [String]
        var files: [[String: Any]] { data["files"] as? [[String: Any]] ?? [] }
        var diff: String { data["diff"] as? String ?? "" }
        func file(_ path: String) -> [String: Any]? { files.first { $0["path"] as? String == path } }
    }

    private func changes(_ taskID: Int, _ extra: [String: Any] = [:]) async throws -> Page {
        var args: [String: Any] = ["folder_id": folderID as Any, "task_id": taskID, "round": 1]
        args.merge(extra) { $1 }
        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.taskChanges, args: args, agent: agent)
        XCTAssertFalse(result.isError, result.outputJSON)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let meta = envelope["meta"] as? [String: Any]
        return Page(
            data: try XCTUnwrap(envelope["data"] as? [String: Any]),
            warnings: meta?["warnings"] as? [String] ?? [])
    }

    // MARK: - S5

    func testHiddenCharacterWarning_namesOnlyTheFileItWasFoundIn() async throws {
        try await openExternalFolder()
        let taskID = try await task()
        for name in ["a.swift", "b.swift", "c.swift", "d.swift", "e.swift", "f.swift"] {
            try write("let x = 1\n", name)
        }
        try await snapshot(taskID, .start)
        try write("let x = \"admin\u{202E}txt\"\n", "b.swift")
        for name in ["a.swift", "c.swift", "d.swift", "e.swift", "f.swift"] {
            try write("let x = 2\n", name)
        }
        try await snapshot(taskID, .review)

        let first = try await changes(taskID)
        XCTAssertEqual(first.files.count, 6)
        let hidden = first.warnings.filter { $0.contains("hidden characters") }
        XCTAssertEqual(hidden.count, 1, "one file hid something: \(first.warnings)")
        XCTAssertTrue(hidden.first?.contains("b.swift") == true, "\(hidden)")

        let second = try await changes(taskID, ["page": 2])
        XCTAssertTrue(
            second.warnings.filter { $0.contains("hidden characters") }.isEmpty,
            "f.swift on page 2 hides nothing, and b.swift is not on it: \(second.warnings)")
    }

    func testNameThatHidesACharacter_isTaggedWarnedAndFilterable() async throws {
        try await openExternalFolder()
        let taskID = try await task()
        try await snapshot(taskID, .start)
        let rawName = "invoice\u{202E}fdp.exe"
        try write("payload\n", rawName)
        try await snapshot(taskID, .review)

        let page = try await changes(taskID)
        let shown = "invoice<U+202E>fdp.exe"
        XCTAssertNotNil(page.file(shown), "the name is shown with its hidden character tagged: \(page.files)")
        XCTAssertTrue(
            page.warnings.contains { $0.contains(shown) && $0.contains("name") },
            "a hidden character in a NAME warns even when the diff is clean: \(page.warnings)")

        let filtered = try await changes(taskID, ["file_path": shown])
        XCTAssertEqual(filtered.files.count, 1, "file_path accepts the name as it was shown")
        XCTAssertTrue(filtered.diff.contains("+payload"))
    }

    func testCleanPage_hasNoHiddenCharacterWarnings() async throws {
        try await openExternalFolder()
        let taskID = try await task()
        try await snapshot(taskID, .start)
        try write("let 👨‍💻 = \"❤️\"\n", "emoji.swift")
        try await snapshot(taskID, .review)

        let page = try await changes(taskID)
        XCTAssertEqual(page.warnings.filter { $0.contains("hidden") }, [])
    }

    // MARK: - S1

    /// A store altered behind NanoTeams' back warns through `task_changes` — and the labels
    /// ride `meta.warnings` only, never a field of the result.
    func testStoreAlteredDuringThePass_warnsInMeta_andIsNotAResultField() async throws {
        try await openExternalFolder()
        let taskID = try await task()
        try write("a\n", "a.txt")
        try await snapshot(taskID, .start)
        let config = NTMSPaths(workFolderRoot: tempDir).snapshotsGitDir.appendingPathComponent("config")
        let planted = try String(contentsOf: config, encoding: .utf8) + "[filter \"x\"]\n\tclean = cat\n"
        try planted.write(to: config, atomically: true, encoding: .utf8)
        try write("b\n", "a.txt")
        try await snapshot(taskID, .review)

        let page = try await changes(taskID)
        XCTAssertTrue(page.warnings.contains(TaskChangesWarnings.storeRestored(["config"])), "\(page.warnings)")
        XCTAssertNil(page.data["store_repairs"])

        let clean = try await task()
        try await snapshot(clean, .start)
        try await snapshot(clean, .review)
        let cleanPage = try await changes(clean)
        XCTAssertFalse(cleanPage.warnings.contains { $0.contains("snapshot store") })
    }

    /// A repair made BEFORE a round started is not that round's, even inside the same second.
    /// The journal kept whole seconds until 2026-11-12, so a round started in the second of a
    /// repair reported it (`testStoreAlteredDuringThePass…` failed 2 runs in 3).
    func testRepairMadeJustBeforeARoundStarts_isNotThatRoundsRepair() async throws {
        try await openExternalFolder()
        let config = NTMSPaths(workFolderRoot: tempDir).snapshotsGitDir.appendingPathComponent("config")
        for attempt in 0..<4 {
            let altered = try await task()
            try write("v\(attempt)\n", "a.txt")
            try await snapshot(altered, .start)
            let planted = try String(contentsOf: config, encoding: .utf8) + "[filter \"x\(attempt)\"]\n\tclean = cat\n"
            try planted.write(to: config, atomically: true, encoding: .utf8)
            try await snapshot(altered, .review)   // this check repairs the config

            let clean = try await task()
            try await snapshot(clean, .start)
            try await snapshot(clean, .review)
            let cleanPage = try await changes(clean)
            XCTAssertFalse(
                cleanPage.warnings.contains { $0.contains("snapshot store") },
                "attempt \(attempt): \(cleanPage.warnings)")
        }
    }

    // MARK: - N8

    func testBinaryFile_isMarkedBinary() async throws {
        try await openExternalFolder()
        let taskID = try await task()
        try write(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]), "image.png")
        try await snapshot(taskID, .start)
        try write(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x09, 0x08]), "image.png")
        try write("text\n", "notes.txt")
        try await snapshot(taskID, .review)

        let page = try await changes(taskID)
        XCTAssertEqual(page.file("image.png")?["binary"] as? Bool, true)
        XCTAssertNil(page.file("notes.txt")?["binary"], "a text file carries no binary field")
        XCTAssertNil(page.file("notes.txt")?["encoding"])
    }

    func testLatin1File_isMarkedAndItsBytesSurvive() async throws {
        try await openExternalFolder()
        let taskID = try await task()
        try await snapshot(taskID, .start)
        try write(Data("caf".utf8) + Data([0xE9]) + Data(" cr\u{00E8}me\n".utf8), "menu.txt")
        try await snapshot(taskID, .review)

        let page = try await changes(taskID)
        XCTAssertEqual(page.file("menu.txt")?["encoding"] as? String, "not_utf8")
        XCTAssertTrue(page.diff.contains("+caf<0xE9> crème"), page.diff)
        XCTAssertFalse(page.diff.contains("\u{FFFD}"))
        XCTAssertTrue(
            page.warnings.contains { $0.contains("menu.txt") && $0.contains("UTF-8") }, "\(page.warnings)")
    }
}
