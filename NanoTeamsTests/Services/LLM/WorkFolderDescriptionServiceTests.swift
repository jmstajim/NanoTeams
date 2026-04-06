import XCTest

@testable import NanoTeams

final class WorkFolderDescriptionServiceTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var service: WorkFolderDescriptionService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = WorkFolderDescriptionService()
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        tempDir = nil
//        service = nil
        try super.tearDownWithError()
    }

    private func createFile(named name: String, content: String = "test content") throws {
        let fileURL = tempDir.appendingPathComponent(name)
        let parentDir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Service Initialization Tests

    func testServiceInitialization() {
        XCTAssertNotNil(service)
    }

    // MARK: - Input Building Integration Tests
    // These tests verify that the service can correctly build input from the project

    func testGenerateUsesWorkFolderDescriptionBuilder() async throws {
        // Create a simple project structure
        try createFile(named: "README.md", content: "# Test Project\nA simple test project.")
        try createFile(named: "main.swift", content: "import Foundation\nprint(\"Hello\")")

        // Build the input directly to verify it works
        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertEqual(input.rootName, tempDir.lastPathComponent)
        XCTAssertTrue(input.fileList.contains("README.md"))
        XCTAssertTrue(input.fileList.contains("main.swift"))
        XCTAssertFalse(input.excerpts.isEmpty)
    }

    func testProjectInputWithMultipleFileTypes() async throws {
        try createFile(named: "app.swift", content: "import UIKit")
        try createFile(named: "config.json", content: "{\"key\": \"value\"}")
        try createFile(named: "styles.css", content: "body { color: red; }")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertEqual(input.fileTypeCounts["swift"], 1)
        XCTAssertEqual(input.fileTypeCounts["json"], 1)
        XCTAssertEqual(input.fileTypeCounts["css"], 1)
    }

    func testProjectInputExcerptExtraction() async throws {
        let swiftContent = """
        import Foundation

        class MyClass {
            func doSomething() {
                print("Hello")
            }
        }
        """
        try createFile(named: "MyClass.swift", content: swiftContent)

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        let excerpt = input.excerpts.first { $0.path == "MyClass.swift" }
        XCTAssertNotNil(excerpt)
        XCTAssertTrue(excerpt!.content.contains("class MyClass"))
    }

    func testProjectInputHandlesEmptyProject() async throws {
        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        XCTAssertEqual(input.rootName, tempDir.lastPathComponent)
        XCTAssertTrue(input.fileList.isEmpty)
        XCTAssertTrue(input.fileTypeCounts.isEmpty)
        XCTAssertTrue(input.excerpts.isEmpty)
    }

    func testProjectInputPrioritizesImportantFiles() async throws {
        // Create many files
        for i in 1...20 {
            try createFile(named: "file\(i).swift", content: "// File \(i)")
        }
        // Create priority files
        try createFile(named: "README.md", content: "# Important README")
        try createFile(named: "Package.swift", content: "// swift-tools-version:5.5")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir, maxExcerpts: 3)

        // Priority files should be in excerpts
        let excerptPaths = input.excerpts.map { $0.path }
        XCTAssertTrue(excerptPaths.contains("README.md"))
        XCTAssertTrue(excerptPaths.contains("Package.swift"))
    }

    // MARK: - Error Handling Tests

    func testProjectInputWithInvalidPath() async throws {
        let invalidPath = tempDir.appendingPathComponent("nonexistent")
        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: invalidPath)

        // Should return empty input rather than crash
        XCTAssertEqual(input.rootName, "nonexistent")
        XCTAssertTrue(input.fileList.isEmpty)
    }

    // MARK: - Prompt Building Verification Tests

    func testPromptBuildingWithFileTypes() async throws {
        try createFile(named: "a.swift")
        try createFile(named: "b.swift")
        try createFile(named: "c.swift")
        try createFile(named: "d.json")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        // Verify file types are counted correctly for prompt building
        let sorted = input.fileTypeCounts.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        let top = sorted.prefix(8).map { "\($0.key): \($0.value)" }.joined(separator: ", ")

        XCTAssertTrue(top.contains("swift: 3"))
        XCTAssertTrue(top.contains("json: 1"))
    }

    func testPromptBuildingWithExcerpts() async throws {
        try createFile(named: "main.swift", content: "import Foundation\nclass App {}")

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir)

        // Verify excerpts are available for prompt
        XCTAssertFalse(input.excerpts.isEmpty)
        let mainExcerpt = input.excerpts.first { $0.path == "main.swift" }
        XCTAssertNotNil(mainExcerpt)
        XCTAssertTrue(mainExcerpt!.content.contains("import Foundation"))
    }

    // MARK: - Configuration Parameter Tests

    func testMaxFilesConfiguration() async throws {
        for i in 1...100 {
            try createFile(named: "file\(i).txt", content: "content")
        }

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir, maxFiles: 10)

        XCTAssertEqual(input.fileList.count, 10)
    }

    func testMaxExcerptsConfiguration() async throws {
        for i in 1...20 {
            try createFile(named: "file\(i).swift", content: "// Swift file \(i)")
        }

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir, maxExcerpts: 5)

        XCTAssertEqual(input.excerpts.count, 5)
    }

    func testMaxBytesPerExcerptConfiguration() async throws {
        let longContent = String(repeating: "x", count: 5000)
        try createFile(named: "large.swift", content: longContent)

        let input = WorkFolderDescriptionBuilder.buildInput(workFolderRoot: tempDir, maxBytesPerExcerpt: 500)

        let excerpt = input.excerpts.first { $0.path == "large.swift" }
        XCTAssertNotNil(excerpt)
        XCTAssertLessThanOrEqual(excerpt!.content.count, 500)
    }
}
