import Foundation

final class ToolDefinitionRegistry {
    static let shared = ToolDefinitionRegistry()

    private var definitionsByID: [String: ToolDefinitionRecord] = [:]
    private var orderedIDs: [String] = []

    private init() {}

    func update(_ definitions: [ToolDefinitionRecord]) {
        var ids: [String] = []
        var map: [String: ToolDefinitionRecord] = [:]
        for definition in definitions {
            if map[definition.id] == nil {
                ids.append(definition.id)
                map[definition.id] = definition
            }
        }
        orderedIDs = ids
        definitionsByID = map
    }

    func definition(for name: String) -> ToolDefinitionRecord? {
        definitionsByID[name]
    }

    func allToolSchemas() -> [ToolSchema] {
        if orderedIDs.isEmpty {
            return ToolHandlerRegistry.allSchemas
        }
        return orderedIDs.compactMap { id in
            definitionsByID[id]?.toToolSchema()
        }
    }
}
