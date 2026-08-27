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
        bashSandboxEnabled: Bool = BashConstants.defaultSandboxEnabled,
        bashSandboxPermissions: BashSandboxPermissions = BashSandboxPermissions(),
        bashAllowUnsandboxedFallback: Bool = false
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
            bashSandboxEnabled: bashSandboxEnabled,
            bashSandboxPermissions: bashSandboxPermissions,
            bashAllowUnsandboxedFallback: bashAllowUnsandboxedFallback
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

        // Common LLM aliases
        for (alias, canonical) in ToolRegistry.defaultAliases {
            registry.registerAlias(alias, for: canonical)
        }

        return (registry: registry, runtime: runtime)
    }
}
