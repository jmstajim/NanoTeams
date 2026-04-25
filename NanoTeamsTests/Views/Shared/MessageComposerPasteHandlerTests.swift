import AppKit
import XCTest

@testable import NanoTeams

@MainActor
final class MessageComposerPasteHandlerTests: XCTestCase {

    var pasteboard: NSPasteboard!
    var stagedFiles: [URL] = []

    override func setUp() {
        super.setUp()
        let name = NSPasteboard.Name(rawValue: "ntms-paste-test-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        stagedFiles = []
        PasteMonitorRegistry.shared._testReset()
    }

    override func tearDown() {
        for url in stagedFiles {
            try? FileManager.default.removeItem(at: url)
        }
        stagedFiles = []
        pasteboard.releaseGlobally()
        pasteboard = nil
        PasteMonitorRegistry.shared._testReset()
        super.tearDown()
    }

    // MARK: - dispatch — classification

    func testDispatch_emptyPasteboard_passesThrough() {
        let action = MessageComposerPasteHandler.dispatch(pasteboard: pasteboard)
        XCTAssertEqual(action, .passThrough)
    }

    func testDispatch_textOnly_passesThrough() {
        pasteboard.setString("plain text", forType: .string)
        let action = MessageComposerPasteHandler.dispatch(pasteboard: pasteboard)
        XCTAssertEqual(action, .passThrough)
    }

    func testDispatch_fileURLs_returnsStageFiles() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntms-paste-\(UUID().uuidString).txt", isDirectory: false)
        try Data("hello".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        pasteboard.writeObjects([tmp as NSURL])

        let action = MessageComposerPasteHandler.dispatch(pasteboard: pasteboard)
        guard case .stageFiles(let urls) = action else {
            XCTFail("expected .stageFiles, got \(action)")
            return
        }
        XCTAssertEqual(urls.first?.lastPathComponent, tmp.lastPathComponent)
    }

    func testDispatch_imageOnly_returnsStageImages_alsoHasTextFalse() {
        let image = makeTestImage(size: NSSize(width: 4, height: 4))
        pasteboard.writeObjects([image])

        let stub: PasteboardImageExtractor.ExtractionResult = .init(
            urls: [URL(fileURLWithPath: "/tmp/Screenshot-stub.png")],
            failures: []
        )
        let action = MessageComposerPasteHandler.dispatch(
            pasteboard: pasteboard,
            extractImages: { _ in stub }
        )
        guard case .stageImages(let result, let alsoHasText) = action else {
            XCTFail("expected .stageImages, got \(action)")
            return
        }
        XCTAssertEqual(result, stub)
        XCTAssertFalse(alsoHasText, "no text on pasteboard → caption pass-through must NOT trigger")
    }

    func testDispatch_imageWithText_returnsStageImages_alsoHasTextTrue() {
        let image = makeTestImage(size: NSSize(width: 4, height: 4))
        pasteboard.writeObjects([image])
        // Slack-style: image + caption.
        pasteboard.setString("a caption", forType: .string)

        let stub: PasteboardImageExtractor.ExtractionResult = .init(
            urls: [URL(fileURLWithPath: "/tmp/Screenshot-stub.png")],
            failures: []
        )
        let action = MessageComposerPasteHandler.dispatch(
            pasteboard: pasteboard,
            extractImages: { _ in stub }
        )
        guard case .stageImages(_, let alsoHasText) = action else {
            XCTFail("expected .stageImages, got \(action)")
            return
        }
        XCTAssertTrue(alsoHasText, "string + image must signal caption pass-through")
    }

    func testDispatch_imageExtractionFailure_isSurfacedInResult() {
        let image = makeTestImage(size: NSSize(width: 4, height: 4))
        pasteboard.writeObjects([image])

        let failed: PasteboardImageExtractor.ExtractionResult = .init(
            urls: [],
            failures: ["image: disk full"]
        )
        let action = MessageComposerPasteHandler.dispatch(
            pasteboard: pasteboard,
            extractImages: { _ in failed }
        )
        guard case .stageImages(let result, _) = action else {
            XCTFail("expected .stageImages, got \(action)")
            return
        }
        XCTAssertTrue(result.urls.isEmpty)
        XCTAssertEqual(result.failures, ["image: disk full"])
    }

    // MARK: - PasteMonitorRegistry — cross-instance arbitration

    func testRegistry_registerSetsActiveOwner() {
        let id = UUID()
        var removed = false
        PasteMonitorRegistry.shared.register(ownerID: id, remove: { removed = true })
        XCTAssertEqual(PasteMonitorRegistry.shared.activeOwnerID, id)
        XCTAssertFalse(removed)
    }

    func testRegistry_registerNew_evictsPreviousAndCallsItsRemove() {
        let first = UUID()
        let second = UUID()
        var firstRemoved = false
        var secondRemoved = false
        PasteMonitorRegistry.shared.register(ownerID: first, remove: { firstRemoved = true })
        PasteMonitorRegistry.shared.register(ownerID: second, remove: { secondRemoved = true })

        XCTAssertTrue(firstRemoved, "previous owner's monitor must be removed when a new one registers")
        XCTAssertFalse(secondRemoved)
        XCTAssertEqual(PasteMonitorRegistry.shared.activeOwnerID, second)
    }

    func testRegistry_releaseByCurrentOwner_clearsAndCallsRemove() {
        let id = UUID()
        var removed = false
        PasteMonitorRegistry.shared.register(ownerID: id, remove: { removed = true })

        PasteMonitorRegistry.shared.release(ownerID: id)
        XCTAssertTrue(removed)
        XCTAssertNil(PasteMonitorRegistry.shared.activeOwnerID)
    }

    func testRegistry_releaseByEvictedOwner_isNoOp() {
        let first = UUID()
        let second = UUID()
        var secondRemoved = false
        PasteMonitorRegistry.shared.register(ownerID: first, remove: { })
        PasteMonitorRegistry.shared.register(ownerID: second, remove: { secondRemoved = true })

        // The first owner doesn't know it was evicted — its release must be a no-op,
        // not accidentally remove the new owner's monitor.
        PasteMonitorRegistry.shared.release(ownerID: first)
        XCTAssertFalse(secondRemoved)
        XCTAssertEqual(PasteMonitorRegistry.shared.activeOwnerID, second)
    }

    // MARK: - Helpers

    private func makeTestImage(size: NSSize, color: NSColor = .black) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}
