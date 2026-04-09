import XCTest
@testable import NanoTeams

final class BuildDiagnosticsPersistenceTests: XCTestCase {
    func testBuildDiagnosticsRoundTrip() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let repository = NTMSRepository(fileManager: fileManager)
        let runID = 0
        let roleID = "test_engineer"

        let record = BuildIssuePersisted(
            severity: "error",
            message: "Cannot convert value of type 'Int' to expected argument type 'String'",
            file: "Sources/App/main.swift",
            line: 7,
            column: 9,
            toolchainHint: "swiftc",
            ruleId: nil,
            excerpt: "/tmp/main.swift:7:9: error: type mismatch"
        )
        let diagnostics = BuildDiagnosticsPersisted(
            schemaVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            errorCount: 1,
            warningCount: 0,
            issues: [record],
            excerptsRelativePath: "runs/placeholder/steps/placeholder/build_excerpts.txt"
        )

        let taskID = 0
        let rel = try repository.persistBuildDiagnosticsPersisted(
            at: tempDir,
            taskID: taskID,
            runID: runID,
            roleID: roleID,
            diagnostics: diagnostics
        )

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let jsonURL = paths.buildDiagnosticsJSON(taskID: taskID, runID: runID, roleID: roleID)

        XCTAssertTrue(fileManager.fileExists(atPath: jsonURL.path))
        XCTAssertEqual(rel, paths.relativePathWithinNanoteams(for: jsonURL))

        let data = try Data(contentsOf: jsonURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BuildDiagnosticsPersisted.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, diagnostics.schemaVersion)
        XCTAssertEqual(decoded.errorCount, 1)
        XCTAssertEqual(decoded.warningCount, 0)
        XCTAssertEqual(decoded.issues.first?.message, record.message)
        XCTAssertEqual(decoded.issues.first?.file, record.file)
    }

    func testBuildDiagnostics_createsDirectoryWithRestrictedPermissions() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let repository = NTMSRepository(fileManager: fileManager)
        let diagnostics = BuildDiagnosticsPersisted(
            schemaVersion: 1,
            createdAt: Date(),
            errorCount: 0,
            warningCount: 0,
            issues: [],
            excerptsRelativePath: nil
        )

        _ = try repository.persistBuildDiagnosticsPersisted(
            at: tempDir, taskID: 0, runID: 0, roleID: "eng", diagnostics: diagnostics
        )

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let roleDir = paths.buildDiagnosticsJSON(taskID: 0, runID: 0, roleID: "eng")
            .deletingLastPathComponent()
        let attrs = try fileManager.attributesOfItem(atPath: roleDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700,
                        "Build diagnostics directory should have owner-only permissions")
    }

    func testEmptyBuildDiagnostics_createsDirectoryWithRestrictedPermissions() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let repository = NTMSRepository(fileManager: fileManager)
        let service = ArtifactService(repository: repository, fileManager: fileManager)

        _ = try service.persistEmptyBuildDiagnostics(
            taskID: 0, runID: 0, roleID: "eng", workFolderRoot: tempDir
        )

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let roleDir = paths.buildDiagnosticsJSON(taskID: 0, runID: 0, roleID: "eng")
            .deletingLastPathComponent()
        let attrs = try fileManager.attributesOfItem(atPath: roleDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700,
                        "ArtifactService build diagnostics directory should have owner-only permissions")
    }

    func testExcerptsRelativePathIsStable() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let runID = 0
        let roleID = "test_engineer"

        let excerptsURL = paths.buildExcerptsTXT(taskID: 0, runID: runID, roleID: roleID)
        let rel = paths.relativePathWithinNanoteams(for: excerptsURL)

        XCTAssertTrue(rel.contains("build_excerpts.txt"))
        XCTAssertTrue(rel.contains(String(runID)))
        XCTAssertTrue(rel.contains("roles/\(roleID)"))
    }
}
