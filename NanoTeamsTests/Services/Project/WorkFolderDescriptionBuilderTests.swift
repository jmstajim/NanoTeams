import XCTest

@testable import NanoTeams

final class WorkFolderDescriptionBuilderTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Use standardizedFileURL to resolve symlinks (/var -> /private/var on macOS)
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func createFile(named name: String, content: String = "test content") throws {
        let fileURL = tempDir.appendingPathComponent(name)
        // Ensure parent directory exists
        let parentDir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func createDirectory(named name: String) throws {
        let dirURL = tempDir.appendingPathComponent(name)
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
    }

    // MARK: - Basic Input Building Tests

    func testBuildInput_returnsRootName() throws {
        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertEqual(input.rootName, tempDir.lastPathComponent)
    }

    func testBuildInput_emptyProject() {
        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.fileList.isEmpty)
        XCTAssertTrue(input.fileTypeCounts.isEmpty)
        XCTAssertTrue(input.excerpts.isEmpty)
    }

    func testBuildInput_listsFiles() throws {
        try createFile(named: "file1.swift", content: "import Foundation")
        try createFile(named: "file2.swift", content: "class MyClass {}")
        try createFile(named: "README.md", content: "# Project")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertEqual(input.fileList.count, 3)
        XCTAssertTrue(input.fileList.contains("file1.swift"))
        XCTAssertTrue(input.fileList.contains("file2.swift"))
        XCTAssertTrue(input.fileList.contains("README.md"))
    }

    func testBuildInput_countsFileTypes() throws {
        try createFile(named: "a.swift")
        try createFile(named: "b.swift")
        try createFile(named: "c.swift")
        try createFile(named: "d.json")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertEqual(input.fileTypeCounts["swift"], 3)
        XCTAssertEqual(input.fileTypeCounts["json"], 1)
    }

    func testBuildInput_sortsFileList() throws {
        try createFile(named: "z.swift")
        try createFile(named: "a.swift")
        try createFile(named: "m.swift")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertEqual(input.fileList, ["a.swift", "m.swift", "z.swift"])
    }

    // MARK: - Directory Ignoring Tests

    func testBuildInput_ignoresGitDirectory() throws {
        try createDirectory(named: ".git")
        try createFile(named: ".git/config", content: "[core]")
        try createFile(named: "main.swift")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertFalse(input.fileList.contains { $0.contains(".git") })
        XCTAssertTrue(input.fileList.contains("main.swift"))
    }

    func testBuildInput_ignoresNanoteamsDirectory() throws {
        try createDirectory(named: ".nanoteams")
        try createFile(named: ".nanoteams/project.json")
        try createFile(named: "main.swift")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertFalse(input.fileList.contains { $0.contains(".nanoteams") })
    }

    func testBuildInput_ignoresDerivedData() throws {
        try createDirectory(named: "DerivedData")
        try createFile(named: "DerivedData/Build/some.o")
        try createFile(named: "main.swift")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertFalse(input.fileList.contains { $0.contains("DerivedData") })
    }

    func testBuildInput_ignoresNodeModules() throws {
        try createDirectory(named: "node_modules")
        try createFile(named: "node_modules/package/index.js")
        try createFile(named: "app.js")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertFalse(input.fileList.contains { $0.contains("node_modules") })
        XCTAssertTrue(input.fileList.contains("app.js"))
    }

    func testBuildInput_ignoresPods() throws {
        try createDirectory(named: "Pods")
        try createFile(named: "Pods/AFNetworking/AFNetworking.m")
        try createFile(named: "MyApp.swift")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertFalse(input.fileList.contains { $0.contains("Pods") })
    }

    // MARK: - Xcode Project/Workspace Tests

    func testBuildInput_includesXcodeproject() throws {
        try createDirectory(named: "MyApp.xcodeproj")
        try createFile(named: "main.swift")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.fileList.contains("MyApp.xcodeproj"))
    }

    func testBuildInput_includesXcworkspace() throws {
        try createDirectory(named: "MyApp.xcworkspace")
        try createFile(named: "main.swift")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.fileList.contains("MyApp.xcworkspace"))
    }

    // MARK: - Excerpt Tests

    func testBuildInput_extractsExcerpts() throws {
        try createFile(named: "main.swift", content: "import Foundation\nprint(\"Hello\")")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertFalse(input.excerpts.isEmpty)
        XCTAssertTrue(input.excerpts.contains { $0.path == "main.swift" })
    }

    func testBuildInput_prioritizesReadme() throws {
        try createFile(named: "README.md", content: "# My Project\n\nThis is a description.")
        try createFile(named: "other.swift", content: "import Foundation")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        // README should be included in excerpts
        XCTAssertTrue(input.excerpts.contains { $0.path == "README.md" })
    }

    func testBuildInput_prioritizesReadmeLLM() throws {
        try createFile(named: "README_LLM.md", content: "# LLM Guide\n\nInstructions for AI.")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.excerpts.contains { $0.path == "README_LLM.md" })
    }

    func testBuildInput_prioritizesPackageSwift() throws {
        try createFile(named: "Package.swift", content: "// swift-tools-version:5.5")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.excerpts.contains { $0.path == "Package.swift" })
    }

    func testBuildInput_excerptContentTrimmed() throws {
        try createFile(named: "test.swift", content: "   \n\nclass Test {}\n\n   ")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        let excerpt = input.excerpts.first { $0.path == "test.swift" }
        XCTAssertNotNil(excerpt)
        XCTAssertEqual(excerpt?.content, "class Test {}")
    }

    func testBuildInput_limitsExcerpts() throws {
        // Create more files than maxExcerpts
        for i in 1...10 {
            try createFile(named: "file\(i).swift", content: "// File \(i)")
        }

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir, maxExcerpts: 3)

        XCTAssertEqual(input.excerpts.count, 3)
    }

    func testBuildInput_excerptOnlyTextFiles() throws {
        try createFile(named: "code.swift", content: "import Foundation")

        // Binary-like extension (not in text extensions)
        let binaryURL = tempDir.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: binaryURL)

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.excerpts.contains { $0.path == "code.swift" })
        XCTAssertFalse(input.excerpts.contains { $0.path == "image.png" })
    }

    // MARK: - Max Limits Tests

    func testBuildInput_limitsFiles() throws {
        for i in 1...150 {
            try createFile(named: "file\(i).swift")
        }

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir, maxFiles: 50)

        XCTAssertEqual(input.fileList.count, 50)
    }

    func testBuildInput_limitsExcerptSize() throws {
        let longContent = String(repeating: "x", count: 10000)
        try createFile(named: "large.swift", content: longContent)

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir, maxBytesPerExcerpt: 1000)

        let excerpt = input.excerpts.first { $0.path == "large.swift" }
        XCTAssertNotNil(excerpt)
        XCTAssertLessThanOrEqual(excerpt!.content.count, 1000)
    }

    // MARK: - Text Extension Coverage Tests

    func testBuildInput_recognizesSwiftFiles() throws {
        try createFile(named: "app.swift", content: "import UIKit")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.excerpts.contains { $0.path == "app.swift" })
    }

    func testBuildInput_recognizesJavaScriptFiles() throws {
        try createFile(named: "app.js", content: "console.log('hello');")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.excerpts.contains { $0.path == "app.js" })
    }

    func testBuildInput_recognizesTypeScriptFiles() throws {
        try createFile(named: "app.ts", content: "const x: number = 1;")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.excerpts.contains { $0.path == "app.ts" })
    }

    func testBuildInput_recognizesPythonFiles() throws {
        try createFile(named: "app.py", content: "print('hello')")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.excerpts.contains { $0.path == "app.py" })
    }

    func testBuildInput_recognizesYamlFiles() throws {
        try createFile(named: "config.yml", content: "key: value")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.excerpts.contains { $0.path == "config.yml" })
    }

    func testBuildInput_recognizesJsonFiles() throws {
        try createFile(named: "config.json", content: "{\"key\": \"value\"}")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.excerpts.contains { $0.path == "config.json" })
    }

    // MARK: - Nested Directory Tests

    func testBuildInput_handlesNestedDirectories() throws {
        try createDirectory(named: "src/models")
        try createFile(named: "src/main.swift", content: "import Foundation")
        try createFile(named: "src/models/User.swift", content: "struct User {}")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertTrue(input.fileList.contains("src/main.swift"))
        XCTAssertTrue(input.fileList.contains("src/models/User.swift"))
    }

    // MARK: - WorkFolderDescriptionInput Structure Tests

    func testWorkFolderDescriptionInput_hashable() throws {
        let input1 = WorkFolderDescriptionInput(
            rootName: "Project",
            fileList: ["a.swift", "b.swift"],
            fileTypeCounts: ["swift": 2],
            excerpts: []
        )

        let input2 = WorkFolderDescriptionInput(
            rootName: "Project",
            fileList: ["a.swift", "b.swift"],
            fileTypeCounts: ["swift": 2],
            excerpts: []
        )

        XCTAssertEqual(input1, input2)
        XCTAssertEqual(input1.hashValue, input2.hashValue)
    }

    func testFileExcerpt_hashable() {
        let excerpt1 = WorkFolderDescriptionInput.FileExcerpt(path: "test.swift", content: "content")
        let excerpt2 = WorkFolderDescriptionInput.FileExcerpt(path: "test.swift", content: "content")

        XCTAssertEqual(excerpt1, excerpt2)
        XCTAssertEqual(excerpt1.hashValue, excerpt2.hashValue)
    }

    // MARK: - Edge Cases

    func testBuildInput_handlesEmptyFiles() throws {
        try createFile(named: "empty.swift", content: "")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        // Empty file should be in file list but not in excerpts
        XCTAssertTrue(input.fileList.contains("empty.swift"))
        XCTAssertFalse(input.excerpts.contains { $0.path == "empty.swift" })
    }

    func testBuildInput_handlesWhitespaceOnlyFiles() throws {
        try createFile(named: "whitespace.swift", content: "   \n\n   \t  ")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        // Whitespace-only file should be in file list but not in excerpts (trimmed to empty)
        XCTAssertTrue(input.fileList.contains("whitespace.swift"))
        // After trimming, content is empty, so it won't be added to excerpts
        XCTAssertFalse(input.excerpts.contains { $0.path == "whitespace.swift" })
    }

    func testBuildInput_nonExistentDirectory() {
        let nonExistent = tempDir.appendingPathComponent("does_not_exist")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: nonExistent)

        XCTAssertEqual(input.rootName, "does_not_exist")
        XCTAssertTrue(input.fileList.isEmpty)
        XCTAssertTrue(input.excerpts.isEmpty)
    }

    func testBuildInput_duplicateFileNames() throws {
        try createDirectory(named: "dir1")
        try createDirectory(named: "dir2")
        try createFile(named: "dir1/README.md", content: "# Dir1")
        try createFile(named: "dir2/README.md", content: "# Dir2")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        // Both files should be in file list
        XCTAssertTrue(input.fileList.contains("dir1/README.md"))
        XCTAssertTrue(input.fileList.contains("dir2/README.md"))

        // Only one excerpt per unique filename (first found wins for excerpts)
        let readmeExcerpts = input.excerpts.filter { $0.path.contains("README.md") }
        XCTAssertEqual(readmeExcerpts.count, 1)
    }
}
