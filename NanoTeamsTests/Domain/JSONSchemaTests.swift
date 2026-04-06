@testable import NanoTeams
import XCTest

final class JSONSchemaTests: XCTestCase {

    private var encoder: JSONEncoder!
    private var decoder: JSONDecoder!

    override func setUp() {
        super.setUp()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    override func tearDown() {
        encoder = nil
        decoder = nil
        super.tearDown()
    }

    // MARK: - JSONSchemaLeaf Static Constructors

    func testLeafStringDefaults() {
        let leaf = JSONSchemaLeaf.string()
        XCTAssertEqual(leaf.type, "string")
        XCTAssertNil(leaf.description)
        XCTAssertNil(leaf.enumValues)
    }

    func testLeafStringWithDescription() {
        let leaf = JSONSchemaLeaf.string("A name field")
        XCTAssertEqual(leaf.type, "string")
        XCTAssertEqual(leaf.description, "A name field")
        XCTAssertNil(leaf.enumValues)
    }

    func testLeafStringWithEnumValues() {
        let leaf = JSONSchemaLeaf.string("Pick one", enumValues: ["alpha", "beta", "gamma"])
        XCTAssertEqual(leaf.type, "string")
        XCTAssertEqual(leaf.description, "Pick one")
        XCTAssertEqual(leaf.enumValues, ["alpha", "beta", "gamma"])
    }

    func testLeafIntegerDefaults() {
        let leaf = JSONSchemaLeaf.integer()
        XCTAssertEqual(leaf.type, "integer")
        XCTAssertNil(leaf.description)
        XCTAssertNil(leaf.enumValues)
    }

    func testLeafIntegerWithDescription() {
        let leaf = JSONSchemaLeaf.integer("The count")
        XCTAssertEqual(leaf.type, "integer")
        XCTAssertEqual(leaf.description, "The count")
    }

    func testLeafBooleanDefaults() {
        let leaf = JSONSchemaLeaf.boolean()
        XCTAssertEqual(leaf.type, "boolean")
        XCTAssertNil(leaf.description)
        XCTAssertNil(leaf.enumValues)
    }

    func testLeafBooleanWithDescription() {
        let leaf = JSONSchemaLeaf.boolean("Is active")
        XCTAssertEqual(leaf.type, "boolean")
        XCTAssertEqual(leaf.description, "Is active")
    }

    // MARK: - JSONSchemaLeaf Codable

    func testLeafCodableRoundTripString() throws {
        let leaf = JSONSchemaLeaf.string("Name of the user")
        let data = try encoder.encode(leaf)
        let decoded = try decoder.decode(JSONSchemaLeaf.self, from: data)
        XCTAssertEqual(decoded, leaf)
    }

    func testLeafCodableRoundTripWithEnumValues() throws {
        let leaf = JSONSchemaLeaf.string("Status", enumValues: ["open", "closed"])
        let data = try encoder.encode(leaf)
        let decoded = try decoder.decode(JSONSchemaLeaf.self, from: data)
        XCTAssertEqual(decoded, leaf)
    }

    func testLeafCodableRoundTripInteger() throws {
        let leaf = JSONSchemaLeaf.integer("Age")
        let data = try encoder.encode(leaf)
        let decoded = try decoder.decode(JSONSchemaLeaf.self, from: data)
        XCTAssertEqual(decoded, leaf)
    }

    func testLeafCodableRoundTripBoolean() throws {
        let leaf = JSONSchemaLeaf.boolean("Enabled flag")
        let data = try encoder.encode(leaf)
        let decoded = try decoder.decode(JSONSchemaLeaf.self, from: data)
        XCTAssertEqual(decoded, leaf)
    }

    func testLeafCodableRoundTripMinimal() throws {
        let leaf = JSONSchemaLeaf.string()
        let data = try encoder.encode(leaf)
        let decoded = try decoder.decode(JSONSchemaLeaf.self, from: data)
        XCTAssertEqual(decoded, leaf)
    }

    func testLeafEnumKeyEncodesAsEnum() throws {
        let leaf = JSONSchemaLeaf.string("Color", enumValues: ["red", "green"])
        let data = try encoder.encode(leaf)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // The key must be "enum", not "enumValues"
        XCTAssertNotNil(json["enum"])
        XCTAssertNil(json["enumValues"])
        let values = try XCTUnwrap(json["enum"] as? [String])
        XCTAssertEqual(values, ["red", "green"])
    }

    func testLeafDecodesFromEnumKey() throws {
        let jsonString = """
        {"type":"string","description":"Mode","enum":["fast","slow"]}
        """
        let data = Data(jsonString.utf8)
        let leaf = try decoder.decode(JSONSchemaLeaf.self, from: data)
        XCTAssertEqual(leaf.type, "string")
        XCTAssertEqual(leaf.description, "Mode")
        XCTAssertEqual(leaf.enumValues, ["fast", "slow"])
    }

    // MARK: - JSONSchemaLeaf Hashable

    func testLeafEqualValuesHashEqually() {
        let a = JSONSchemaLeaf.string("desc", enumValues: ["x"])
        let b = JSONSchemaLeaf.string("desc", enumValues: ["x"])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testLeafDifferentTypesAreNotEqual() {
        let a = JSONSchemaLeaf.string("desc")
        let b = JSONSchemaLeaf.integer("desc")
        XCTAssertNotEqual(a, b)
    }

    func testLeafDifferentDescriptionsAreNotEqual() {
        let a = JSONSchemaLeaf.string("one")
        let b = JSONSchemaLeaf.string("two")
        XCTAssertNotEqual(a, b)
    }

    func testLeafDifferentEnumValuesAreNotEqual() {
        let a = JSONSchemaLeaf.string(nil, enumValues: ["x"])
        let b = JSONSchemaLeaf.string(nil, enumValues: ["y"])
        XCTAssertNotEqual(a, b)
    }

    func testLeafNilVsNonNilEnumValuesAreNotEqual() {
        let a = JSONSchemaLeaf.string()
        let b = JSONSchemaLeaf.string(nil, enumValues: ["x"])
        XCTAssertNotEqual(a, b)
    }

    // MARK: - JSONSchemaProperty Codable

    func testPropertyCodableRoundTripPrimitive() throws {
        let prop = JSONSchemaProperty(
            type: "string",
            description: "A simple string",
            properties: nil,
            required: nil,
            items: nil,
            enumValues: nil
        )
        let data = try encoder.encode(prop)
        let decoded = try decoder.decode(JSONSchemaProperty.self, from: data)
        XCTAssertEqual(decoded, prop)
    }

    func testPropertyCodableRoundTripObjectWithLeaves() throws {
        let prop = JSONSchemaProperty(
            type: "object",
            description: "A user record",
            properties: [
                "name": .string("User name"),
                "age": .integer("User age"),
                "active": .boolean("Is active"),
            ],
            required: ["name"],
            items: nil,
            enumValues: nil
        )
        let data = try encoder.encode(prop)
        let decoded = try decoder.decode(JSONSchemaProperty.self, from: data)
        XCTAssertEqual(decoded, prop)
    }

    func testPropertyCodableRoundTripArrayWithItems() throws {
        let prop = JSONSchemaProperty(
            type: "array",
            description: "A list of tags",
            properties: nil,
            required: nil,
            items: .string("Tag name"),
            enumValues: nil
        )
        let data = try encoder.encode(prop)
        let decoded = try decoder.decode(JSONSchemaProperty.self, from: data)
        XCTAssertEqual(decoded, prop)
    }

    func testPropertyCodableRoundTripWithEnumValues() throws {
        let prop = JSONSchemaProperty(
            type: "string",
            description: "Priority level",
            properties: nil,
            required: nil,
            items: nil,
            enumValues: ["low", "medium", "high"]
        )
        let data = try encoder.encode(prop)
        let decoded = try decoder.decode(JSONSchemaProperty.self, from: data)
        XCTAssertEqual(decoded, prop)
    }

    func testPropertyEnumKeyEncodesAsEnum() throws {
        let prop = JSONSchemaProperty(
            type: "string",
            description: nil,
            properties: nil,
            required: nil,
            items: nil,
            enumValues: ["a", "b"]
        )
        let data = try encoder.encode(prop)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["enum"])
        XCTAssertNil(json["enumValues"])
    }

    func testPropertyDecodesFromEnumKey() throws {
        let jsonString = """
        {"type":"string","enum":["x","y","z"]}
        """
        let data = Data(jsonString.utf8)
        let prop = try decoder.decode(JSONSchemaProperty.self, from: data)
        XCTAssertEqual(prop.type, "string")
        XCTAssertEqual(prop.enumValues, ["x", "y", "z"])
    }

    // MARK: - JSONSchemaProperty Hashable

    func testPropertyEqualValuesHashEqually() {
        let a = JSONSchemaProperty(
            type: "string", description: "test", properties: nil,
            required: nil, items: nil, enumValues: nil
        )
        let b = JSONSchemaProperty(
            type: "string", description: "test", properties: nil,
            required: nil, items: nil, enumValues: nil
        )
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testPropertyDifferentTypesAreNotEqual() {
        let a = JSONSchemaProperty(
            type: "string", description: nil, properties: nil,
            required: nil, items: nil, enumValues: nil
        )
        let b = JSONSchemaProperty(
            type: "integer", description: nil, properties: nil,
            required: nil, items: nil, enumValues: nil
        )
        XCTAssertNotEqual(a, b)
    }

    func testPropertyWithDifferentNestedLeavesAreNotEqual() {
        let a = JSONSchemaProperty(
            type: "object", description: nil,
            properties: ["x": .string()],
            required: nil, items: nil, enumValues: nil
        )
        let b = JSONSchemaProperty(
            type: "object", description: nil,
            properties: ["x": .integer()],
            required: nil, items: nil, enumValues: nil
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - JSONSchema Convenience Constructors

    func testConvenienceStringDefaults() {
        let prop: JSONSchemaProperty = JSONSchema.string()
        XCTAssertEqual(prop.type, "string")
        XCTAssertNil(prop.description)
        XCTAssertNil(prop.properties)
        XCTAssertNil(prop.required)
        XCTAssertNil(prop.items)
        XCTAssertNil(prop.enumValues)
    }

    func testConvenienceStringWithDescription() {
        let prop: JSONSchemaProperty = JSONSchema.string("File path")
        XCTAssertEqual(prop.type, "string")
        XCTAssertEqual(prop.description, "File path")
    }

    func testConvenienceStringWithEnumValues() {
        let prop: JSONSchemaProperty = JSONSchema.string("Lang", enumValues: ["en", "fr"])
        XCTAssertEqual(prop.type, "string")
        XCTAssertEqual(prop.description, "Lang")
        XCTAssertEqual(prop.enumValues, ["en", "fr"])
    }

    func testConvenienceIntegerDefaults() {
        let prop: JSONSchemaProperty = JSONSchema.integer()
        XCTAssertEqual(prop.type, "integer")
        XCTAssertNil(prop.description)
        XCTAssertNil(prop.enumValues)
    }

    func testConvenienceIntegerWithDescription() {
        let prop: JSONSchemaProperty = JSONSchema.integer("Line number")
        XCTAssertEqual(prop.type, "integer")
        XCTAssertEqual(prop.description, "Line number")
    }

    func testConvenienceBooleanDefaults() {
        let prop: JSONSchemaProperty = JSONSchema.boolean()
        XCTAssertEqual(prop.type, "boolean")
        XCTAssertNil(prop.description)
        XCTAssertNil(prop.enumValues)
    }

    func testConvenienceBooleanWithDescription() {
        let prop: JSONSchemaProperty = JSONSchema.boolean("Recursive")
        XCTAssertEqual(prop.type, "boolean")
        XCTAssertEqual(prop.description, "Recursive")
    }

    func testConvenienceArrayReturnsArrayProperty() {
        let items: JSONSchemaProperty = JSONSchema.string("Tag")
        let prop: JSONSchemaProperty = JSONSchema.array(items: items, description: "Tags list")
        XCTAssertEqual(prop.type, "array")
        XCTAssertEqual(prop.description, "Tags list")
        XCTAssertNil(prop.properties)
        XCTAssertNil(prop.required)
        XCTAssertNil(prop.enumValues)

        // Items should be converted to a JSONSchemaLeaf
        let leafItems = try! XCTUnwrap(prop.items)
        XCTAssertEqual(leafItems.type, "string")
        XCTAssertEqual(leafItems.description, "Tag")
    }

    func testConvenienceArrayPreservesItemEnumValues() {
        let items: JSONSchemaProperty = JSONSchema.string("Prio", enumValues: ["low", "high"])
        let prop: JSONSchemaProperty = JSONSchema.array(items: items)
        let leafItems = try! XCTUnwrap(prop.items)
        XCTAssertEqual(leafItems.enumValues, ["low", "high"])
    }

    func testConvenienceArrayDefaultsDescriptionToNil() {
        let items: JSONSchemaProperty = JSONSchema.string()
        let prop: JSONSchemaProperty = JSONSchema.array(items: items)
        XCTAssertEqual(prop.type, "array")
        XCTAssertNil(prop.description)
    }

    func testConvenienceObjectWithSchemaPropertiesReturnsJSONSchema() {
        let schema: JSONSchema = JSONSchema.object(
            properties: [
                "name": JSONSchema.string("The name"),
                "count": JSONSchema.integer("How many"),
            ],
            required: ["name"],
            description: "A record"
        )
        XCTAssertEqual(schema.type, "object")
        XCTAssertEqual(schema.description, "A record")
        XCTAssertEqual(schema.required, ["name"])
        XCTAssertNil(schema.items)
        XCTAssertNil(schema.enumValues)

        let props = try! XCTUnwrap(schema.properties)
        XCTAssertEqual(props.count, 2)
        XCTAssertEqual(props["name"]?.type, "string")
        XCTAssertEqual(props["name"]?.description, "The name")
        XCTAssertEqual(props["count"]?.type, "integer")
        XCTAssertEqual(props["count"]?.description, "How many")
    }

    func testConvenienceObjectWithSchemaPropertiesDefaultRequiredEmpty() {
        let schema: JSONSchema = JSONSchema.object(properties: [:])
        XCTAssertEqual(schema.type, "object")
        XCTAssertEqual(schema.required, [])
        XCTAssertNil(schema.description)
    }

    func testConvenienceObjectWithLeafPropertiesReturnsSchemaProperty() {
        let prop: JSONSchemaProperty = JSONSchema.object(
            properties: [
                "label": .string("Label text"),
                "visible": .boolean("Is visible"),
            ],
            required: ["label"],
            description: "A widget"
        )
        XCTAssertEqual(prop.type, "object")
        XCTAssertEqual(prop.description, "A widget")
        XCTAssertEqual(prop.required, ["label"])
        XCTAssertNil(prop.items)
        XCTAssertNil(prop.enumValues)

        let leafProps = try! XCTUnwrap(prop.properties)
        XCTAssertEqual(leafProps.count, 2)
        XCTAssertEqual(leafProps["label"]?.type, "string")
        XCTAssertEqual(leafProps["visible"]?.type, "boolean")
    }

    func testConvenienceObjectWithLeafPropertiesDefaultRequiredEmpty() {
        let prop: JSONSchemaProperty = JSONSchema.object(properties: [String: JSONSchemaLeaf]())
        XCTAssertEqual(prop.type, "object")
        XCTAssertEqual(prop.required, [])
        XCTAssertNil(prop.description)
    }

    // MARK: - JSONSchema Codable

    func testSchemaCodableRoundTripSimpleObject() throws {
        let schema = JSONSchema.object(
            properties: [
                "path": JSONSchema.string("File path"),
                "recursive": JSONSchema.boolean("Search recursively"),
            ],
            required: ["path"],
            description: "Search parameters"
        )
        let data = try encoder.encode(schema)
        let decoded = try decoder.decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, schema)
    }

    func testSchemaCodableRoundTripWithArrayProperty() throws {
        let schema = JSONSchema.object(
            properties: [
                "tags": JSONSchema.array(
                    items: JSONSchema.string("Tag value"),
                    description: "List of tags"
                ),
            ],
            required: ["tags"]
        )
        let data = try encoder.encode(schema)
        let decoded = try decoder.decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, schema)
    }

    func testSchemaCodableRoundTripWithEnumProperty() throws {
        let schema = JSONSchema.object(
            properties: [
                "severity": JSONSchema.string("Level", enumValues: ["error", "warning", "info"]),
            ],
            required: ["severity"]
        )
        let data = try encoder.encode(schema)
        let decoded = try decoder.decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, schema)
    }

    func testSchemaCodableRoundTripComplex() throws {
        let schema = JSONSchema.object(
            properties: [
                "name": JSONSchema.string("Tool name"),
                "count": JSONSchema.integer("Invocation count"),
                "enabled": JSONSchema.boolean("Is enabled"),
                "mode": JSONSchema.string("Run mode", enumValues: ["fast", "safe"]),
                "items": JSONSchema.array(
                    items: JSONSchema.string("Item name"),
                    description: "List of items"
                ),
            ],
            required: ["name", "enabled"],
            description: "Tool configuration"
        )
        let data = try encoder.encode(schema)
        let decoded = try decoder.decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, schema)
    }

    func testSchemaEnumKeyEncodesAsEnum() throws {
        let schema = JSONSchema(
            type: "string",
            description: "A top-level enum schema",
            enumValues: ["one", "two"]
        )
        let data = try encoder.encode(schema)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["enum"])
        XCTAssertNil(json["enumValues"])
        let values = try XCTUnwrap(json["enum"] as? [String])
        XCTAssertEqual(values, ["one", "two"])
    }

    func testSchemaDecodesFromEnumKey() throws {
        let jsonString = """
        {"type":"string","enum":["a","b"],"description":"choices"}
        """
        let data = Data(jsonString.utf8)
        let schema = try decoder.decode(JSONSchema.self, from: data)
        XCTAssertEqual(schema.type, "string")
        XCTAssertEqual(schema.description, "choices")
        XCTAssertEqual(schema.enumValues, ["a", "b"])
    }

    func testSchemaDecodesComplexJSONWithNestedEnum() throws {
        let jsonString = """
        {
            "type": "object",
            "description": "A tool",
            "properties": {
                "action": {
                    "type": "string",
                    "description": "The action",
                    "enum": ["read", "write", "delete"]
                },
                "count": {
                    "type": "integer",
                    "description": "How many"
                }
            },
            "required": ["action"]
        }
        """
        let data = Data(jsonString.utf8)
        let schema = try decoder.decode(JSONSchema.self, from: data)

        XCTAssertEqual(schema.type, "object")
        XCTAssertEqual(schema.description, "A tool")
        XCTAssertEqual(schema.required, ["action"])

        let props = try XCTUnwrap(schema.properties)
        XCTAssertEqual(props["action"]?.type, "string")
        XCTAssertEqual(props["action"]?.enumValues, ["read", "write", "delete"])
        XCTAssertEqual(props["count"]?.type, "integer")
        XCTAssertNil(props["count"]?.enumValues)
    }

    func testSchemaCodableRoundTripMinimal() throws {
        let schema = JSONSchema(type: "object")
        let data = try encoder.encode(schema)
        let decoded = try decoder.decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, schema)
        XCTAssertNil(decoded.description)
        XCTAssertNil(decoded.properties)
        XCTAssertNil(decoded.required)
        XCTAssertNil(decoded.items)
        XCTAssertNil(decoded.enumValues)
    }

    func testSchemaCodableRoundTripWithItemsProperty() throws {
        let itemProp = JSONSchemaProperty(
            type: "string", description: "Element", properties: nil,
            required: nil, items: nil, enumValues: nil
        )
        let schema = JSONSchema(
            type: "array",
            description: "A top-level array schema",
            items: itemProp
        )
        let data = try encoder.encode(schema)
        let decoded = try decoder.decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, schema)
        XCTAssertEqual(decoded.items?.type, "string")
        XCTAssertEqual(decoded.items?.description, "Element")
    }

    // MARK: - JSONSchema Hashable

    func testSchemaEqualValuesHashEqually() {
        let a = JSONSchema.object(
            properties: ["x": JSONSchema.string("desc")],
            required: ["x"],
            description: "obj"
        )
        let b = JSONSchema.object(
            properties: ["x": JSONSchema.string("desc")],
            required: ["x"],
            description: "obj"
        )
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testSchemaDifferentPropertiesAreNotEqual() {
        let a = JSONSchema.object(
            properties: ["x": JSONSchema.string()],
            required: []
        )
        let b = JSONSchema.object(
            properties: ["y": JSONSchema.string()],
            required: []
        )
        XCTAssertNotEqual(a, b)
    }

    func testSchemaDifferentRequiredAreNotEqual() {
        let a = JSONSchema.object(
            properties: ["x": JSONSchema.string()],
            required: ["x"]
        )
        let b = JSONSchema.object(
            properties: ["x": JSONSchema.string()],
            required: []
        )
        XCTAssertNotEqual(a, b)
    }

    func testSchemaDifferentDescriptionsAreNotEqual() {
        let a = JSONSchema.object(
            properties: [String: JSONSchemaProperty](),
            description: "Alpha"
        )
        let b = JSONSchema.object(
            properties: [String: JSONSchemaProperty](),
            description: "Beta"
        )
        XCTAssertNotEqual(a, b)
    }

    func testSchemaDifferentTypesAreNotEqual() {
        let a = JSONSchema(type: "object")
        let b = JSONSchema(type: "array")
        XCTAssertNotEqual(a, b)
    }

    func testSchemaCanBeUsedInSet() {
        let schema1 = JSONSchema.object(properties: ["a": JSONSchema.string()])
        let schema2 = JSONSchema.object(properties: ["a": JSONSchema.string()])
        let schema3 = JSONSchema.object(properties: ["b": JSONSchema.integer()])

        let set: Set<JSONSchema> = [schema1, schema2, schema3]
        // schema1 and schema2 are equal, so the set should have 2 elements
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - Cross-Level Nesting Codable

    func testFullThreeLevelNestingRoundTrip() throws {
        // Build a schema with all 3 levels:
        // JSONSchema (level 0) -> JSONSchemaProperty (level 1) -> JSONSchemaLeaf (level 2)
        let nestedProp = JSONSchemaProperty(
            type: "object",
            description: "Inner object",
            properties: [
                "field1": .string("A string leaf"),
                "field2": .integer("An integer leaf"),
                "field3": .boolean("A boolean leaf"),
                "field4": .string("Enum leaf", enumValues: ["opt1", "opt2"]),
            ],
            required: ["field1", "field2"],
            items: nil,
            enumValues: nil
        )

        let schema = JSONSchema(
            type: "object",
            description: "Root schema",
            properties: [
                "nested": nestedProp,
                "flat": JSONSchemaProperty(
                    type: "string", description: "A flat prop", properties: nil,
                    required: nil, items: nil, enumValues: nil
                ),
            ],
            required: ["nested"]
        )

        let data = try encoder.encode(schema)
        let decoded = try decoder.decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, schema)

        // Verify nested structure survived
        let decodedNested = try XCTUnwrap(decoded.properties?["nested"])
        XCTAssertEqual(decodedNested.type, "object")
        XCTAssertEqual(decodedNested.required, ["field1", "field2"])

        let leaves = try XCTUnwrap(decodedNested.properties)
        XCTAssertEqual(leaves.count, 4)
        XCTAssertEqual(leaves["field1"]?.type, "string")
        XCTAssertEqual(leaves["field2"]?.type, "integer")
        XCTAssertEqual(leaves["field3"]?.type, "boolean")
        XCTAssertEqual(leaves["field4"]?.enumValues, ["opt1", "opt2"])
    }

    func testPropertyWithArrayOfLeavesRoundTrip() throws {
        let prop = JSONSchemaProperty(
            type: "array",
            description: "Tags array",
            properties: nil,
            required: nil,
            items: .string("A tag", enumValues: ["bug", "feature", "docs"]),
            enumValues: nil
        )

        let schema = JSONSchema(
            type: "object",
            description: "Wrapper",
            properties: ["tags": prop],
            required: ["tags"]
        )

        let data = try encoder.encode(schema)
        let decoded = try decoder.decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, schema)

        let decodedItems = try XCTUnwrap(decoded.properties?["tags"]?.items)
        XCTAssertEqual(decodedItems.type, "string")
        XCTAssertEqual(decodedItems.enumValues, ["bug", "feature", "docs"])
    }

    // MARK: - Edge Cases

    func testAllNilOptionalsEncodeAndDecode() throws {
        let leaf = JSONSchemaLeaf(type: "string", description: nil, enumValues: nil)
        let data = try encoder.encode(leaf)
        let decoded = try decoder.decode(JSONSchemaLeaf.self, from: data)
        XCTAssertEqual(decoded, leaf)
        XCTAssertNil(decoded.description)
        XCTAssertNil(decoded.enumValues)
    }

    func testEmptyPropertiesDictionaryRoundTrip() throws {
        let prop = JSONSchemaProperty(
            type: "object", description: nil, properties: [:],
            required: [], items: nil, enumValues: nil
        )
        let data = try encoder.encode(prop)
        let decoded = try decoder.decode(JSONSchemaProperty.self, from: data)
        XCTAssertEqual(decoded, prop)
        XCTAssertEqual(decoded.properties?.count, 0)
    }

    func testEmptyEnumArrayRoundTrip() throws {
        let leaf = JSONSchemaLeaf(type: "string", description: nil, enumValues: [])
        let data = try encoder.encode(leaf)
        let decoded = try decoder.decode(JSONSchemaLeaf.self, from: data)
        XCTAssertEqual(decoded, leaf)
        XCTAssertEqual(decoded.enumValues, [])
    }

    func testEmptyRequiredArrayRoundTrip() throws {
        let schema = JSONSchema.object(
            properties: ["x": JSONSchema.string()],
            required: []
        )
        let data = try encoder.encode(schema)
        let decoded = try decoder.decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded.required, [])
    }
}
