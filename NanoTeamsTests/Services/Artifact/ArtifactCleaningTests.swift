import XCTest
@testable import NanoTeams // periphery:ignore

final class ArtifactCleaningTests: XCTestCase {

    func testControlTokensAreStrippedFromArtifacts() throws {
        // Simulate content with control tokens as seen in the report
        let input = """
            **Requirements - Supervisor (Step 1 of 7)**

            | # | Requirement | Rationale |
            |---|-------------|-----------|
            | 1 | Change greeting | Supervisor task |

            <|channel|>final <|constrain|>requirements<|message|>These requirements capture the goal.
            """

        let cleaned = Self.cleanArtifactContent(input)

        XCTAssertFalse(cleaned.contains("<|channel|>"))
        XCTAssertFalse(cleaned.contains("<|constrain|>"))
        XCTAssertFalse(cleaned.contains("<|message|>"))
        XCTAssertTrue(cleaned.contains("Requirements - Supervisor"))
        XCTAssertTrue(cleaned.contains("Change greeting"))
        XCTAssertTrue(cleaned.contains("These requirements capture the goal"))
    }

    func testIncompleteStartMarkersAreStripped() throws {
        let input = """
            Some content here.
            <|start|>functions.G
            More content after.
            """

        let cleaned = Self.cleanArtifactContent(input)

        XCTAssertFalse(cleaned.contains("<|start|>functions."))
        XCTAssertTrue(cleaned.contains("Some content here"))
        XCTAssertTrue(cleaned.contains("More content after"))
    }

    func testCallAndEndMarkersAreStripped() throws {
        let input = """
            Response content
            <|call|>{"name":"tool"}<|end|>
            """

        let cleaned = Self.cleanArtifactContent(input)

        XCTAssertFalse(cleaned.contains("<|call|>"))
        XCTAssertFalse(cleaned.contains("<|end|>"))
        XCTAssertTrue(cleaned.contains("Response content"))
    }

    func testNormalContentIsPreserved() throws {
        let input = """
            # Requirements Document

            This is a normal markdown document with:
            - Bullet points
            - Code blocks: `print("Hello")`
            - Tables and formatting

            No special tokens here.
            """

        let cleaned = Self.cleanArtifactContent(input)

        XCTAssertEqual(cleaned, input.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testChannelCommentaryIsStripped() throws {
        let input = "Some text<|channel|>commentary more text"
        let cleaned = Self.cleanArtifactContent(input)

        XCTAssertFalse(cleaned.contains("<|channel|>"))
        XCTAssertFalse(cleaned.contains("commentary"))
        XCTAssertTrue(cleaned.contains("Some text"))
        XCTAssertTrue(cleaned.contains("more text"))
    }

    // MARK: - Private helper (mirrors NTMSRepository.cleanArtifactContent)

    private static func cleanArtifactContent(_ content: String) -> String {
        var result = content
        let patterns = [
            #"<\|channel\|>\s*\w*\s*"#,
            #"<\|constrain\|>\s*\w*\s*"#,
            #"<\|message\|>"#,
            #"<\|start\|>functions\.[a-zA-Z_]*"#,
            #"<\|end\|>"#,
            #"<\|call\|>"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
