import XCTest
@testable import NanoTeams

final class RoleErrorTests: XCTestCase {

    // MARK: - RoleError.canRetry

    func testCanRetry_belowMax_true() {
        let error = RoleError(role: .softwareEngineer, errorMessage: "timeout", retryCount: 1, maxRetries: 3)
        XCTAssertTrue(error.canRetry)
    }

    func testCanRetry_atMax_false() {
        let error = RoleError(role: .softwareEngineer, errorMessage: "timeout", retryCount: 3, maxRetries: 3)
        XCTAssertFalse(error.canRetry)
    }

    func testCanRetry_aboveMax_false() {
        let error = RoleError(role: .softwareEngineer, errorMessage: "timeout", retryCount: 5, maxRetries: 3)
        XCTAssertFalse(error.canRetry)
    }

    func testCanRetry_zeroRetries_true() {
        let error = RoleError(role: .softwareEngineer, errorMessage: "err", retryCount: 0, maxRetries: 3)
        XCTAssertTrue(error.canRetry)
    }

    // MARK: - RoleErrorType.isTransient

    func testIsTransient_transient_true() {
        XCTAssertTrue(RoleErrorType.transient.isTransient)
    }

    func testIsTransient_nonTransient_false() {
        let nonTransient: [RoleErrorType] = [.llmError, .toolError, .buildFailure, .missingDependency, .unknown]
        for errorType in nonTransient {
            XCTAssertFalse(errorType.isTransient, "\(errorType) should not be transient")
        }
    }

    // MARK: - RoleErrorType.suggestedStrategy

    func testSuggestedStrategy_transient_retry() {
        XCTAssertEqual(RoleErrorType.transient.suggestedStrategy, .retry)
    }

    func testSuggestedStrategy_llmError_retry() {
        XCTAssertEqual(RoleErrorType.llmError.suggestedStrategy, .retry)
    }

    func testSuggestedStrategy_toolError_askSupervisor() {
        XCTAssertEqual(RoleErrorType.toolError.suggestedStrategy, .askSupervisor)
    }

    func testSuggestedStrategy_buildFailure_askSupervisor() {
        XCTAssertEqual(RoleErrorType.buildFailure.suggestedStrategy, .askSupervisor)
    }

    func testSuggestedStrategy_missingDependency_skip() {
        XCTAssertEqual(RoleErrorType.missingDependency.suggestedStrategy, .skip)
    }

    func testSuggestedStrategy_unknown_askSupervisor() {
        XCTAssertEqual(RoleErrorType.unknown.suggestedStrategy, .askSupervisor)
    }

    // MARK: - RoleErrorStrategy metadata

    func testStrategy_allCases_haveDisplayName() {
        for strategy in RoleErrorStrategy.allCases {
            XCTAssertFalse(strategy.displayName.isEmpty, "\(strategy) should have displayName")
        }
    }

    func testStrategy_allCases_haveDescription() {
        for strategy in RoleErrorStrategy.allCases {
            XCTAssertFalse(strategy.description.isEmpty, "\(strategy) should have description")
        }
    }

    func testStrategy_allCases_haveIcon() {
        for strategy in RoleErrorStrategy.allCases {
            XCTAssertFalse(strategy.icon.isEmpty, "\(strategy) should have icon")
        }
    }

    func testStrategy_specificValues() {
        XCTAssertEqual(RoleErrorStrategy.retry.displayName, "Retry")
        XCTAssertEqual(RoleErrorStrategy.askSupervisor.displayName, "Ask Supervisor")
        XCTAssertEqual(RoleErrorStrategy.skip.displayName, "Skip Role")
        XCTAssertEqual(RoleErrorStrategy.failTask.displayName, "Fail Task")
    }

    // MARK: - ChangeRequestStatus.displayName

    func testChangeRequestStatus_allCases_haveDisplayName() {
        let allStatuses: [ChangeRequestStatus] = [
            .pending, .approved, .rejected, .escalated,
            .supervisorApproved, .supervisorRejected, .failed
        ]
        for status in allStatuses {
            XCTAssertFalse(status.displayName.isEmpty, "\(status) should have displayName")
        }
    }

    func testChangeRequestStatus_specificValues() {
        XCTAssertEqual(ChangeRequestStatus.pending.displayName, "Pending")
        XCTAssertEqual(ChangeRequestStatus.supervisorApproved.displayName, "Supervisor Approved")
        XCTAssertEqual(ChangeRequestStatus.failed.displayName, "Failed")
    }

    // MARK: - ErrorHistory

    func testErrorHistory_initialValues() {
        let history = ErrorHistory()
        XCTAssertTrue(history.errors.isEmpty)
        XCTAssertEqual(history.totalRetries, 0)
        XCTAssertEqual(history.totalSkipped, 0)
        XCTAssertEqual(history.totalFailed, 0)
    }

    func testErrorHistory_record_retried() {
        var history = ErrorHistory()
        let error = RoleError(role: .softwareEngineer, errorMessage: "timeout")
        history.record(error, outcome: .retried)
        XCTAssertEqual(history.errors.count, 1)
        XCTAssertEqual(history.totalRetries, 1)
        XCTAssertEqual(history.totalSkipped, 0)
        XCTAssertEqual(history.totalFailed, 0)
    }

    func testErrorHistory_record_skipped() {
        var history = ErrorHistory()
        let error = RoleError(role: .softwareEngineer, errorMessage: "missing dep")
        history.record(error, outcome: .skipped)
        XCTAssertEqual(history.totalSkipped, 1)
        XCTAssertEqual(history.totalRetries, 0)
    }

    func testErrorHistory_record_failed() {
        var history = ErrorHistory()
        let error = RoleError(role: .softwareEngineer, errorMessage: "fatal")
        history.record(error, outcome: .failed)
        XCTAssertEqual(history.totalFailed, 1)
        XCTAssertEqual(history.totalRetries, 0)
    }

    func testErrorHistory_record_resolved_noCounterChange() {
        var history = ErrorHistory()
        let error = RoleError(role: .softwareEngineer, errorMessage: "fixed")
        history.record(error, outcome: .resolved)
        XCTAssertEqual(history.errors.count, 1)
        XCTAssertEqual(history.totalRetries, 0)
        XCTAssertEqual(history.totalSkipped, 0)
        XCTAssertEqual(history.totalFailed, 0)
    }

    func testErrorHistory_record_multipleOutcomes() {
        var history = ErrorHistory()
        let e1 = RoleError(role: .softwareEngineer, errorMessage: "a")
        let e2 = RoleError(role: .productManager, errorMessage: "b")
        let e3 = RoleError(role: .techLead, errorMessage: "c")
        history.record(e1, outcome: .retried)
        history.record(e2, outcome: .retried)
        history.record(e3, outcome: .failed)
        XCTAssertEqual(history.errors.count, 3)
        XCTAssertEqual(history.totalRetries, 2)
        XCTAssertEqual(history.totalFailed, 1)
    }

    func testErrorHistory_summary_format() {
        var history = ErrorHistory()
        let error = RoleError(role: .softwareEngineer, errorMessage: "err")
        history.record(error, outcome: .retried)
        history.record(error, outcome: .skipped)
        let summary = history.summary
        XCTAssertEqual(summary, "Errors: 2, Retries: 1, Skipped: 1, Failed: 0")
    }
}
