import XCTest
@testable import NanoTeams

/// Pins the user-facing copy of `BundledUpdateReport`.
///
/// The whole point of this type is that the old message — "Bundled updates
/// deferred for 2 teams — will retry on next open." — named nothing the user
/// could act on. So the assertions here are about CONTENT (the team, the role,
/// the task, the file) and about fitting the banner, not about exact wording.
///
/// `ErrorBannerView` renders at `lineLimit(2)` and auto-dismisses after 4s with
/// no expand and no copy affordance, so anything longer is silently truncated
/// and unrecoverable.
final class BundledUpdateReportCopyTests: XCTestCase {

    /// Two lines of the banner's font comfortably fit ~120 characters.
    private static let bannerCharacterBudget = 130

    private func team(
        name: String,
        roles: [String] = ["Software Engineer"],
        taskID: Int = 12,
        taskTitle: String = "Fix login",
        otherTasks: Int = 0
    ) -> BundledUpdateReport.DeferredTeam {
        .init(
            teamID: NTMSID.from(name: name),
            teamName: name,
            roleNames: roles,
            taskID: taskID,
            taskTitle: taskTitle,
            otherBlockingTaskCount: otherTasks
        )
    }

    private func assertFitsBanner(_ message: String, _ label: String) {
        XCTAssertLessThanOrEqual(
            message.count, Self.bannerCharacterBudget,
            "\(label) is \(message.count) chars — the banner truncates at two lines: \(message)"
        )
    }

    // MARK: - Nothing to say

    func testFullyApplied_hasNoBanner() {
        let report = BundledUpdateReport()
        XCTAssertTrue(report.isFullyApplied)
        XCTAssertNil(report.bannerMessage)
        XCTAssertNil(report.durableMessage)
        XCTAssertFalse(report.bannerIsError)
    }

    // MARK: - Deferral (informational, transient)

    func testSingleTeam_namesTeamRoleAndTask() throws {
        let report = BundledUpdateReport(deferred: [team(name: "FAANG Team")])
        let message = try XCTUnwrap(report.bannerMessage)

        XCTAssertTrue(message.contains("FAANG Team"), message)
        XCTAssertTrue(message.contains("Software Engineer"), message)
        XCTAssertTrue(message.contains("#12"), message)
        XCTAssertFalse(report.bannerIsError, "a deferral is not an error")
        assertFitsBanner(message, "single-team deferral")
    }

    /// The message must not imply resolving one task is enough when several
    /// block the same team.
    func testSingleTeam_withSeveralBlockingTasks_saysSo() throws {
        let report = BundledUpdateReport(
            deferred: [team(name: "FAANG Team", otherTasks: 2)]
        )
        let message = try XCTUnwrap(report.bannerMessage)
        XCTAssertTrue(message.contains("3 tasks"), "1 named + 2 others = 3: \(message)")
        XCTAssertFalse(
            message.contains("#12"),
            "naming one task would imply resolving it is enough: \(message)"
        )
        assertFitsBanner(message, "multi-task deferral")
    }

    func testThreeTeams_listsThemAll() throws {
        let report = BundledUpdateReport(deferred: [
            team(name: "FAANG Team"), team(name: "Engineering"), team(name: "Startup")
        ])
        let message = try XCTUnwrap(report.bannerMessage)

        for name in ["FAANG Team", "Engineering", "Startup"] {
            XCTAssertTrue(message.contains(name), "missing \(name): \(message)")
        }
        XCTAssertFalse(message.contains("more"), "three names fit inline: \(message)")
        assertFitsBanner(message, "three-team deferral")
    }

    /// No silent caps: the overflow count is stated and arithmetically right.
    func testFiveTeams_statesTheOverflowCount() throws {
        let names = ["A Team", "B Team", "C Team", "D Team", "E Team"]
        let report = BundledUpdateReport(deferred: names.map { team(name: $0) })
        let message = try XCTUnwrap(report.bannerMessage)

        XCTAssertTrue(message.contains("5 teams"), message)
        XCTAssertTrue(message.contains("and 2 more"), "5 listed - 3 inline = 2: \(message)")
        XCTAssertFalse(message.contains("E Team"), "the 5th name is covered by the count")
        assertFitsBanner(message, "five-team deferral")
    }

    /// Boundary either side of the inline-name limit. Off-by-one here either
    /// drops a name silently or says "and 0 more".
    func testFourTeams_saysAndOneMore() throws {
        let names = ["A Team", "B Team", "C Team", "D Team"]
        let report = BundledUpdateReport(deferred: names.map { team(name: $0) })
        let message = try XCTUnwrap(report.bannerMessage)

        XCTAssertTrue(message.contains("4 teams"), message)
        XCTAssertTrue(message.contains("and 1 more"), message)
        XCTAssertFalse(message.contains("and 0 more"), message)
        assertFitsBanner(message, "four-team deferral")
    }

    func testTwoTeams_listsBothWithNoOverflow() throws {
        let report = BundledUpdateReport(deferred: [
            team(name: "FAANG Team"), team(name: "Engineering")
        ])
        let message = try XCTUnwrap(report.bannerMessage)

        XCTAssertTrue(message.contains("2 teams"), message)
        XCTAssertTrue(message.contains("FAANG Team"), message)
        XCTAssertTrue(message.contains("Engineering"), message)
        XCTAssertFalse(message.contains("more"), message)
        assertFitsBanner(message, "two-team deferral")
    }

    /// Exactly one extra blocking task — the singular/plural boundary of the
    /// count, and the point where naming a task number stops being honest.
    func testSingleTeam_withExactlyOneOtherTask_saysTwoTasks() throws {
        let report = BundledUpdateReport(deferred: [team(name: "FAANG Team", otherTasks: 1)])
        let message = try XCTUnwrap(report.bannerMessage)

        XCTAssertTrue(message.contains("2 tasks"), message)
        XCTAssertFalse(message.contains("#12"), message)
        assertFitsBanner(message, "two-task deferral")
    }

    /// Several blocking roles: the banner names one, and must not concatenate
    /// them into an unbounded string that blows the two-line budget.
    func testSingleTeam_withManyRoles_staysWithinBudget() throws {
        let report = BundledUpdateReport(deferred: [
            team(
                name: "FAANG Team",
                roles: ["Product Manager", "UX Researcher", "UX Designer",
                        "Tech Lead", "Software Engineer", "Code Reviewer"]
            )
        ])
        let message = try XCTUnwrap(report.bannerMessage)

        XCTAssertTrue(message.contains("Product Manager"), message)
        assertFitsBanner(message, "many-role deferral")
    }

    /// Long team names are the realistic way a two-line banner overflows.
    func testVeryLongTeamNames_stillFitTheBanner() throws {
        let long = String(repeating: "Extremely Long Team Name ", count: 4)
        let report = BundledUpdateReport(deferred: (0..<5).map { team(name: "\(long)\($0)") })
        let message = try XCTUnwrap(report.bannerMessage)
        // Can't win on content, but the count and the pointer must survive.
        XCTAssertTrue(message.contains("5 teams"), String(message.prefix(80)))
        XCTAssertTrue(message.contains("and 2 more"), String(message.prefix(80)))
    }

    /// Defensive: a team whose blocking role can't be resolved to a name still
    /// produces a sentence, not a dangling one.
    func testTeamWithNoResolvedRoleNames_stillReadsCleanly() throws {
        let report = BundledUpdateReport(deferred: [team(name: "FAANG Team", roles: [])])
        let message = try XCTUnwrap(report.bannerMessage)
        XCTAssertTrue(message.contains("a role is mid-run"), message)
        assertFitsBanner(message, "nameless-role deferral")
    }

    // MARK: - Scan failure (error, permanent)

    func testScanFailure_isAnErrorAndNamesTheTask() throws {
        let report = BundledUpdateReport(
            scanFailure: .taskFileUnreadable(
                taskID: 12,
                relativePath: ".nanoteams/internal/tasks/12/task.json",
                reason: "You don't have permission."
            )
        )
        let message = try XCTUnwrap(report.bannerMessage)

        XCTAssertTrue(report.bannerIsError, "a blocked folder needs error styling")
        XCTAssertTrue(message.contains("#12"), message)
        assertFitsBanner(message, "scan failure")
    }

    /// The durable row carries the detail the 4s banner can't.
    func testScanFailure_durableMessageNamesPathAndReason() throws {
        let report = BundledUpdateReport(
            scanFailure: .taskFileUnreadable(
                taskID: 12,
                relativePath: ".nanoteams/internal/tasks/12/task.json",
                reason: "You don't have permission."
            )
        )
        let durable = try XCTUnwrap(report.durableMessage)

        XCTAssertTrue(durable.contains(".nanoteams/internal/tasks/12/task.json"), durable)
        XCTAssertTrue(durable.contains("You don't have permission."), durable)
        XCTAssertTrue(durable.contains("every team"), "the block is folder-wide: \(durable)")
    }

    /// A scan failure blocks everything, so it must win the single banner slot.
    func testScanFailure_takesPrecedenceOverDeferrals() throws {
        let report = BundledUpdateReport(
            scanFailure: .taskFileUnreadable(taskID: 3, relativePath: "p", reason: "r"),
            deferred: [team(name: "FAANG Team")]
        )
        let message = try XCTUnwrap(report.bannerMessage)
        XCTAssertTrue(report.bannerIsError)
        XCTAssertTrue(message.contains("#3"), message)
        XCTAssertFalse(message.contains("FAANG Team"), message)
    }

    /// A deferral clears itself; only the permanent case earns a durable row.
    func testDeferral_hasNoDurableMessage() {
        let report = BundledUpdateReport(deferred: [team(name: "FAANG Team")])
        XCTAssertNil(report.durableMessage)
    }
}
