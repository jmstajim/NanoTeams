import Foundation

// MARK: - JSONSchemaLeaf

/// Leaf schema — primitive types without nesting (level 2, deepest).
nonisolated struct JSONSchemaLeaf: Codable, Hashable {
    let type: String
    let description: String?
    let enumValues: [String]?
    let minimum: Int?
    let maximum: Int?

    init(
        type: String,
        description: String? = nil,
        enumValues: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.minimum = nil
        self.maximum = nil
    }

    init(
        type: String,
        description: String? = nil,
        enumValues: [String]? = nil,
        minimum: Int?,
        maximum: Int? = nil
    ) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.minimum = minimum
        self.maximum = maximum
    }

    enum CodingKeys: String, CodingKey {
        case type, description, minimum, maximum
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
nonisolated struct JSONSchemaProperty: Codable, Hashable {
    let type: String
    let description: String?
    let properties: [String: JSONSchemaLeaf]?
    let required: [String]?
    let items: JSONSchemaLeaf?
    let enumValues: [String]?
    let minimum: Int?
    let maximum: Int?

    init(
        type: String,
        description: String? = nil,
        properties: [String: JSONSchemaLeaf]? = nil,
        required: [String]? = nil,
        items: JSONSchemaLeaf? = nil,
        enumValues: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.items = items
        self.enumValues = enumValues
        self.minimum = nil
        self.maximum = nil
    }

    init(
        type: String,
        description: String? = nil,
        properties: [String: JSONSchemaLeaf]? = nil,
        required: [String]? = nil,
        items: JSONSchemaLeaf? = nil,
        enumValues: [String]? = nil,
        minimum: Int?,
        maximum: Int? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.items = items
        self.enumValues = enumValues
        self.minimum = minimum
        self.maximum = maximum
    }

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required, items, minimum, maximum
        case enumValues = "enum"
    }
}

// MARK: - JSONSchema

/// Root schema — top-level object with property schemas (level 0, root).
nonisolated struct JSONSchema: Codable, Hashable {
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

    /// The argument names this schema declares; empty when it has no `properties`. What every
    /// check of a call's keys against its schema reads — the in-app tools' vocabulary
    /// (`ToolArgumentVocabulary`) and the external agent's refusal (`HostedMCPCatalog`).
    var declaredArgumentNames: Set<String> {
        guard let properties else { return [] }
        return Set(properties.keys)
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

    static func integer(_ description: String? = nil, minimum: Int?, maximum: Int? = nil) -> JSONSchemaProperty {
        JSONSchemaProperty(
            type: "integer", description: description, properties: nil, required: nil,
            items: nil, enumValues: nil, minimum: minimum, maximum: maximum)
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
            type: items.type, description: items.description, enumValues: items.enumValues,
            minimum: items.minimum, maximum: items.maximum)
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

    /// An object parameter whose SHAPE lives in the tool description rather than in the
    /// schema — for a nested JSON document this model cannot express (an array of objects
    /// dies at `JSONSchemaLeaf`, CLAUDE.md #46).
    ///
    /// Declaring it `object` rather than `string` is the point: no provider is sent a real
    /// JSON Schema (neither `NativeChatRequest` nor Ollama's `ChatRequest` has a `tools`
    /// field — every schema reaches the model as prose), so the `(type)` the renderer
    /// prints is the ONLY thing telling the model whether to send a value or a transcript
    /// of one. Declared `string`, `ask_supervisor_form` asked a local model to escape a
    /// 1500-character JSON document by hand and got 2 clean emissions out of 6
    /// (MeditationApp tasks 71/74, 2026-09-12); the handler had accepted the object form
    /// all along.
    ///
    /// The sibling overload takes a `[String: JSONSchemaLeaf]` map and would write a dead
    /// `"properties": {}` into every work folder's `tools.json` for a shape it cannot hold.
    /// This one leaves `properties` nil, which the renderer prints as plain `(object)` —
    /// see `NativeLMStudioClient.typeAndAttributes`, which licenses the description as the
    /// documentation surface for exactly this case.
    static func object(_ description: String) -> JSONSchemaProperty {
        JSONSchemaProperty(
            type: "object", description: description, properties: nil,
            required: nil, items: nil, enumValues: nil)
    }
}
