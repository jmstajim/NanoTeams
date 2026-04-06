import Foundation

struct ToolDefinitionRecord: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var prompt: String
    var parameters: JSONSchema
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        name: String,
        prompt: String,
        parameters: JSONSchema,
        isBuiltIn: Bool,
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now()
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.parameters = parameters
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ToolDefinitionRecord, rhs: ToolDefinitionRecord) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.prompt == rhs.prompt &&
        lhs.parameters == rhs.parameters &&
        lhs.isBuiltIn == rhs.isBuiltIn
    }
}

extension ToolDefinitionRecord {
    static func fromToolDefinition(_ tool: ToolSchema, isBuiltIn: Bool) -> ToolDefinitionRecord {
        ToolDefinitionRecord(
            id: tool.name,
            name: tool.name,
            prompt: tool.description,
            parameters: tool.parameters,
            isBuiltIn: isBuiltIn
        )
    }

    func toToolSchema() -> ToolSchema {
        ToolSchema(
            name: name,
            description: prompt,
            parameters: parameters
        )
    }

    static func defaultDefinitions() -> [ToolDefinitionRecord] {
        ToolHandlerRegistry
            .allSchemas
            .map { ToolDefinitionRecord.fromToolDefinition($0, isBuiltIn: true) }
    }

    static func mergeWithDefaults(existing: [ToolDefinitionRecord]) -> [ToolDefinitionRecord] {
        let defaults = defaultDefinitions()
        let defaultsByID = Dictionary(uniqueKeysWithValues: defaults.map { ($0.id, $0) })
        var ordered: [ToolDefinitionRecord] = []
        var seen = Set<String>()

        for tool in existing {
            guard !seen.contains(tool.id) else { continue }
            if let builtIn = defaultsByID[tool.id] {
                var normalized = builtIn
                normalized.isBuiltIn = true
                normalized.createdAt = tool.createdAt
                normalized.updatedAt = tool.updatedAt
                ordered.append(normalized)
            } else {
                ordered.append(tool)
            }
            seen.insert(tool.id)
        }

        for tool in defaults where !seen.contains(tool.id) {
            ordered.append(tool)
        }

        return ordered
    }
}
