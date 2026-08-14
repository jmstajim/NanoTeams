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

        // 2026-04-25 21:43:22.123 UTC. Hour, minute and second are mutually
        // distinct on purpose — that is what proves the field ORDER in the name.
        let now = makeFixedDate(year: 2026, month: 4, day: 25, hour: 21, minute: 43, second: 22, ms: 123)

        let result = PasteboardImageExtractor.extractImages(pasteboard, now: now)
        writtenURLs = result.urls

        let url = try XCTUnwrap(result.urls.first)
        XCTAssertEqual(url.lastPathComponent, "Screenshot-2026-04-25-214322123.png")
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

    // MARK: - Wave 11 — encode failure (pngData → nil)

    /// A zero-size PDF reads back off the pasteboard as a real `NSImage` with one representation
    /// and `size == .zero`, so `tiffRepresentation` is nil and the image cannot be encoded. The
    /// extractor must SURFACE that as a failure entry rather than silently dropping the image —
    /// a paste that quietly loses one of three screenshots is worse than one that says so.
    ///
    /// RED: change `guard let png = pngData(for: image) else { … }` in `extractImages` to
    /// `let png = pngData(for: image) ?? Data()` → `failures` comes back empty (and a 0-byte file
    /// is written instead), failing the equality below.
    func testExtractImages_undecodableImage_surfacesFailureInsteadOfDropping() throws {
        let pdf = Self.zeroSizePDFData()
        // Fixture precondition: if a future macOS starts rasterizing a zero-size PDF, this fails
        // HERE, naming the fixture, rather than further down naming the contract.
        let probe = try XCTUnwrap(NSImage(data: pdf), "fixture must still decode as an NSImage")
        XCTAssertNil(probe.tiffRepresentation, "fixture must still be un-encodable on this OS")

        let item = NSPasteboardItem()
        item.setData(pdf, forType: .pdf)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let result = PasteboardImageExtractor.extractImages(pasteboard)
        writtenURLs = result.urls

        XCTAssertTrue(result.urls.isEmpty, "nothing encodable — no file should be written")
        XCTAssertEqual(result.failures, ["image: could not encode as PNG"],
                       "a single un-encodable image reports the un-indexed label")
    }

    /// An un-encodable image FIRST, an encodable one second. The loop must `continue` past the bad
    /// one rather than abandon the batch, and the survivor must keep its ORIGINAL 1-based index
    /// suffix so written filenames stay aligned with the failure labels the user is shown.
    ///
    /// RED: change that guard's `continue` to `break` → `urls` comes back empty and both the count
    /// and filename assertions fail.
    func testExtractImages_undecodableFirst_stillWritesTheRest_andLabelsByOriginalIndex() throws {
        let pdf = Self.zeroSizePDFData()
        let probe = try XCTUnwrap(NSImage(data: pdf), "fixture must still decode as an NSImage")
        XCTAssertNil(probe.tiffRepresentation, "fixture must still be un-encodable on this OS")

        let bad = NSPasteboardItem()
        bad.setData(pdf, forType: .pdf)
        let good = NSPasteboardItem()
        good.setData(try makePNGData(), forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([bad, good]))

        let now = makeFixedDate(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0, ms: 0)
        let result = PasteboardImageExtractor.extractImages(pasteboard, now: now)
        writtenURLs = result.urls

        XCTAssertEqual(result.urls.count, 1,
                       "an un-encodable image must not abandon the images after it")
        XCTAssertEqual(result.urls.first?.lastPathComponent, "Screenshot-2026-01-01-000000000-2.png",
                       "the survivor keeps its original index — filenames stay aligned with labels")
        XCTAssertEqual(result.failures, ["image 1: could not encode as PNG"],
                       "the failure names the image by its original 1-based position")
    }

    /// PNG bytes of a real 4x4 image, for writing an encodable pasteboard item.
    private func makePNGData(color: NSColor = .red) throws -> Data {
        let image = makeTestImage(size: NSSize(width: 4, height: 4), color: color)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// A one-page PDF whose mediaBox is `.zero`, produced by CoreGraphics itself — so it is
    /// generated by the same framework that reads it back, rather than hand-written PDF syntax.
    /// `NSImage` accepts it from the pasteboard but cannot rasterize it.
    private static func zeroSizePDFData() -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return Data() }
        var mediaBox = CGRect.zero
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
