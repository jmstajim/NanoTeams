import XCTest

@testable import NanoTeams

/// What a person reads when a review action is refused rather than written. Each refusal says
/// what moved and what to do instead, in its own words — the sheet and the server page show it
/// through `MCPToolReviewChrome.failureMessage(for:)`, and anything that reads an error the
/// Foundation way (`localizedDescription`) gets the same sentence.
final class MCPReviewErrorTests: XCTestCase {

    private let every: [MCPReviewError] = [
        .changedWhileReviewing, .listChangedWhileReviewing, .withdrawn, .alreadyApproved,
        .standingGrantsNotAllowed, .connectionStopped,
    ]

    func testEachRefusalSaysWhatMovedAndWhatToDo() {
        XCTAssertEqual(
            MCPReviewError.changedWhileReviewing.message,
            "The tool changed while you were reading. Review it again.")
        XCTAssertEqual(
            MCPReviewError.listChangedWhileReviewing.message,
            "A tool in that list changed since the list was shown, so nothing was approved. Open the list again.")
        XCTAssertEqual(
            MCPReviewError.withdrawn.message,
            "The server no longer offers this tool, so there is nothing to decide.")
        XCTAssertEqual(
            MCPReviewError.alreadyApproved.message,
            "This text is already approved. Revoke the approval instead.")
        XCTAssertEqual(
            MCPReviewError.standingGrantsNotAllowed.message,
            "This server asks about every call — its approval mode is Manual — so nothing was recorded. "
                + "Make it Semi-automatic or Auto to let a tool run without asking.")
        XCTAssertEqual(
            MCPReviewError.connectionStopped.message,
            "The server's connection was stopped a moment ago, so nothing was recorded. "
                + "Try again once it has reconnected.")
    }

    /// The banner shows the refusal's own sentence — never the disk-failure one — and a caller
    /// that reads the error the Foundation way sees the same sentence.
    func testEveryRefusalReachesTheBannerInItsOwnWords() {
        for refusal in every {
            XCTAssertEqual(MCPToolReviewChrome.failureMessage(for: refusal), refusal.message, "\(refusal)")
            XCTAssertEqual(refusal.errorDescription, refusal.message, "\(refusal)")
            XCTAssertEqual((refusal as any Error).localizedDescription, refusal.message, "\(refusal)")
        }
        XCTAssertEqual(Set(every.map(\.message)).count, every.count, "no two refusals read alike")
    }
}
