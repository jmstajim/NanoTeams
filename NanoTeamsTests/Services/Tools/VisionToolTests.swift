import XCTest

@testable import NanoTeams

final class VisionToolTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var registry: ToolRegistry!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        let (reg, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        registry = reg
        runtime = run

        context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: Int(),
            runID: 0,
            roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        registry = nil
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Registration

    func testAnalyzeImageToolRegistered() {
        XCTAssertTrue(registry.registeredToolNames.contains("analyze_image"))
    }

    func testAliasesRegistered() {
        let aliases = ToolRegistry.defaultAliases
        XCTAssertEqual(aliases["describe_image"], "analyze_image")
        XCTAssertEqual(aliases["vision"], "analyze_image")
    }

    // MARK: - Valid Input

    func testValidImage_returnsVisionAnalysisSignal() throws {
        let imagePath = "screenshot.png"
        let imageURL = tempDir.appendingPathComponent(imagePath)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL) // minimal PNG header bytes

        let call = StepToolCall(
            name: "analyze_image",
            argumentsJSON: """
            {"path": "\(imagePath)", "prompt": "Describe this UI"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(
            results[0].signal,
            .visionAnalysis(imagePath: imagePath, prompt: "Describe this UI")
        )
    }

    // MARK: - Extension Validation

    func testUnsupportedExtension_returnsError() throws {
        let imagePath = "document.pdf"
        let fileURL = tempDir.appendingPathComponent(imagePath)
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: fileURL)

        let call = StepToolCall(
            name: "analyze_image",
            argumentsJSON: """
            {"path": "\(imagePath)", "prompt": "Read this"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Unsupported image format"))
    }

    func testAllSupportedExtensions() throws {
        for ext in VisionConstants.supportedExtensions {
            let imagePath = "test_image.\(ext)"
            let fileURL = tempDir.appendingPathComponent(imagePath)
            try Data([0xFF]).write(to: fileURL)

            let call = StepToolCall(
                name: "analyze_image",
                argumentsJSON: """
                {"path": "\(imagePath)", "prompt": "Describe"}
                """
            )
            let results = runtime.executeAll(context: context, toolCalls: [call])

            XCTAssertEqual(results.count, 1, "Extension .\(ext)")
            XCTAssertFalse(results[0].isError, "Extension .\(ext) should succeed")
            XCTAssertEqual(
                results[0].signal,
                .visionAnalysis(imagePath: imagePath, prompt: "Describe"),
                "Extension .\(ext)"
            )

            try? fileManager.removeItem(at: fileURL)
        }
    }

    // MARK: - File Not Found

    func testMissingFile_returnsError() {
        let call = StepToolCall(
            name: "analyze_image",
            argumentsJSON: """
            {"path": "nonexistent.png", "prompt": "Describe"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("not found"))
    }

    // MARK: - Sandbox Escape

    func testSandboxEscape_returnsError() {
        let call = StepToolCall(
            name: "analyze_image",
            argumentsJSON: """
            {"path": "../../etc/passwd.png", "prompt": "Read"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
    }

    // MARK: - Missing Arguments

    func testMissingPath_returnsError() {
        let call = StepToolCall(
            name: "analyze_image",
            argumentsJSON: """
            {"prompt": "Describe this"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
    }

    func testMissingPrompt_returnsError() {
        let call = StepToolCall(
            name: "analyze_image",
            argumentsJSON: """
            {"path": "image.png"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
    }

    // MARK: - MIME Type Lookup

    func testMimeTypeLookup() {
        let mimeTypes = VisionConstants.mimeTypes
        XCTAssertEqual(mimeTypes["png"], "image/png")
        XCTAssertEqual(mimeTypes["jpg"], "image/jpeg")
        XCTAssertEqual(mimeTypes["jpeg"], "image/jpeg")
        XCTAssertEqual(mimeTypes["gif"], "image/gif")
        XCTAssertEqual(mimeTypes["webp"], "image/webp")
        XCTAssertEqual(mimeTypes["bmp"], "image/bmp")
    }

    // MARK: - Constants

    func testVisionConstants() {
        XCTAssertEqual(VisionConstants.maxImageBytes, 10_485_760)
        XCTAssertFalse(VisionConstants.supportedExtensions.isEmpty)
        XCTAssertFalse(VisionConstants.mimeTypes.isEmpty)
    }
}
