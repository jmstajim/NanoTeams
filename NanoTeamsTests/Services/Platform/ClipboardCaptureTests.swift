import XCTest

@testable import NanoTeams

// MARK: - ClipboardCaptureResult Tests

final class ClipboardCaptureResultTests: XCTestCase {

    // MARK: - Init Defaults

    func testInit_textNilAndFileURLsEmpty() {
        let result = ClipboardCaptureResult(text: nil, fileURLs: [])
        XCTAssertNil(result.text)
        XCTAssertTrue(result.fileURLs.isEmpty)
    }

    func testInit_textOnly() {
        let result = ClipboardCaptureResult(text: "hello", fileURLs: [])
        XCTAssertEqual(result.text, "hello")
        XCTAssertTrue(result.fileURLs.isEmpty)
    }

    func testInit_fileURLsOnly() {
        let url = URL(fileURLWithPath: "/tmp/test.png")
        let result = ClipboardCaptureResult(text: nil, fileURLs: [url])
        XCTAssertNil(result.text)
        XCTAssertEqual(result.fileURLs.count, 1)
        XCTAssertEqual(result.fileURLs.first, url)
    }

    func testInit_bothTextAndFileURLs() {
        let url = URL(fileURLWithPath: "/tmp/doc.pdf")
        let result = ClipboardCaptureResult(text: "path info", fileURLs: [url])
        XCTAssertEqual(result.text, "path info")
        XCTAssertEqual(result.fileURLs.count, 1)
    }

    func testInit_multipleFileURLs() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.png"),
            URL(fileURLWithPath: "/tmp/b.jpg"),
            URL(fileURLWithPath: "/tmp/c.pdf"),
        ]
        let result = ClipboardCaptureResult(text: nil, fileURLs: urls)
        XCTAssertEqual(result.fileURLs.count, 3)
        XCTAssertEqual(result.fileURLs, urls)
    }

    // MARK: - Mutability

    func testText_isMutable() {
        var result = ClipboardCaptureResult(text: "original", fileURLs: [])
        result.text = "updated"
        XCTAssertEqual(result.text, "updated")
    }

    func testText_canBeSetToNil() {
        var result = ClipboardCaptureResult(text: "something", fileURLs: [])
        result.text = nil
        XCTAssertNil(result.text)
    }

    func testFileURLs_isMutable() {
        var result = ClipboardCaptureResult(text: nil, fileURLs: [])
        result.fileURLs.append(URL(fileURLWithPath: "/tmp/new.txt"))
        XCTAssertEqual(result.fileURLs.count, 1)
    }

    // MARK: - Empty Text Edge Cases

    func testInit_emptyStringText() {
        let result = ClipboardCaptureResult(text: "", fileURLs: [])
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.text?.isEmpty ?? true == false, "Empty string is not nil")
    }

    func testInit_whitespaceOnlyText() {
        let result = ClipboardCaptureResult(text: "   \n\t", fileURLs: [])
        XCTAssertNotNil(result.text)
    }
}

// MARK: - SourceContext.parse Tests

final class SourceContextParseTests: XCTestCase {

    func testParse_enrichedTextWithRange() {
        let text = "\u{200B}// Source: NanoTeams/Views/MyView.swift:42-51\nfunc myMethod() {\n    print(\"hello\")\n}"
        let result = SourceContext.parse(text)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.source, "NanoTeams/Views/MyView.swift:42-51")
        XCTAssertEqual(result?.body, "func myMethod() {\n    print(\"hello\")\n}")
    }

    func testParse_enrichedTextWithSingleLine() {
        let text = "\u{200B}// Source: main.swift:10\nlet x = 42"
        let result = SourceContext.parse(text)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.source, "main.swift:10")
        XCTAssertEqual(result?.body, "let x = 42")
    }

    func testParse_enrichedTextWithNoLineInfo() {
        let text = "\u{200B}// Source: README.md\nSome content here"
        let result = SourceContext.parse(text)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.source, "README.md")
        XCTAssertEqual(result?.body, "Some content here")
    }

    func testParse_plainTextWithoutPrefix_returnsNil() {
        let result = SourceContext.parse("just some plain text\nwith newlines")
        XCTAssertNil(result)
    }

    func testParse_userCodeWithSourceComment_returnsNil() {
        // User code starting with "// Source:" (no zero-width space sentinel)
        let result = SourceContext.parse("// Source: this is a comment\nlet x = 1")
        XCTAssertNil(result, "Should not parse user code as enriched text")
    }

    func testParse_noNewline_returnsNil() {
        let text = "\u{200B}// Source: file.swift:10"
        XCTAssertNil(SourceContext.parse(text))
    }

    func testParse_emptyBody_returnsNil() {
        let text = "\u{200B}// Source: file.swift:10\n"
        XCTAssertNil(SourceContext.parse(text))
    }

    func testParse_emptyString_returnsNil() {
        XCTAssertNil(SourceContext.parse(""))
    }

    func testParse_multilineBody_preservesAllLines() {
        let body = "line1\nline2\nline3"
        let text = "\u{200B}// Source: test.swift:1-3\n\(body)"
        let result = SourceContext.parse(text)

        XCTAssertEqual(result?.body, body)
    }

    func testParse_roundTrip_matchesEnrichFormat() {
        // Verify parse works with the exact format enrichText produces
        let prefix = "\u{200B}// Source: "
        let enriched = "\(prefix)NanoTeams/Services/MyService.swift:100-120\nclass MyService {}"
        let result = SourceContext.parse(enriched)

        XCTAssertEqual(result?.source, "NanoTeams/Services/MyService.swift:100-120")
        XCTAssertEqual(result?.body, "class MyService {}")
    }

    func testParse_bodyWithSourceComment_preservesIt() {
        // Body itself contains "// Source:" — should not be stripped
        let text = "\u{200B}// Source: file.swift:1\n// Source: original attribution\nlet x = 1"
        let result = SourceContext.parse(text)

        XCTAssertEqual(result?.source, "file.swift:1")
        XCTAssertEqual(result?.body, "// Source: original attribution\nlet x = 1")
    }
}

// MARK: - SourceContext Struct Tests

final class SourceContextStructTests: XCTestCase {

    func testInit_allFields() {
        let ctx = SourceContext(filePath: "/Users/alex/Project/file.swift", fileName: "file.swift", lineStart: 10, lineEnd: 20)

        XCTAssertEqual(ctx.filePath, "/Users/alex/Project/file.swift")
        XCTAssertEqual(ctx.fileName, "file.swift")
        XCTAssertEqual(ctx.lineStart, 10)
        XCTAssertEqual(ctx.lineEnd, 20)
    }

    func testInit_nilLines() {
        let ctx = SourceContext(filePath: "/path/to/file.txt", fileName: "file.txt", lineStart: nil, lineEnd: nil)

        XCTAssertNil(ctx.lineStart)
        XCTAssertNil(ctx.lineEnd)
    }

    func testInit_singleLine() {
        let ctx = SourceContext(filePath: "/path", fileName: "f.swift", lineStart: 5, lineEnd: 5)

        XCTAssertEqual(ctx.lineStart, 5)
        XCTAssertEqual(ctx.lineEnd, 5)
    }
}
