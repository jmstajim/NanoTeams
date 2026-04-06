import Foundation

extension ToolRegistry {
    /// Builds a tool registry and runtime for the given work folder, backed by
    /// `ToolHandlerRegistry` as the single source of truth for schemas and handlers.
    static func defaultRegistry(
        workFolderRoot: URL,
        toolCallsLogURL: URL?,
        isDefaultStorage: Bool = false
    ) -> (registry: ToolRegistry, runtime: ToolRuntime) {
        let registry = ToolRegistry()
        let logger = toolCallsLogURL.map { ToolCallLogger(logURL: $0) }
        let runtime = ToolRuntime(registry: registry, logger: logger)

        // Register all live handlers (state captured at build time)
        let handlers = ToolHandlerRegistry.buildHandlers(
            workFolderRoot: workFolderRoot,
            isDefaultStorage: isDefaultStorage
        )
        for handler in handlers {
            let name = type(of: handler).name
            registry.register(name: name) { ctx, args in
                handler.handle(context: ctx, args: args)
            }
        }

        // In default-storage mode, register error stubs for tools that require a real work folder
        if isDefaultStorage {
            let message = "No work folder is open. This tool requires a work folder to be opened first."
            for handlerType in ToolHandlerRegistry.allTypes where handlerType.blockedInDefaultStorage {
                let name = handlerType.name
                registry.register(name: name) { _, args in
                    makeErrorResult(
                        toolName: name, args: args,
                        code: .permissionDenied, message: message
                    )
                }
            }
        }

        // Common LLM aliases
        for (alias, canonical) in ToolRegistry.defaultAliases {
            registry.registerAlias(alias, for: canonical)
        }

        return (registry: registry, runtime: runtime)
    }
}
