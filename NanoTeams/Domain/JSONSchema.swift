import Foundation

// MARK: - JSONSchemaLeaf

/// Leaf schema — primitive types without nesting (level 2, deepest).
struct JSONSchemaLeaf: Codable, Hashable {
    let type: String
    let description: String?
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }

    static func string(_ description: String? = nil, enumValues: [String]? = nil) -> JSONSchemaLeaf {
        JSONSchemaLeaf(type: "string", description: description, enumValues: enumValues)
    }

    static func integer(_ description: String? = nil) -> JSONSchemaLeaf {
        JSONSchemaLeaf(type: "integer", description: description, enumValues: nil)
    }

    static func boolean(_ description: String? = nil) -> JSONSchemaLeaf {
        JSONSchemaLeaf(type: "boolean", description: description, enumValues: nil)
    }
}

// MARK: - JSONSchemaProperty

/// Property schema — can be primitive or object with leaf properties (level 1).
struct JSONSchemaProperty: Codable, Hashable {
    let type: String
    let description: String?
    let properties: [String: JSONSchemaLeaf]?
    let required: [String]?
    let items: JSONSchemaLeaf?
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required, items
        case enumValues = "enum"
    }
}

// MARK: - JSONSchema

/// Root schema — top-level object with property schemas (level 0, root).
struct JSONSchema: Codable, Hashable {
    let type: String
    let description: String?
    let properties: [String: JSONSchemaProperty]?
    let required: [String]?
    let items: JSONSchemaProperty?
    let enumValues: [String]?

    init(
        type: String,
        description: String? = nil,
        properties: [String: JSONSchemaProperty]? = nil,
        required: [String]? = nil,
        items: JSONSchemaProperty? = nil,
        enumValues: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.items = items
        self.enumValues = enumValues
    }

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required, items
        case enumValues = "enum"
    }

    // MARK: - Convenience Constructors

    static func string(_ description: String? = nil, enumValues: [String]? = nil)
        -> JSONSchemaProperty
    {
        JSONSchemaProperty(
            type: "string", description: description, properties: nil, required: nil,
            items: nil, enumValues: enumValues)
    }

    static func integer(_ description: String? = nil) -> JSONSchemaProperty {
        JSONSchemaProperty(
            type: "integer", description: description, properties: nil, required: nil,
            items: nil, enumValues: nil)
    }

    static func boolean(_ description: String? = nil) -> JSONSchemaProperty {
        JSONSchemaProperty(
            type: "boolean", description: description, properties: nil, required: nil,
            items: nil, enumValues: nil)
    }

    static func array(items: JSONSchemaProperty, description: String? = nil)
        -> JSONSchemaProperty
    {
        let leafItems = JSONSchemaLeaf(
            type: items.type, description: items.description, enumValues: items.enumValues)
        return JSONSchemaProperty(
            type: "array", description: description, properties: nil, required: nil,
            items: leafItems, enumValues: nil)
    }

    static func object(
        properties: [String: JSONSchemaProperty], required: [String] = [],
        description: String? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: "object", description: description, properties: properties,
            required: required, items: nil, enumValues: nil)
    }

    static func object(
        properties: [String: JSONSchemaLeaf], required: [String] = [],
        description: String? = nil
    ) -> JSONSchemaProperty {
        JSONSchemaProperty(
            type: "object", description: description, properties: properties,
            required: required, items: nil, enumValues: nil)
    }
}
