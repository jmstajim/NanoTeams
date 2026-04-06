import XCTest

@testable import NanoTeams

/// Integration tests for error recovery: classification → strategy → recovery options.
/// Validates ErrorRecoveryService classifies errors correctly and suggests appropriate strategies.
@MainActor
final class EndToEndErrorRecoveryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: Transient error → retry strategy with backoff

    func testTransientError_classifiesAndSuggestsRetry() {
        let error = ErrorRecoveryService.createError(
            role: .softwareEngineer,
            errorMessage: "Connection timeout: server unreachable"
        )

        XCTAssertEqual(error.errorType, .transient, "Timeout should classify as transient")
        XCTAssertEqual(error.strategy, .retry, "Transient error should suggest retry")
        XCTAssertTrue(ErrorRecoveryService.shouldRetry(error: error))

        // Verify exponential backoff
        let delay0 = ErrorRecoveryService.retryDelay(retryCount: 0)
        let delay1 = ErrorRecoveryService.retryDelay(retryCount: 1)
        let delay2 = ErrorRecoveryService.retryDelay(retryCount: 2)

        XCTAssertEqual(delay0, 2.0, "First retry should be 2s")
        XCTAssertEqual(delay1, 4.0, "Second retry should be 4s")
        XCTAssertEqual(delay2, 8.0, "Third retry should be 8s")

        // Max delay cap
        let delayMax = ErrorRecoveryService.retryDelay(retryCount: 10)
        XCTAssertLessThanOrEqual(delayMax, 30.0, "Delay should be capped at 30s")
    }

    // MARK: - Test 2: Build failure → escalate

    func testBuildFailure_classifiesAsBuildFailure() {
        let error = ErrorRecoveryService.createError(
            role: .softwareEngineer,
            errorMessage: "xcodebuild: Build failed with 3 errors"
        )

        XCTAssertEqual(error.errorType, .buildFailure, "Xcodebuild error should classify as buildFailure")

        // Recovery options should include retry, skip, and fail
        let options = ErrorRecoveryService.recoveryOptions(for: error)
        let strategies = options.map(\.strategy)

        XCTAssertTrue(strategies.contains(.retry), "Should offer retry")
        XCTAssertTrue(strategies.contains(.skip), "Should offer skip")
        XCTAssertTrue(strategies.contains(.failTask), "Should offer failTask")
    }

    // MARK: - Test 3: Error history tracks across retries

    func testErrorHistory_classificationCoverage() {
        // Test all error types are classifiable
        let testCases: [(String, RoleErrorType)] = [
            ("Build failed with compilation error", .buildFailure),
            ("Network timeout connecting to API", .transient),
            ("Tool command failed: permission denied", .toolError),
            ("LLM response parse error", .llmError),
            ("Missing dependency: artifact not found", .missingDependency),
            ("Something completely unknown happened", .unknown),
        ]

        for (message, expectedType) in testCases {
            let classified = ErrorRecoveryService.classifyError(message)
            XCTAssertEqual(classified, expectedType,
                           "'\(message)' should classify as \(expectedType)")
        }
    }

    // MARK: - Test 4: Recovery options — recommended varies by type

    func testRecoveryOptions_recommendedVariesByType() {
        // Transient: retry is recommended
        let transientError = ErrorRecoveryService.createError(
            role: .softwareEngineer,
            errorMessage: "Connection timeout"
        )
        let transientOptions = ErrorRecoveryService.recoveryOptions(for: transientError)
        let transientRecommended = transientOptions.first(where: \.isRecommended)
        XCTAssertEqual(transientRecommended?.strategy, .retry,
                       "Retry should be recommended for transient errors")

        // Missing dependency: skip is recommended
        let depError = ErrorRecoveryService.createError(
            role: .softwareEngineer,
            errorMessage: "Missing dependency: artifact not produced"
        )
        let depOptions = ErrorRecoveryService.recoveryOptions(for: depError)
        let depRecommended = depOptions.first(where: \.isRecommended)
        XCTAssertEqual(depRecommended?.strategy, .skip,
                       "Skip should be recommended for missing dependency")
    }

    // MARK: - Test 5: Override strategy takes precedence

    func testOverrideStrategy_takesPrecedence() {
        let error = ErrorRecoveryService.createError(
            role: .softwareEngineer,
            errorMessage: "Connection timeout",
            overrideStrategy: .failTask
        )

        XCTAssertEqual(error.errorType, .transient, "Type should still be classified correctly")
        XCTAssertEqual(error.strategy, .failTask, "Override strategy should take precedence")
    }
}
