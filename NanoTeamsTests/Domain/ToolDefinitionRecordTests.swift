import XCTest
@testable import NanoTeams

/// Tests for ToolDefinitionRecord - tool definition conversion and merging
final class ToolDefinitionRecordTests: XCTestCase {

    // Common LLM client objects
    var emptyJSONSchema: JSONSchema!
    var filePathJSONSchema: JSONSchema!
    var messageJSONSchema: JSONSchema!
    var defaultToolDefinitionRecord: [ToolDefinitionRecord]!

    // MARK: - Setup and Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        MonotonicClock.shared.reset()

        // Initialize common LLM client objects
        emptyJSONSchema = JSONSchema(type: "object", properties: [:], required: [])

        filePathJSONSchema = JSONSchema(
            type: "object",
            properties: ["path": JSONSchema.string("File path")],
            required: ["path"]
        )

        messageJSONSchema = JSONSchema(
            type: "object",
            properties: ["message": JSONSchema.string("Message to send")],
            required: ["message"]
        )

        defaultToolDefinitionRecord = ToolDefinitionRecord.defaultDefinitions()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
    }

    // MARK: - Helper

    func createRecord(
        id: String,
        name: String? = nil,
        prompt: String = "Test prompt",
        isBuiltIn: Bool = false
    ) -> ToolDefinitionRecord {
        ToolDefinitionRecord(
            id: id,
            name: name ?? id,
            prompt: prompt,
            parameters: emptyJSONSchema,
            isBuiltIn: isBuiltIn
        )
    }

    func createToolDefinition(name: String, description: String = "Test") -> ToolSchema {
        ToolSchema(
            name: name,
            description: description,
            parameters: emptyJSONSchema
        )
    }

    // MARK: - Initialization Tests

    func testToolDefinitionRecordInit() {
        let record = createRecord(id: "test_tool", name: "Test Tool", prompt: "A test tool")

        XCTAssertEqual(record.id, "test_tool")
        XCTAssertEqual(record.name, "Test Tool")
        XCTAssertEqual(record.prompt, "A test tool")
        XCTAssertFalse(record.isBuiltIn)
    }

    func testToolDefinitionRecordTimestamps() {
        let before = Date()
        let record = createRecord(id: "test")

        // MonotonicClock may return timestamps slightly ahead of system time
        XCTAssertGreaterThanOrEqual(record.createdAt, before)
        XCTAssertLessThan(record.createdAt.timeIntervalSince(before), 1.0)
        XCTAssertGreaterThanOrEqual(record.updatedAt, before)
        XCTAssertLessThan(record.updatedAt.timeIntervalSince(before), 1.0)
    }

    func testToolDefinitionRecordCustomTimestamps() {
        let customDate = Date(timeIntervalSince1970: 1000)
        let record = ToolDefinitionRecord(
            id: "test",
            name: "Test",
            prompt: "Test",
            parameters: emptyJSONSchema,
            isBuiltIn: false,
            createdAt: customDate,
            updatedAt: customDate
        )

        XCTAssertEqual(record.createdAt, customDate)
        XCTAssertEqual(record.updatedAt, customDate)
    }

    // MARK: - fromToolDefinition Tests

    func testFromToolDefinition() {
        let tool = createToolDefinition(name: "my_tool", description: "My tool description")
        let record = ToolDefinitionRecord.fromToolDefinition(tool, isBuiltIn: true)

        XCTAssertEqual(record.id, "my_tool")
        XCTAssertEqual(record.name, "my_tool")
        XCTAssertEqual(record.prompt, "My tool description")
        XCTAssertTrue(record.isBuiltIn)
    }

    func testFromToolDefinitionPreservesParameters() {
        let tool = ToolSchema(
            name: "read_file",
            description: "Reads a file",
            parameters: filePathJSONSchema
        )

        let record = ToolDefinitionRecord.fromToolDefinition(tool, isBuiltIn: true)

        XCTAssertEqual(record.parameters.type, "object")
        XCTAssertNotNil(record.parameters.properties?["path"])
        XCTAssertEqual(record.parameters.required, ["path"])
    }

    // MARK: - toToolSchema Tests

    func testToToolDefinition() {
        let record = createRecord(id: "test_tool", name: "test_tool", prompt: "Test description")
        let tool = record.toToolSchema()

        XCTAssertEqual(tool.name, "test_tool")
        XCTAssertEqual(tool.description, "Test description")
    }

    func testToToolDefinitionPreservesParameters() {
        let record = ToolDefinitionRecord(
            id: "send_message",
            name: "send_message",
            prompt: "Sends a message",
            parameters: messageJSONSchema,
            isBuiltIn: false
        )

        let tool = record.toToolSchema()

        XCTAssertEqual(tool.parameters.type, "object")
        XCTAssertNotNil(tool.parameters.properties?["message"])
    }

    // MARK: - Round-trip Tests

    func testRoundTripConversion() {
        let original = createToolDefinition(name: "round_trip", description: "Round trip test")
        let record = ToolDefinitionRecord.fromToolDefinition(original, isBuiltIn: true)
        let converted = record.toToolSchema()

        XCTAssertEqual(converted.name, original.name)
        XCTAssertEqual(converted.description, original.description)
    }

    // MARK: - defaultDefinitions Tests

    func testDefaultDefinitionsNotEmpty() {
        XCTAssertFalse(defaultToolDefinitionRecord.isEmpty)
    }

    func testDefaultDefinitionsAllBuiltIn() {
        for record in defaultToolDefinitionRecord {
            XCTAssertTrue(record.isBuiltIn, "\(record.id) should be built-in")
        }
    }

    func testDefaultDefinitionsContainExpectedTools() {
        let ids = Set(defaultToolDefinitionRecord.map { $0.id })

        XCTAssertTrue(ids.contains("read_file"))
        XCTAssertTrue(ids.contains("write_file"))
        XCTAssertTrue(ids.contains("list_files"))
    }

    func testDefaultDefinitionsHaveUniqueIds() {
        let ids = defaultToolDefinitionRecord.map { $0.id }
        let uniqueIds = Set(ids)

        XCTAssertEqual(ids.count, uniqueIds.count)
    }

    // MARK: - mergeWithDefaults Tests

    func testMergeWithDefaultsEmpty() {
        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: [])

        // Should return all defaults
        XCTAssertEqual(merged.count, defaultToolDefinitionRecord.count)
    }

    func testMergeWithDefaultsPreservesCustomTools() {
        let custom = createRecord(id: "my_custom_tool", prompt: "Custom tool")
        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: [custom])

        let customInMerged = merged.first { $0.id == "my_custom_tool" }
        XCTAssertNotNil(customInMerged)
        XCTAssertFalse(customInMerged?.isBuiltIn ?? true)
    }

    func testMergeWithDefaultsNormalizesBuiltInTools() {
        let modifiedBuiltIn = createRecord(id: "read_file", prompt: "Modified description", isBuiltIn: true)
        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: [modifiedBuiltIn])

        let readFile = merged.first { $0.id == "read_file" }
        XCTAssertNotNil(readFile)
        XCTAssertTrue(readFile?.isBuiltIn ?? false)
        // Should use default prompt, not modified one
        XCTAssertNotEqual(readFile?.prompt, "Modified description")
    }

    func testMergeWithDefaultsPreservesTimestamps() {
        let oldDate = Date(timeIntervalSince1970: 1000)
        let existing = ToolDefinitionRecord(
            id: "read_file",
            name: "read_file",
            prompt: "Custom",
            parameters: emptyJSONSchema,
            isBuiltIn: true,
            createdAt: oldDate,
            updatedAt: oldDate
        )

        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: [existing])

        let readFile = merged.first { $0.id == "read_file" }
        XCTAssertEqual(readFile?.createdAt, oldDate)
        XCTAssertEqual(readFile?.updatedAt, oldDate)
    }

    func testMergeWithDefaultsPreservesOrder() {
        let existing = [
            createRecord(id: "custom_first"),
            createRecord(id: "read_file", isBuiltIn: true)
        ]

        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: existing)

        XCTAssertEqual(merged[0].id, "custom_first")
        XCTAssertEqual(merged[1].id, "read_file")
    }

    func testMergeWithDefaultsRemovesDuplicates() {
        let existing = [
            createRecord(id: "read_file"),
            createRecord(id: "read_file")
        ]

        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: existing)

        let readFileCount = merged.filter { $0.id == "read_file" }.count
        XCTAssertEqual(readFileCount, 1)
    }

    func testMergeWithDefaultsAddsNewDefaults() {
        // Only provide some tools, rest should be added from defaults
        let existing = [
            createRecord(id: "read_file", isBuiltIn: true)
        ]

        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: existing)

        // Should have read_file plus all other defaults
        XCTAssertEqual(merged.count, defaultToolDefinitionRecord.count)
    }

    // MARK: - Identifiable/Hashable Tests

    func testToolDefinitionRecordIdentifiable() {
        let record = createRecord(id: "test")
        XCTAssertEqual(record.id, "test")
    }

    func testToolDefinitionRecordHashable() {
        let record1 = createRecord(id: "test")
        let record2 = createRecord(id: "test")

        var recordSet = Set<ToolDefinitionRecord>()
        recordSet.insert(record1)
        recordSet.insert(record2)

        // Same id means same hash - only one instance in set
        XCTAssertEqual(recordSet.count, 1)
    }

    func testToolDefinitionRecordEquality() {
        let record1 = createRecord(id: "test", name: "Test", prompt: "A")
        let record2 = createRecord(id: "test", name: "Test", prompt: "A")

        // Records with same ID are equal regardless of timestamps
        XCTAssertEqual(record1, record2)
    }

    // MARK: - Codable Tests

    var decoded: ToolDefinitionRecord!

    func testToolDefinitionRecordEncodeDecode() throws {
        let original = createRecord(id: "test_tool", name: "Test Tool", prompt: "Test description")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoded = try decoder.decode(ToolDefinitionRecord.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.prompt, original.prompt)
        XCTAssertEqual(decoded.isBuiltIn, original.isBuiltIn)
    }
}
