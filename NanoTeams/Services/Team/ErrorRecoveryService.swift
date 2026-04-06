import Foundation

// MARK: - Error Recovery Service

/// Service for handling role execution errors with recovery strategies
struct ErrorRecoveryService {

    /// Determine the appropriate error type from an error description
    /// Ordered pattern map for error classification (first match wins).
    private static let errorPatterns: [(keywords: [String], type: RoleErrorType)] = [
        (["build failed", "compilation error", "xcodebuild"], .buildFailure),
        (["timeout", "network", "connection", "unreachable"], .transient),
        (["tool", "command failed", "execution error"], .toolError),
        (["llm", "model", "parse", "response"], .llmError),
        (["dependency", "artifact", "required"], .missingDependency),
    ]

    static func classifyError(_ errorMessage: String) -> RoleErrorType {
        let lowercased = errorMessage.lowercased()
        for pattern in errorPatterns {
            if pattern.keywords.contains(where: { lowercased.contains($0) }) {
                return pattern.type
            }
        }
        return .unknown
    }

    /// Create a role error with appropriate classification
    static func createError(
        role: Role,
        errorMessage: String,
        overrideStrategy: RoleErrorStrategy? = nil
    ) -> RoleError {
        let errorType = classifyError(errorMessage)
        let strategy = overrideStrategy ?? errorType.suggestedStrategy

        return RoleError(
            role: role,
            errorMessage: errorMessage,
            errorType: errorType,
            strategy: strategy
        )
    }

    /// Calculate retry delay using exponential backoff
    static func retryDelay(retryCount: Int) -> TimeInterval {
        let baseDelay: TimeInterval = 2.0
        let maxDelay: TimeInterval = 30.0
        let delay = baseDelay * pow(2.0, Double(retryCount))
        return min(delay, maxDelay)
    }

    /// Determine if a retry should be attempted
    static func shouldRetry(error: RoleError) -> Bool {
        error.strategy == .retry && error.canRetry
    }

}

// MARK: - Recovery Options

extension ErrorRecoveryService {

    /// Generate recovery options for an error
    static func recoveryOptions(for error: RoleError) -> [RecoveryOption] {
        var options: [RecoveryOption] = []

        if error.canRetry {
            options.append(RecoveryOption(
                strategy: .retry,
                title: "Retry",
                description: "Attempt again (retry \(error.retryCount + 1) of \(error.maxRetries))",
                isRecommended: error.errorType.isTransient
            ))
        }

        options.append(RecoveryOption(
            strategy: .skip,
            title: "Skip Role",
            description: "Skip \(error.role.displayName) and continue",
            isRecommended: error.errorType == .missingDependency
        ))

        options.append(RecoveryOption(
            strategy: .failTask,
            title: "Fail Task",
            description: "Stop execution and mark task as failed",
            isRecommended: false
        ))

        return options
    }

    /// Recovery option for UI display
    struct RecoveryOption: Identifiable {
        let id = UUID()
        let strategy: RoleErrorStrategy
        let title: String
        let description: String
        let isRecommended: Bool
    }
}
