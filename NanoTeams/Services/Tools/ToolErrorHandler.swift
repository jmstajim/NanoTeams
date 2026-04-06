import Foundation

/// Helper type for executing tool implementations with standardized error handling.
enum ToolErrorHandler {

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
        } catch {
            return makeErrorResult(
                toolName: toolName, args: args,
                code: .commandFailed, message: error.localizedDescription
            )
        }
    }
}
