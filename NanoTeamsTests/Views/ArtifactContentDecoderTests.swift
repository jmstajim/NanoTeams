import XCTest
@testable import NanoTeams

/// Pins routing for the artifact viewer's content loader.
///
/// Pre-fix `ArtifactDetailBody.loadContent` called `String(contentsOf:encoding:.utf8)`
/// directly, so a non-UTF-8 file (binary side-car, mis-labelled mime, corrupt
/// markdown) surfaced as a generic NSError. The decoder routes those through
/// a `binary` affordance instead — actionable ("open in Finder") rather than
/// confusing ("Couldn't load artifact: NSCocoaErrorDomain Code=261").
final class ArtifactContentDecoderTests: XCTestCase {

    // MARK: - Text path

    func testDecide_validUTF8Markdown_returnsText() {
        let data = "# Hello".data(using: .utf8)!
        let decision = ArtifactContentDecoder.decide(
            data: data, mimeType: "text/markdown", fileExtension: "md"
        )
        XCTAssertEqual(decision, .text("# Hello"))
    }

    func testDecide_emptyText_returnsEmptyText() {
        let decision = ArtifactContentDecoder.decide(
            data: Data(), mimeType: "text/markdown", fileExtension: "md"
        )
        XCTAssertEqual(decision, .text(""))
    }

    // MARK: - Binary fast path (mime / extension)

    func testDecide_pdfMimeType_returnsBinary_evenIfBytesAreUTF8() {
        // Defense in depth: if the caller labels something `application/pdf`
        // we don't second-guess via byte sniffing.
        let data = "fake".data(using: .utf8)!
        let decision = ArtifactContentDecoder.decide(
            data: data, mimeType: "application/pdf", fileExtension: "pdf"
        )
        XCTAssertEqual(decision, .binary(byteCount: 4, fileExtension: "pdf"))
    }

    func testDecide_docxMimeType_returnsBinary() {
        let data = Data([0x50, 0x4B, 0x03, 0x04])  // PK header
        let decision = ArtifactContentDecoder.decide(
            data: data,
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            fileExtension: "docx"
        )
        XCTAssertEqual(decision, .binary(byteCount: 4, fileExtension: "docx"))
    }

    func testDecide_pdfExtension_overridesMissingMime() {
        let decision = ArtifactContentDecoder.decide(
            data: Data([0x25, 0x50, 0x44, 0x46]),  // %PDF
            mimeType: "",
            fileExtension: "PDF"  // case-insensitive
        )
        XCTAssertEqual(decision, .binary(byteCount: 4, fileExtension: "pdf"))
    }

    func testDecide_imageMime_returnsBinary() {
        let decision = ArtifactContentDecoder.decide(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png", fileExtension: "png"
        )
        XCTAssertEqual(decision, .binary(byteCount: 4, fileExtension: "png"))
    }

    // MARK: - Mislabelled binary fallback

    /// Pre-fix the view crashed loading any non-UTF-8 file with a generic
    /// `NSCocoaErrorDomain Code=261`. With the decoder, non-UTF-8 bytes under
    /// a text mime gracefully fall through to the binary affordance.
    func testDecide_nonUTF8BytesUnderTextMime_routesToBinary() {
        let bogusUTF8 = Data([0xFF, 0xFE, 0xFD])
        let decision = ArtifactContentDecoder.decide(
            data: bogusUTF8,
            mimeType: "text/markdown", fileExtension: "md"
        )
        XCTAssertEqual(decision, .binary(byteCount: 3, fileExtension: "md"))
    }

    // MARK: - Unknown mime types fall through to UTF-8

    func testDecide_unknownMimeWithUTF8Bytes_returnsText() {
        // No assumptions for unknown types — try decoding, succeed when valid.
        let data = "{}".data(using: .utf8)!
        let decision = ArtifactContentDecoder.decide(
            data: data, mimeType: "application/x-custom", fileExtension: "weird"
        )
        XCTAssertEqual(decision, .text("{}"))
    }
}
