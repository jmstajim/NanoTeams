import XCTest

@testable import NanoTeams

/// Integration tests for vision analysis: signal creation, constants validation,
/// default storage compatibility. Validates VisionAnalysis configuration and ToolSignal creation.
@MainActor
final class EndToEndVisionAnalysisTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: Vision signal has correct fields

    func testVision_signalCreation() {
        let signal = ToolSignal.visionAnalysis(
            imagePath: "/project/screenshot.png",
            prompt: "Describe what you see"
        )

        if case .visionAnalysis(let path, let prompt) = signal {
            XCTAssertEqual(path, "/project/screenshot.png")
            XCTAssertEqual(prompt, "Describe what you see")
        } else {
            XCTFail("Should create visionAnalysis signal")
        }
    }

    // MARK: - Test 2: Invalid path handling

    func testVision_invalidPath_detected() {
        let nonExistentPath = tempDir.appendingPathComponent("nonexistent.png").path
        let exists = FileManager.default.fileExists(atPath: nonExistentPath)
        XCTAssertFalse(exists, "Non-existent file should be detected")
    }

    // MARK: - Test 3: Supported image extensions

    func testVision_supportedExtensions() {
        let supported = VisionConstants.supportedExtensions

        XCTAssertTrue(supported.contains("png"), "Should support PNG")
        XCTAssertTrue(supported.contains("jpg"), "Should support JPG")
        XCTAssertTrue(supported.contains("jpeg"), "Should support JPEG")
    }

    // MARK: - Test 4: analyze_image allowed in default storage

    func testVision_allowedInDefaultStorage() {
        let blocked = ToolHandlerRegistry.defaultStorageBlocked
        let analyzeImage = ToolNames.analyzeImage

        XCTAssertFalse(blocked.contains(analyzeImage),
                       "analyze_image should NOT be blocked in default storage")
    }

    // MARK: - Test 5: Vision MIME types defined

    func testVision_mimeTypes_defined() {
        let mimeTypes = VisionConstants.mimeTypes

        XCTAssertFalse(mimeTypes.isEmpty, "Vision MIME types should be defined")
        XCTAssertEqual(mimeTypes["png"], "image/png", "Should map png to image/png")
    }

    // MARK: - Test 6: Max image size is reasonable

    func testVision_maxImageBytes_reasonable() {
        let maxBytes = VisionConstants.maxImageBytes

        XCTAssertGreaterThan(maxBytes, 0, "Max image bytes should be positive")
        XCTAssertLessThanOrEqual(maxBytes, 20 * 1024 * 1024,
                                 "Max image bytes should be <= 20MB")
    }
}
