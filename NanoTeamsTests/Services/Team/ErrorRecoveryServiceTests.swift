import XCTest
@testable import NanoTeams

final class ErrorRecoveryServiceTests: XCTestCase {

    // MARK: - classifyError Tests

    func testClassifyError_Timeout_ReturnsTransient() {
        let messages = [
            "Request timeout",
            "Connection timeout occurred",
            "TIMEOUT error"
        ]

        for message in messages {
            let result = ErrorRecoveryService.classifyError(message)
            XCTAssertEqual(result, .transient, "Failed for: \(message)")
        }
    }

    func testClassifyError_Network_ReturnsTransient() {
        let messages = [
            "Network error",
            "Network unreachable",
            "Connection failed",
            "Server unreachable"
        ]

        for message in messages {
            let result = ErrorRecoveryService.classifyError(message)
            XCTAssertEqual(result, .transient, "Failed for: \(message)")
        }
    }

    func testClassifyError_BuildFailure_ReturnsBuildFailure() {
        let messages = [
            "Build failed with 3 errors",
            "Compilation error in main.swift",
            "xcodebuild returned exit code 65"
        ]

        for message in messages {
            let result = ErrorRecoveryService.classifyError(message)
            XCTAssertEqual(result, .buildFailure, "Failed for: \(message)")
        }
    }

    func testClassifyError_ToolError_ReturnsToolError() {
        let messages = [
            "Tool execution failed",
            "Command failed with error",
            "Execution error occurred"
        ]

        for message in messages {
            let result = ErrorRecoveryService.classifyError(message)
            XCTAssertEqual(result, .toolError, "Failed for: \(message)")
        }
    }

    func testClassifyError_LLMError_ReturnsLLMError() {
        let messages = [
            "LLM response parsing failed",
            "Model returned invalid response",
            "Failed to parse JSON response"
        ]

        for message in messages {
            let result = ErrorRecoveryService.classifyError(message)
            XCTAssertEqual(result, .llmError, "Failed for: \(message)")
        }
    }

    func testClassifyError_MissingDependency_ReturnsMissingDependency() {
        let messages = [
            "Missing dependency: requirements.md",
            "Artifact not found",
            "Required input not available"
        ]

        for message in messages {
            let result = ErrorRecoveryService.classifyError(message)
            XCTAssertEqual(result, .missingDependency, "Failed for: \(message)")
        }
    }

    func testClassifyError_Unknown_ReturnsUnknown() {
        let messages = [
            "Something went wrong",
            "Unexpected error occurred",
            "Internal error"
        ]

        for message in messages {
            let result = ErrorRecoveryService.classifyError(message)
            XCTAssertEqual(result, .unknown, "Failed for: \(message)")
        }
    }

    func testClassifyError_CaseInsensitive() {
        XCTAssertEqual(ErrorRecoveryService.classifyError("TIMEOUT"), .transient)
        XCTAssertEqual(ErrorRecoveryService.classifyError("Build Failed"), .buildFailure)
        XCTAssertEqual(ErrorRecoveryService.classifyError("NETWORK ERROR"), .transient)
    }

    // MARK: - RoleErrorType.suggestedStrategy Tests

    func testRoleErrorType_SuggestedStrategy() {
        XCTAssertEqual(RoleErrorType.transient.suggestedStrategy, .retry)
        XCTAssertEqual(RoleErrorType.llmError.suggestedStrategy, .retry)
        XCTAssertEqual(RoleErrorType.toolError.suggestedStrategy, .askSupervisor)
        XCTAssertEqual(RoleErrorType.buildFailure.suggestedStrategy, .askSupervisor)
        XCTAssertEqual(RoleErrorType.missingDependency.suggestedStrategy, .skip)
        XCTAssertEqual(RoleErrorType.unknown.suggestedStrategy, .askSupervisor)
    }

    func testRoleErrorType_IsTransient() {
        XCTAssertTrue(RoleErrorType.transient.isTransient)
        XCTAssertFalse(RoleErrorType.llmError.isTransient)
        XCTAssertFalse(RoleErrorType.toolError.isTransient)
        XCTAssertFalse(RoleErrorType.buildFailure.isTransient)
        XCTAssertFalse(RoleErrorType.missingDependency.isTransient)
        XCTAssertFalse(RoleErrorType.unknown.isTransient)
    }

    // MARK: - createError Tests

    func testCreateError_ClassifiesAutomatically() {
        let error = ErrorRecoveryService.createError(
            role: .softwareEngineer,
            errorMessage: "Network timeout occurred"
        )

        XCTAssertEqual(error.role, .softwareEngineer)
        XCTAssertEqual(error.errorMessage, "Network timeout occurred")
        XCTAssertEqual(error.errorType, .transient)
        XCTAssertEqual(error.strategy, .retry)
        XCTAssertEqual(error.retryCount, 0)
        XCTAssertEqual(error.maxRetries, 3)
    }

    func testCreateError_WithOverrideStrategy() {
        let error = ErrorRecoveryService.createError(
            role: .uxDesigner,
            errorMessage: "Network timeout occurred",
            overrideStrategy: .failTask
        )

        XCTAssertEqual(error.errorType, .transient)
        XCTAssertEqual(error.strategy, .failTask, "Override strategy should be used")
    }

    func testCreateError_UsesSuggestedStrategyWhenNoOverride() {
        let errorTransient = ErrorRecoveryService.createError(
            role: .sre,
            errorMessage: "Connection timeout"
        )
        XCTAssertEqual(errorTransient.strategy, .retry)

        let errorBuild = ErrorRecoveryService.createError(
            role: .softwareEngineer,
            errorMessage: "Build failed with 5 errors"
        )
        XCTAssertEqual(errorBuild.strategy, .askSupervisor)

        let errorDependency = ErrorRecoveryService.createError(
            role: .softwareEngineer,
            errorMessage: "Missing dependency: plan.md"
        )
        XCTAssertEqual(errorDependency.strategy, .skip)
    }

    // MARK: - RoleError.canRetry Tests

    func testRoleError_CanRetry_WithinLimit() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Test error",
            retryCount: 1,
            maxRetries: 3
        )

        XCTAssertTrue(error.canRetry)
    }

    func testRoleError_CanRetry_AtLimit() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Test error",
            retryCount: 3,
            maxRetries: 3
        )

        XCTAssertFalse(error.canRetry)
    }

    func testRoleError_CanRetry_OverLimit() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Test error",
            retryCount: 5,
            maxRetries: 3
        )

        XCTAssertFalse(error.canRetry)
    }

    // MARK: - retryDelay Tests

    func testRetryDelay_ExponentialBackoff() {
        let delay0 = ErrorRecoveryService.retryDelay(retryCount: 0)
        let delay1 = ErrorRecoveryService.retryDelay(retryCount: 1)
        let delay2 = ErrorRecoveryService.retryDelay(retryCount: 2)
        let delay3 = ErrorRecoveryService.retryDelay(retryCount: 3)

        XCTAssertEqual(delay0, 2.0)  // 2 * 2^0 = 2
        XCTAssertEqual(delay1, 4.0)  // 2 * 2^1 = 4
        XCTAssertEqual(delay2, 8.0)  // 2 * 2^2 = 8
        XCTAssertEqual(delay3, 16.0) // 2 * 2^3 = 16
    }

    func testRetryDelay_CapsAtMaxDelay() {
        let delayHigh = ErrorRecoveryService.retryDelay(retryCount: 10)

        XCTAssertEqual(delayHigh, 30.0, "Delay should cap at 30 seconds")
    }

    // MARK: - shouldRetry Tests

    func testShouldRetry_RetryStrategyAndCanRetry_ReturnsTrue() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Timeout",
            errorType: .transient,
            strategy: .retry,
            retryCount: 1,
            maxRetries: 3
        )

        XCTAssertTrue(ErrorRecoveryService.shouldRetry(error: error))
    }

    func testShouldRetry_RetryStrategyButExhausted_ReturnsFalse() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Timeout",
            errorType: .transient,
            strategy: .retry,
            retryCount: 3,
            maxRetries: 3
        )

        XCTAssertFalse(ErrorRecoveryService.shouldRetry(error: error))
    }

    func testShouldRetry_NonRetryStrategy_ReturnsFalse() {
        let strategies: [RoleErrorStrategy] = [.askSupervisor, .skip, .failTask]

        for strategy in strategies {
            let error = RoleError(
                role: .softwareEngineer,
                errorMessage: "Error",
                strategy: strategy,
                retryCount: 0,
                maxRetries: 3
            )

            XCTAssertFalse(ErrorRecoveryService.shouldRetry(error: error), "Failed for strategy: \(strategy)")
        }
    }

    // MARK: - recoveryOptions Tests

    func testRecoveryOptions_WithRetryAvailable_IncludesRetry() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Network error",
            errorType: .transient,
            retryCount: 1,
            maxRetries: 3
        )

        let options = ErrorRecoveryService.recoveryOptions(for: error)

        XCTAssertTrue(options.contains { $0.strategy == .retry })
        let retryOption = options.first { $0.strategy == .retry }!
        XCTAssertEqual(retryOption.title, "Retry")
        XCTAssertTrue(retryOption.description.contains("retry 2 of 3"))
        XCTAssertTrue(retryOption.isRecommended, "Retry should be recommended for transient errors")
    }

    func testRecoveryOptions_WithRetryExhausted_ExcludesRetry() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Network error",
            errorType: .transient,
            retryCount: 3,
            maxRetries: 3
        )

        let options = ErrorRecoveryService.recoveryOptions(for: error)

        XCTAssertFalse(options.contains { $0.strategy == .retry })
    }

    func testRecoveryOptions_AlwaysIncludesSkipAndFail() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Error"
        )

        let options = ErrorRecoveryService.recoveryOptions(for: error)

        XCTAssertTrue(options.contains { $0.strategy == .skip })
        XCTAssertTrue(options.contains { $0.strategy == .failTask })
    }

    func testRecoveryOptions_SkipIsRecommendedForMissingDependency() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Missing artifact",
            errorType: .missingDependency
        )

        let options = ErrorRecoveryService.recoveryOptions(for: error)
        let skipOption = options.first { $0.strategy == .skip }!

        XCTAssertTrue(skipOption.isRecommended)
    }

    func testRecoveryOptions_FailTaskNeverRecommended() {
        let errors = [
            RoleError(role: .softwareEngineer, errorMessage: "Error", errorType: .transient),
            RoleError(role: .softwareEngineer, errorMessage: "Error", errorType: .buildFailure),
            RoleError(role: .softwareEngineer, errorMessage: "Error", errorType: .unknown)
        ]

        for error in errors {
            let options = ErrorRecoveryService.recoveryOptions(for: error)
            let failOption = options.first { $0.strategy == .failTask }!

            XCTAssertFalse(failOption.isRecommended)
        }
    }

    // MARK: - RoleErrorStrategy Tests

    func testRoleErrorStrategy_DisplayName() {
        XCTAssertEqual(RoleErrorStrategy.retry.displayName, "Retry")
        XCTAssertEqual(RoleErrorStrategy.askSupervisor.displayName, "Ask Supervisor")
        XCTAssertEqual(RoleErrorStrategy.skip.displayName, "Skip Role")
        XCTAssertEqual(RoleErrorStrategy.failTask.displayName, "Fail Task")
    }

    func testRoleErrorStrategy_Description() {
        XCTAssertTrue(RoleErrorStrategy.retry.description.contains("retry"))
        XCTAssertTrue(RoleErrorStrategy.askSupervisor.description.contains("Supervisor"))
        XCTAssertTrue(RoleErrorStrategy.skip.description.contains("Skip"))
        XCTAssertTrue(RoleErrorStrategy.failTask.description.contains("failed"))
    }

    func testRoleErrorStrategy_Icon() {
        XCTAssertEqual(RoleErrorStrategy.retry.icon, "arrow.clockwise")
        XCTAssertEqual(RoleErrorStrategy.askSupervisor.icon, "person.fill.questionmark")
        XCTAssertEqual(RoleErrorStrategy.skip.icon, "forward.fill")
        XCTAssertEqual(RoleErrorStrategy.failTask.icon, "xmark.octagon")
    }

    // MARK: - ErrorHistory Tests

    func testErrorHistory_Record_UpdatesCounters() {
        var history = ErrorHistory()

        history.record(createError(), outcome: .retried)
        history.record(createError(), outcome: .retried)
        history.record(createError(), outcome: .skipped)
        history.record(createError(), outcome: .failed)
        history.record(createError(), outcome: .resolved)

        XCTAssertEqual(history.errors.count, 5)
        XCTAssertEqual(history.totalRetries, 2)
        XCTAssertEqual(history.totalSkipped, 1)
        XCTAssertEqual(history.totalFailed, 1)
    }

    func testErrorHistory_Summary_IncludesAllCounts() {
        var history = ErrorHistory()
        history.record(createError(), outcome: .retried)
        history.record(createError(), outcome: .skipped)
        history.record(createError(), outcome: .failed)

        let summary = history.summary

        XCTAssertTrue(summary.contains("Errors: 3"))
        XCTAssertTrue(summary.contains("Retries: 1"))
        XCTAssertTrue(summary.contains("Skipped: 1"))
        XCTAssertTrue(summary.contains("Failed: 1"))
    }

    // MARK: - Codable Tests

    func testRoleError_Codable_RoundTrip() throws {
        let original = RoleError(
            role: .softwareEngineer,
            errorMessage: "Test error",
            errorType: .buildFailure,
            strategy: .askSupervisor,
            retryCount: 2,
            maxRetries: 5
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RoleError.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.errorMessage, original.errorMessage)
        XCTAssertEqual(decoded.errorType, original.errorType)
        XCTAssertEqual(decoded.strategy, original.strategy)
        XCTAssertEqual(decoded.retryCount, original.retryCount)
        XCTAssertEqual(decoded.maxRetries, original.maxRetries)
    }

    func testErrorHistory_Codable_RoundTrip() throws {
        var original = ErrorHistory()
        original.record(createError(), outcome: .retried)
        original.record(createError(), outcome: .skipped)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ErrorHistory.self, from: encoded)

        XCTAssertEqual(decoded.errors.count, original.errors.count)
        XCTAssertEqual(decoded.totalRetries, original.totalRetries)
        XCTAssertEqual(decoded.totalSkipped, original.totalSkipped)
        XCTAssertEqual(decoded.totalFailed, original.totalFailed)
    }

    // MARK: - Helpers

    private func createError() -> RoleError {
        RoleError(
            role: .softwareEngineer,
            errorMessage: "Test error"
        )
    }
}
