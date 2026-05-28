import Foundation

/// Helper type for executing tool implementations with standardized error handling.
nonisolated enum ToolErrorHandler {

    /// Executes a tool implementation with standardized error handling.
    /// Catches common error types and converts them to appropriate error results.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool being executed
    ///   - args: The tool arguments dictionary
    ///   - implementation: The tool implementation closure that may throw
    /// - Returns: The tool result, either from successful execution or error handling
    static func execute(
        toolName: String,
        args: [String: Any],
        implementation: () throws -> ToolExecutionResult
    ) -> ToolExecutionResult {
        do {
            return try implementation()
        } catch let error as ToolArgumentError {
            return makeErrorResult(
                toolName: toolName, args: args,
                code: .invalidArgs, message: error.localizedDescription
            )
        } catch SandboxPathError.restrictedPath {
            return makeErrorResult(
                toolName: toolName, args: args,
                code: .fileNotFound, message: "File not found."
            )
        } catch let error as SandboxPathError {
            return makeErrorResult(
                toolName: toolName, args: args,
                code: .permissionDenied, message: error.localizedDescription
            )
        } catch ProcessRunnerError.cancelled {
            // SIGTERMed `xcodebuild` / `git`. Route through the unified cancel
            // envelope so MemoryTagStore and downstream classifiers see one
            // wire shape regardless of which layer cancelled.
            return makeCancelledResult(
                toolName: toolName,
                argumentsJSON: encodeArgsToJSON(args)
            )
        } catch {
            return makeErrorResult(
                toolName: toolName, args: args,
                code: .commandFailed, message: error.localizedDescription
            )
        }
    }
}
