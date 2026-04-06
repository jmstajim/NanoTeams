import XCTest
@testable import NanoTeams

/// Tests for ToolDefinitionRegistry - tool definition lookup and management
final class ToolDefinitionRegistryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear registry state before each test
        ToolDefinitionRegistry.shared.update([])
    }

    override func tearDown() {
        // Clean up registry after each test
        ToolDefinitionRegistry.shared.update([])
        super.tearDown()
    }

    // MARK: - Helper

    func createTestRecord(id: String, name: String = "Test Tool", prompt: String = "Test prompt") -> ToolDefinitionRecord {
        ToolDefinitionRecord(
            id: id,
            name: name,
            prompt: prompt,
            parameters: JSONSchema(type: "object", properties: [:], required: []),
            isBuiltIn: false
        )
    }

    // MARK: - Update Tests

    func testUpdateWithDefinitions() {
        let records = [
            createTestRecord(id: "tool1"),
            createTestRecord(id: "tool2")
        ]
        ToolDefinitionRegistry.shared.update(records)

        XCTAssertNotNil(ToolDefinitionRegistry.shared.definition(for: "tool1"))
        XCTAssertNotNil(ToolDefinitionRegistry.shared.definition(for: "tool2"))
    }

    func testUpdateWithEmptyDefinitions() {
        ToolDefinitionRegistry.shared.update([])

        // When empty, allToolSchemas returns defaults
        let tools = ToolDefinitionRegistry.shared.allToolSchemas()
        XCTAssertFalse(tools.isEmpty)
    }

    func testUpdateDeduplicatesById() {
        let records = [
            createTestRecord(id: "test", name: "First"),
            createTestRecord(id: "test", name: "Second")
        ]
        ToolDefinitionRegistry.shared.update(records)

        let def = ToolDefinitionRegistry.shared.definition(for: "test")
        XCTAssertNotNil(def)
        XCTAssertEqual(def?.name, "First")
    }

    func testUpdatePreservesOrder() {
        let records = [
            createTestRecord(id: "z_tool", name: "z_tool"),
            createTestRecord(id: "a_tool", name: "a_tool"),
            createTestRecord(id: "m_tool", name: "m_tool")
        ]
        ToolDefinitionRegistry.shared.update(records)

        let tools = ToolDefinitionRegistry.shared.allToolSchemas()
        XCTAssertEqual(tools.count, 3)
        XCTAssertEqual(tools[0].name, "z_tool")
        XCTAssertEqual(tools[1].name, "a_tool")
        XCTAssertEqual(tools[2].name, "m_tool")
    }

    // MARK: - Definition Lookup Tests

    func testDefinitionForExistingTool() {
        ToolDefinitionRegistry.shared.update(ToolDefinitionRecord.defaultDefinitions())

        let def = ToolDefinitionRegistry.shared.definition(for: "read_file")

        XCTAssertNotNil(def)
        XCTAssertEqual(def?.id, "read_file")
    }

    func testDefinitionForNonexistentTool() {
        ToolDefinitionRegistry.shared.update(ToolDefinitionRecord.defaultDefinitions())

        let def = ToolDefinitionRegistry.shared.definition(for: "nonexistent_tool")

        XCTAssertNil(def)
    }

    func testDefinitionForCustomTool() {
        let custom = createTestRecord(id: "my_custom_tool", name: "My Custom Tool", prompt: "Does something custom")
        ToolDefinitionRegistry.shared.update([custom])

        let def = ToolDefinitionRegistry.shared.definition(for: "my_custom_tool")

        XCTAssertNotNil(def)
        XCTAssertEqual(def?.name, "My Custom Tool")
        XCTAssertEqual(def?.prompt, "Does something custom")
    }

    // MARK: - All Tool Definitions Tests

    func testAllToolDefinitionsWithRecords() {
        let records = [
            createTestRecord(id: "tool1"),
            createTestRecord(id: "tool2"),
            createTestRecord(id: "tool3")
        ]
        ToolDefinitionRegistry.shared.update(records)

        let tools = ToolDefinitionRegistry.shared.allToolSchemas()

        XCTAssertEqual(tools.count, 3)
    }

    func testAllToolDefinitionsReturnsDefaultsWhenEmpty() {
        ToolDefinitionRegistry.shared.update([])

        let tools = ToolDefinitionRegistry.shared.allToolSchemas()

        // Should return default tools
        XCTAssertFalse(tools.isEmpty)
        let names = tools.map { $0.name }
        XCTAssertTrue(names.contains("read_file"))
    }

    func testAllToolDefinitionsConvertsToToolDefinition() {
        let records = [
            createTestRecord(id: "test_tool", name: "test_tool", prompt: "Test description")
        ]
        ToolDefinitionRegistry.shared.update(records)

        let tools = ToolDefinitionRegistry.shared.allToolSchemas()

        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "test_tool")
        XCTAssertEqual(tools[0].description, "Test description")
    }

    // MARK: - Default Tools Tests

    func testDefaultToolsContainExpectedTools() {
        ToolDefinitionRegistry.shared.update(ToolDefinitionRecord.defaultDefinitions())

        let expectedTools = [
            "read_file", "write_file", "list_files", "search",
            "git_status", "git_add", "git_commit"
        ]

        for toolName in expectedTools {
            let def = ToolDefinitionRegistry.shared.definition(for: toolName)
            XCTAssertNotNil(def, "Expected tool \(toolName) to exist")
        }
    }

    func testDefaultToolsAreBuiltIn() {
        let defaults = ToolDefinitionRecord.defaultDefinitions()

        for record in defaults {
            XCTAssertTrue(record.isBuiltIn, "\(record.id) should be built-in")
        }
    }
}
