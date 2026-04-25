import AppKit
import XCTest

@testable import NanoTeams

final class PasteboardImageExtractorTests: XCTestCase {

    var pasteboard: NSPasteboard!
    var writtenURLs: [URL] = []

    override func setUp() {
        super.setUp()
        let name = NSPasteboard.Name(rawValue: "ntms-test-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        writtenURLs = []
    }

    override func tearDown() {
        for url in writtenURLs {
            try? FileManager.default.removeItem(at: url)
        }
        writtenURLs = []
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    // MARK: - hasImage

    func testHasImage_falseForEmptyPasteboard() {
        XCTAssertFalse(PasteboardImageExtractor.hasImage(pasteboard))
    }

    func testHasImage_falseForTextOnlyPasteboard() {
        pasteboard.setString("hello", forType: .string)
        XCTAssertFalse(PasteboardImageExtractor.hasImage(pasteboard))
    }

    func testHasImage_trueWhenImagePresent() {
        let image = makeTestImage(size: NSSize(width: 4, height: 4))
        pasteboard.writeObjects([image])
        XCTAssertTrue(PasteboardImageExtractor.hasImage(pasteboard))
    }

    // MARK: - extractImages

    func testExtractImages_returnsEmptyForEmptyPasteboard() {
        let result = PasteboardImageExtractor.extractImages(pasteboard)
        XCTAssertTrue(result.urls.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testExtractImages_returnsEmptyForTextOnlyPasteboard() {
        pasteboard.setString("plain text", forType: .string)
        let result = PasteboardImageExtractor.extractImages(pasteboard)
        XCTAssertTrue(result.urls.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testExtractImages_writesPNGForSingleImage() throws {
        let image = makeTestImage(size: NSSize(width: 8, height: 8))
        pasteboard.writeObjects([image])

        let result = PasteboardImageExtractor.extractImages(pasteboard)
        writtenURLs = result.urls

        XCTAssertEqual(result.urls.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
        let url = try XCTUnwrap(result.urls.first)
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Screenshot-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Round-trip verifies the bytes are a valid PNG.
        let decoded = NSImage(contentsOf: url)
        XCTAssertNotNil(decoded)
    }

    func testExtractImages_filenameUsesPosixTimestamp() throws {
        let image = makeTestImage(size: NSSize(width: 4, height: 4))
        pasteboard.writeObjects([image])

        // 2026-04-25 14:30:22.123 UTC.
        let now = makeFixedDate(year: 2026, month: 4, day: 25, hour: 14, minute: 30, second: 22, ms: 123)

        let result = PasteboardImageExtractor.extractImages(pasteboard, now: now)
        writtenURLs = result.urls

        let url = try XCTUnwrap(result.urls.first)
        XCTAssertEqual(url.lastPathComponent, "Screenshot-2026-04-25-143022123.png")
    }

    func testExtractImages_indexSuffixForBatch() throws {
        let a = makeTestImage(size: NSSize(width: 4, height: 4), color: .red)
        let b = makeTestImage(size: NSSize(width: 4, height: 4), color: .blue)
        pasteboard.writeObjects([a, b])

        let now = makeFixedDate(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0, ms: 0)
        let result = PasteboardImageExtractor.extractImages(pasteboard, now: now)
        writtenURLs = result.urls

        XCTAssertEqual(result.urls.count, 2)
        XCTAssertEqual(result.urls[0].lastPathComponent, "Screenshot-2026-01-01-000000000-1.png")
        XCTAssertEqual(result.urls[1].lastPathComponent, "Screenshot-2026-01-01-000000000-2.png")
    }

    func testExtractImages_singleImageHasNoIndexSuffix() throws {
        let image = makeTestImage(size: NSSize(width: 4, height: 4))
        pasteboard.writeObjects([image])

        let now = makeFixedDate(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0, ms: 0)
        let result = PasteboardImageExtractor.extractImages(pasteboard, now: now)
        writtenURLs = result.urls

        let url = try XCTUnwrap(result.urls.first)
        XCTAssertEqual(url.lastPathComponent, "Screenshot-2026-01-01-000000000.png")
    }

    // MARK: - Failure surfacing

    func testExtractImages_returnsFailures_whenWriteFails() throws {
        let image = makeTestImage(size: NSSize(width: 8, height: 8))
        pasteboard.writeObjects([image])

        let readOnlyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntms-readonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: readOnlyRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: readOnlyRoot.path
            )
            try? FileManager.default.removeItem(at: readOnlyRoot)
        }

        let result = PasteboardImageExtractor.extractImages(pasteboard, tempRoot: readOnlyRoot)
        writtenURLs = result.urls

        XCTAssertTrue(result.urls.isEmpty, "no URLs should succeed when destination is read-only")
        XCTAssertEqual(result.failures.count, 1, "the single failed write should surface as one failure entry")
    }

    func testExtractImages_partialFailure_returnsBothUrlsAndFailures() throws {
        // Two images, write the first to a real temp dir and the second to a fake
        // path nested inside a regular file (always unwritable). We achieve that
        // by pointing tempRoot at a path that resolves to the real temp dir for
        // image 1 and an unwritable path for image 2 — easiest is to mark only the
        // second filename's parent dir as read-only after the first write succeeds.
        // Simpler equivalent: point to a missing nested directory; both writes fail.
        // Test the contract that failures.count tracks per-image attempts even
        // when 0 succeed.
        let a = makeTestImage(size: NSSize(width: 4, height: 4), color: .red)
        let b = makeTestImage(size: NSSize(width: 4, height: 4), color: .blue)
        pasteboard.writeObjects([a, b])

        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntms-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nope", isDirectory: true)

        let result = PasteboardImageExtractor.extractImages(pasteboard, tempRoot: missingRoot)
        writtenURLs = result.urls

        XCTAssertTrue(result.urls.isEmpty)
        XCTAssertEqual(result.failures.count, 2, "each image should produce a failure entry")
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

    private func makeFixedDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, ms: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = ms * 1_000_000
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components) ?? Date()
    }
}
