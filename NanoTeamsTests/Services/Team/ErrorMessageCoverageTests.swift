import XCTest

@testable import NanoTeams

/// Coverage wave 1 — user-facing error strings that nothing had ever rendered.
///
/// These are not decorative. Every one of them is the only thing a user sees when the operation
/// behind it fails, and an `errorDescription` that names the wrong remedy is a support burden
/// that never shows up in a crash report. They are also the cheapest lines in the codebase to
/// reach, which is why they had survived five coverage waves untouched.
///
/// The assertions deliberately check CONTENT, not just non-emptiness: a switch arm returning the
/// wrong neighbour's string is the realistic defect here, and `XCTAssertFalse(s.isEmpty)` cannot
/// see it.
final class ErrorMessageCoverageTests: XCTestCase {

    // MARK: - Import / export

    /// RED: swap the `.invalidData` and `.fileAccessError` arms → both assertions below fail,
    /// which a non-emptiness check would not have noticed.
    func testImportExportError_everyCaseDescribesItself() {
        let unsupported = ImportExportError.unsupportedVersion(7)
        XCTAssertEqual(unsupported.errorDescription,
                       "Unsupported export format version: 7. Please update NanoTeams to import this file.")
        XCTAssertTrue(unsupported.localizedDescription.contains("7"),
                      "the offending version must reach the user — it is the only actionable part")

        XCTAssertEqual(ImportExportError.invalidData.errorDescription,
                       "The selected file does not contain valid export data.")
        XCTAssertEqual(ImportExportError.fileAccessError.errorDescription,
                       "Unable to read or write the file. Please check permissions.")

        // LocalizedError's bridge is what the UI actually reads.
        for error in [ImportExportError.invalidData, .fileAccessError, .unsupportedVersion(1)] {
            XCTAssertEqual(error.localizedDescription, error.errorDescription,
                           "\(error): localizedDescription must surface errorDescription, or the "
                           + "banner shows a type name instead of the message")
        }
    }

    // MARK: - Team management

    /// (`duplicateName` was deleted in wave 32 — duplicates are renamed at the single add
    /// door, `WorkFolderProjection.addTeam`, so the rejection message was dead copy.)
    ///
    /// RED: return the same string from two arms → the distinctness assertion fails.
    func testTeamValidationError_everyCaseHasItsOwnMessage() {
        let messages = [
            TeamValidationError.noRoles.localizedDescription,
            TeamValidationError.emptyName.localizedDescription,
        ]
        XCTAssertEqual(Set(messages).count, messages.count,
                       "two validation errors share a message, so the user cannot tell which rule "
                       + "they broke: \(messages)")
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Repository

    /// The repository's errors carry the offending path or id, which is the whole reason they are
    /// associated-value cases rather than a flat enum. Nothing had checked that the value
    /// actually reaches the string.
    ///
    /// RED: drop the interpolation from any arm (e.g. return a constant for `.taskNotFound`) →
    /// the matching assertion fails.
    func testRepositoryError_carriesItsSubjectIntoTheMessage() {
        let folder = URL(fileURLWithPath: "/tmp/nt-error-probe")

        XCTAssertTrue(NTMSRepositoryError.invalidProjectFolder(folder)
            .errorDescription?.contains(folder.path) == true,
            "the inaccessible folder must be named — 'not accessible' alone is unactionable")
        XCTAssertTrue(NTMSRepositoryError.taskNotFound(4_711)
            .errorDescription?.contains("4711") == true,
            "the task id must reach the message")

        XCTAssertEqual(NTMSRepositoryError.unableToEncodeReport.errorDescription,
                       "Unable to encode report as UTF-8.")

        struct Underlying: LocalizedError { var errorDescription: String? { "disk is full" } }
        let write = NTMSRepositoryError.unableToWriteReport(folder, underlying: Underlying())
        XCTAssertTrue(write.errorDescription?.contains(folder.path) == true)
        XCTAssertTrue(write.errorDescription?.contains("disk is full") == true,
                      "the underlying cause is the actionable half; swallowing it leaves the user "
                      + "with 'unable to write' and nothing to do about it")
    }
}
