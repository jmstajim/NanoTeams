import XCTest
@testable import NanoTeams

/// Tests for SandboxPathResolver security validation
final class SandboxPathResolverTests: XCTestCase {

    private var tempProjectRoot: URL!
    private var resolver: SandboxPathResolver!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempProjectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempProjectRoot, withIntermediateDirectories: true)
        resolver = SandboxPathResolver(workFolderRoot: tempProjectRoot)
    }

    override func tearDownWithError() throws {
        if let tempProjectRoot {
            try? FileManager.default.removeItem(at: tempProjectRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Valid Paths

    func testResolveEmptyPath() throws {
        let url = try resolver.resolveFileURL(relativePath: "")
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    func testResolveNilPath() throws {
        let url = try resolver.resolveFileURL(relativePath: nil)
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    func testResolveSimpleFilename() throws {
        let url = try resolver.resolveFileURL(relativePath: "file.txt")
        let expected = tempProjectRoot.appendingPathComponent("file.txt").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolveNestedPath() throws {
        let url = try resolver.resolveFileURL(relativePath: "src/main/file.swift")
        let expected = tempProjectRoot
            .appendingPathComponent("src")
            .appendingPathComponent("main")
            .appendingPathComponent("file.swift")
            .standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolveDotPath() throws {
        let url = try resolver.resolveFileURL(relativePath: "./file.txt")
        let expected = tempProjectRoot.appendingPathComponent("file.txt").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolvePathWithWhitespace() throws {
        let url = try resolver.resolveFileURL(relativePath: "  file.txt  ")
        let expected = tempProjectRoot.appendingPathComponent("file.txt").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolvePathWithLeadingDot() throws {
        let url = try resolver.resolveFileURL(relativePath: ".hidden")
        let expected = tempProjectRoot.appendingPathComponent(".hidden").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolvePathWithMultipleDots() throws {
        // Current directory dots should be handled (./././file)
        let url = try resolver.resolveFileURL(relativePath: "././file.txt")
        let expected = tempProjectRoot.appendingPathComponent("file.txt").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolveDeepNestedPath() throws {
        let url = try resolver.resolveFileURL(relativePath: "a/b/c/d/e/f/g.txt")
        XCTAssertTrue(url.path.hasPrefix(tempProjectRoot.path))
        XCTAssertTrue(url.path.hasSuffix("a/b/c/d/e/f/g.txt"))
    }

    // MARK: - Invalid Paths - Absolute

    func testRejectAbsolutePath() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "/etc/passwd")) { error in
            guard let sandboxError = error as? SandboxPathError else {
                XCTFail("Expected SandboxPathError")
                return
            }
            if case .absolutePathNotAllowed(let path) = sandboxError {
                XCTAssertEqual(path, "/etc/passwd")
            } else {
                XCTFail("Expected absolutePathNotAllowed error")
            }
        }
    }

    func testRejectHomeTildePath() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "~/.ssh/id_rsa")) { error in
            guard let sandboxError = error as? SandboxPathError else {
                XCTFail("Expected SandboxPathError")
                return
            }
            if case .absolutePathNotAllowed(let path) = sandboxError {
                XCTAssertEqual(path, "~/.ssh/id_rsa")
            } else {
                XCTFail("Expected absolutePathNotAllowed error")
            }
        }
    }

    func testRejectTildeOnlyPath() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "~")) { error in
            guard case SandboxPathError.absolutePathNotAllowed = error else {
                XCTFail("Expected absolutePathNotAllowed error")
                return
            }
        }
    }

    // MARK: - Invalid Paths - Parent Traversal

    func testRejectParentTraversal() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "../secret.txt")) { error in
            guard let sandboxError = error as? SandboxPathError else {
                XCTFail("Expected SandboxPathError")
                return
            }
            if case .parentTraversalNotAllowed(let path) = sandboxError {
                XCTAssertEqual(path, "../secret.txt")
            } else {
                XCTFail("Expected parentTraversalNotAllowed error")
            }
        }
    }

    func testRejectHiddenParentTraversal() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "subdir/../../../etc/passwd")) { error in
            guard case SandboxPathError.parentTraversalNotAllowed = error else {
                XCTFail("Expected parentTraversalNotAllowed error")
                return
            }
        }
    }

    func testRejectParentTraversalInMiddle() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "a/b/../../../c")) { error in
            guard case SandboxPathError.parentTraversalNotAllowed = error else {
                XCTFail("Expected parentTraversalNotAllowed error")
                return
            }
        }
    }

    func testRejectParentTraversalAtEnd() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "subdir/..")) { error in
            guard case SandboxPathError.parentTraversalNotAllowed = error else {
                XCTFail("Expected parentTraversalNotAllowed error")
                return
            }
        }
    }

    func testRejectJustParentTraversal() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "..")) { error in
            guard case SandboxPathError.parentTraversalNotAllowed = error else {
                XCTFail("Expected parentTraversalNotAllowed error")
                return
            }
        }
    }

    // MARK: - Restricted Internal Paths

    func testRejectInternalPath_projectJSON() {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        XCTAssertThrowsError(
            try resolverWithInternal.resolveFileURL(relativePath: ".nanoteams/internal/project.json")
        ) { error in
            guard case SandboxPathError.restrictedPath = error else {
                XCTFail("Expected restrictedPath, got \(error)")
                return
            }
        }
    }

    func testRejectInternalPath_taskJSON() {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        XCTAssertThrowsError(
            try resolverWithInternal.resolveFileURL(
                relativePath: ".nanoteams/internal/tasks/ABC/task.json"
            )
        ) { error in
            guard case SandboxPathError.restrictedPath = error else {
                XCTFail("Expected restrictedPath, got \(error)")
                return
            }
        }
    }

    func testRejectInternalPath_networkLog() {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        XCTAssertThrowsError(
            try resolverWithInternal.resolveFileURL(
                relativePath: ".nanoteams/internal/runs/ABC/network_log.json"
            )
        ) { error in
            guard case SandboxPathError.restrictedPath = error else {
                XCTFail("Expected restrictedPath, got \(error)")
                return
            }
        }
    }

    func testRejectInternalPath_internalDirItself() {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        XCTAssertThrowsError(
            try resolverWithInternal.resolveFileURL(relativePath: ".nanoteams/internal")
        ) { error in
            guard case SandboxPathError.restrictedPath = error else {
                XCTFail("Expected restrictedPath, got \(error)")
                return
            }
        }
    }

    func testAllowAttachmentPath_withInternalDir() throws {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        let url = try resolverWithInternal.resolveFileURL(
            relativePath: ".nanoteams/tasks/ABC/attachments/file.png"
        )
        XCTAssertTrue(url.path.contains(".nanoteams/tasks/ABC/attachments/file.png"))
    }

    func testAllowArtifactPath_withInternalDir() throws {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        let url = try resolverWithInternal.resolveFileURL(
            relativePath: ".nanoteams/runs/ABC/steps/DEF/artifact_requirements.md"
        )
        XCTAssertTrue(url.path.contains("artifact_requirements.md"))
    }

    func testAllowRegularProjectFile_withInternalDir() throws {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        let url = try resolverWithInternal.resolveFileURL(relativePath: "Sources/main.swift")
        XCTAssertTrue(url.path.contains("Sources/main.swift"))
    }

    func testNoInternalDir_allowsAllNanoteamsPaths() throws {
        // Default resolver without internalDir should allow everything
        let url = try resolver.resolveFileURL(relativePath: ".nanoteams/internal/project.json")
        XCTAssertTrue(url.path.contains(".nanoteams/internal/project.json"))
    }

    // MARK: - Restricted Path Error Description

    func testRestrictedPathErrorDescription() {
        let error = SandboxPathError.restrictedPath
        XCTAssertEqual(error.errorDescription, "File not found.")
    }

    // MARK: - Error Descriptions

    func testEmptyPathErrorDescription() {
        let error = SandboxPathError.emptyPath
        XCTAssertEqual(error.errorDescription, "Path is empty.")
    }

    func testAbsolutePathErrorDescription() {
        let error = SandboxPathError.absolutePathNotAllowed("/etc/passwd")
        XCTAssertEqual(error.errorDescription, "Absolute paths are not allowed: /etc/passwd")
    }

    func testParentTraversalErrorDescription() {
        let error = SandboxPathError.parentTraversalNotAllowed("../secret")
        XCTAssertEqual(error.errorDescription, "Parent traversal (..) is not allowed: ../secret")
    }

    func testOutsideSandboxErrorDescription() {
        let error = SandboxPathError.outsideSandbox("escape")
        XCTAssertEqual(error.errorDescription, "Path resolves outside the selected work folder: escape")
    }

    // MARK: - Edge Cases

    func testResolvePathWithEmptyComponents() throws {
        // Multiple slashes should be handled
        let url = try resolver.resolveFileURL(relativePath: "src//file.txt")
        XCTAssertTrue(url.path.hasSuffix("src/file.txt"))
    }

    func testResolvePathWithOnlyWhitespace() throws {
        let url = try resolver.resolveFileURL(relativePath: "   ")
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    func testResolvePathWithNewlines() throws {
        let url = try resolver.resolveFileURL(relativePath: "\nfile.txt\n")
        let expected = tempProjectRoot.appendingPathComponent("file.txt").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    // MARK: - Standardization

    func testProjectRootIsStandardized() {
        let nonStandardRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("./test/../test")
        let resolver = SandboxPathResolver(workFolderRoot: nonStandardRoot)

        // The workFolderRoot should be standardized
        XCTAssertFalse(resolver.workFolderRoot.path.contains(".."))
        XCTAssertFalse(resolver.workFolderRoot.path.contains("./"))
    }

    func testResolvedPathIsStandardized() throws {
        let url = try resolver.resolveFileURL(relativePath: "./subdir/./file.txt")
        XCTAssertFalse(url.path.contains("./"))
    }
}
