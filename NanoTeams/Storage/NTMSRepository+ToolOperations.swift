import Foundation

extension NTMSRepository {

    func updateTools(at workFolderRoot: URL, tools: [ToolDefinitionRecord]) throws -> WorkFolderContext {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        try ensureLayout(paths: paths)
        try bootstrapIfNeeded(paths: paths, workFolderRoot: workFolderRoot)

        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: tools)
        try store.write(merged, to: paths.toolsJSON)

        return try assembleContext(paths: paths, toolDefinitions: merged)
    }
}
