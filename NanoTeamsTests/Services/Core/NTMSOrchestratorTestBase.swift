import XCTest

@testable import NanoTeams

/// Base class for tests that need a fresh NTMSOrchestrator + temp directory.
/// Subclass and add test methods. setUp/tearDown are handled automatically.
@MainActor
class NTMSOrchestratorTestBase: XCTestCase {

    var sut: NTMSOrchestrator!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        sut = NTMSOrchestrator(repository: NTMSRepository())
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        sut = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }
}
