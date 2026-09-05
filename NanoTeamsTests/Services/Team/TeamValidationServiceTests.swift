import XCTest
@testable import NanoTeams

/// The severity law of `TeamValidationService.ValidationError.isError` for every live case.
///
/// Until 2026-09-04 this file exercised the four artifact-chain validators (duplicate producer,
/// missing producer, circular dependency, orphan artifact) and the aggregators over them. None of that had a
/// production caller — the Team Editor banner never showed its output — so it was deleted with
/// the four cases only it could construct. What survives of the law this file pinned is the
/// error/warning split, which `TeamEditorValidation.issues` forwards to the banner row's icon
/// and tint (CLAUDE.md #104: re-aimed, not dropped).
final class TeamValidationServiceTests: XCTestCase {

    private typealias ValidationError = TeamValidationService.ValidationError

    // MARK: - ValidationError.isError

    /// Eligibility is the rule the run-time handler also refuses (`roleIsTopLevelDelegator` →
    /// `.delegationDenied`, `LLMExecutionService+DelegateToTeam`). Self-delegation has NO runtime
    /// mirror — the handler's whitelist guard passes an own-team id — so it is caught only here
    /// and by the role editor's team picker (`RoleEditorDelegationPolicy.delegatableTeams`
    /// excludes the own team). `isError` is the one place either is marked blocking, and what it
    /// drives is the banner's red tint and the top bar's count; the editor gates nothing on it.
    ///
    /// RED: move `.delegationToSelf` into the `return false` arm of `isError` → the second
    /// assertion fails.
    func testValidationError_isError_trueForBlockingDelegationCases() {
        XCTAssertTrue(ValidationError.nonTopLevelDelegator(roleID: "a").isError)
        XCTAssertTrue(ValidationError.delegationToSelf(roleID: "a", teamID: "t").isError)
    }

    /// A stale whitelist entry, an empty effective catalogue and a missing skill file are all
    /// recoverable without editing the role — the run proceeds — so they must not block.
    ///
    /// RED: move `.unknownDelegationTeam` into the `return true` arm of `isError` → the first
    /// assertion fails.
    func testValidationError_isError_falseForAdvisoryCases() {
        XCTAssertFalse(ValidationError.unknownDelegationTeam(roleID: "a", teamID: "t").isError,
                       "a deleted target team may come back — warn, do not block")
        XCTAssertFalse(ValidationError.noDelegationTargets(roleID: "a").isError)
        XCTAssertFalse(ValidationError.unknownAttachedSkill(roleID: "a", skillID: "s").isError,
                       "the run proceeds with the skill absent from the prompt — warn, do not block")
    }
}
