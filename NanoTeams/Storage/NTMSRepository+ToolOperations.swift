import Foundation

nonisolated extension NTMSRepository {

    func updateTools(at workFolderRoot: URL, tools: [ToolDefinitionRecord]) throws -> WorkFolderContext {
        let paths = try preparePaths(at: workFolderRoot)

        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: tools)
        try store.write(merged, to: paths.toolsJSON)

        return try assembleContext(paths: paths, toolDefinitions: merged)
    }
}
