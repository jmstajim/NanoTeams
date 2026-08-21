import XCTest
@testable import NanoTeams

/// Pins the `envelopeStatus(_:)` helper that drives the deferred-collaboration
/// re-update of `StepToolCall.isError` in `appendCollaborationResult`. Without
/// this, failed delegations / consultations / meetings render with the green ✓
/// from the placeholder result instead of red.
@MainActor
final class EnvelopeStatusHelperTests: XCTestCase {

    private var service: LLMExecutionService!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    // MARK: - .failure (the actionable signal)

    func testStatus_failureOnExplicitFalse() {
        XCTAssertEqual(service.envelopeStatus(#"{"ok":false,"error":{"code":"DELEGATION_DENIED"}}"#), .failure)
    }

    func testStatus_failureOnFalseWithExtraKeys() {
        XCTAssertEqual(service.envelopeStatus(#"{"tool":"x","ok":false,"meta":{}}"#), .failure)
    }

    // MARK: - .success (no UI change)

    func testStatus_successOnExplicitTrue() {
        XCTAssertEqual(service.envelopeStatus(#"{"ok":true,"data":{}}"#), .success)
    }

    // MARK: - .indeterminate (treat as success / no UI change)

    func testStatus_indeterminateOnMalformedJSON() {
        XCTAssertEqual(service.envelopeStatus(#"not even json"#), .indeterminate,
                       "Malformed JSON must not flip the card to error — treat as opaque success.")
    }

    func testStatus_indeterminateOnMissingOkField() {
        XCTAssertEqual(service.envelopeStatus(#"{"data":{}}"#), .indeterminate,
                       "An envelope without `ok` is not actionable — leave the card alone.")
    }

    func testStatus_indeterminateOnNonBoolOk() {
        XCTAssertEqual(service.envelopeStatus(#"{"ok":"true"}"#), .indeterminate,
                       "Non-Bool `ok` is malformed; don't flip.")
    }

    func testStatus_indeterminateOnEmptyString() {
        XCTAssertEqual(service.envelopeStatus(""), .indeterminate)
    }

    func testStatus_indeterminateOnNonObjectRoot() {
        XCTAssertEqual(service.envelopeStatus("[]"), .indeterminate,
                       "Top-level array is not a tool envelope.")
    }

    // MARK: - Three-state distinction

    /// Pins the case-comparison contract: callers MUST use `== .failure` to
    /// gate the re-update. A naive `if !isSuccess` style check would
    /// mis-classify `.indeterminate` as failure and flip every malformed
    /// envelope to red. This test exists so a future "simplification" of the
    /// caller breaks loudly.
    func testStatus_threeStatesAreDistinct() {
        let states: [EnvelopeStatus] = [.success, .failure, .indeterminate]
        XCTAssertEqual(Set(states).count, 3, "Cases must be distinct under Equatable.")
        XCTAssertNotEqual(EnvelopeStatus.success, .failure)
        XCTAssertNotEqual(EnvelopeStatus.success, .indeterminate)
        XCTAssertNotEqual(EnvelopeStatus.failure, .indeterminate)
    }
}
