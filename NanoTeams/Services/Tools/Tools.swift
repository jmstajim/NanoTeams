import Foundation

/// `nonisolated` is load-bearing, not decoration: an extension in this target inherits the
/// project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` even when the TYPE it extends is
/// `nonisolated`, so the closures below (`ToolCallLogger(logURL:)` in an `Optional.map`) carried
/// a main-actor requirement checked DYNAMICALLY. Every production caller happened to be on the
/// main actor, so the check passed and nothing said this builder was pinned there — until a test
/// helper became `async` and built a registry off the main thread, which trapped inside
/// `Optional.map`. Nothing here touches UI.
nonisolated extension ToolRegistry {
    /// Builds a tool registry and runtime for the given work folder, backed by
    /// `ToolHandlerRegistry` as the single source of truth for schemas and handlers.
    static func defaultRegistry(
        workFolderRoot: URL,
        toolCallsLogURL: URL?,
        networkLogger: NetworkLogger? = nil,
        isDefaultStorage: Bool = false,
        searchExploratoryByDefault: Bool = false,
        readFileMaxLines: Int = AppDefaults.readFileMaxLines,
        searchMaxResults: Int = AppDefaults.searchMaxResults,
        searchContextBefore: Int = AppDefaults.searchContextBefore,
        searchContextAfter: Int = AppDefaults.searchContextAfter,
        mcpTools: MCPResolvedTools = .empty,
        mcpAttachmentsDir: URL? = nil,
        home: URL? = nil
    ) -> (registry: ToolRegistry, runtime: ToolRuntime) {
        let registry = ToolRegistry()
        let logger = toolCallsLogURL.map { ToolCallLogger(logURL: $0) }
        let runtime = ToolRuntime(registry: registry, logger: logger, networkLogger: networkLogger)

        // Register all live handlers (state captured at build time)
        let handlers = ToolHandlerRegistry.buildHandlers(
            workFolderRoot: workFolderRoot,
            isDefaultStorage: isDefaultStorage,
            searchExploratoryByDefault: searchExploratoryByDefault,
            readFileMaxLines: readFileMaxLines,
            searchMaxResults: searchMaxResults,
            searchContextBefore: searchContextBefore,
            searchContextAfter: searchContextAfter,
            home: home
        )
        for handler in handlers {
            let name = type(of: handler).name
            registry.register(name: name) { ctx, args in
                await handler.handle(context: ctx, args: args)
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

        // The SHIPPED half only, and it must be the same half the schema was built from:
        // registering a withheld tool would give the model a working handler for a name its
        // prompt never showed it, which is the gate running in only one of the two places it
        // has to run. The caller resolves the snapshot ONCE and passes the same value here
        // and to the schema resolver.
        //
        // No alias is registered for these: an alias is a spelling a model is known to
        // hallucinate for one of THIS app's tools, and an external server's folded name has
        // no such history. `mcp__` is also the one prefix `resolveToolName` must not strip.
        if let invoker = mcpTools.invoker {
            for entry in mcpTools.shipped {
                let tool = MCPDynamicTool(
                    entry: entry,
                    invoker: invoker,
                    attachmentsDirectory: mcpAttachmentsDir?
                        .appendingPathComponent(entry.slug.rawValue, isDirectory: true),
                    workFolderRoot: workFolderRoot)
                registry.register(name: tool.name, schema: tool.schema) { _, args in
                    await tool.handle(args: args)
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
