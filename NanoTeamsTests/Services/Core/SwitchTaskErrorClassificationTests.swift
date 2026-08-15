import XCTest

@testable import NanoTeams

/// Pins the user-facing message classification in `switchTask`'s active-task
/// pointer-write failure path. The two recoverable Cocoa-error categories —
/// disk full and permission-denied — must produce actionable hints; everything
/// else falls back to the underlying `localizedDescription`. Pre-fix the
/// caller showed only the raw description regardless of category, leaving
/// users without a recovery action.
///
/// Invariant the whole suite pins: every message ends with the
/// `"will not persist across app restarts"` suffix. Pre-broadening guard:
/// `.fileNoSuchFile` must NOT be bucketed under "re-grant folder access" —
/// it's most commonly raised mid-`resetAllData` once the `.nanoteams/` tree
/// is gone, and the user-actionable recovery for "folder deleted" is not
/// the same as "permission denied".
@MainActor
final class SwitchTaskErrorClassificationTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let persistenceSuffix = "will not persist across app restarts"

    // MARK: - Disk-full → "free up space"

    func testActiveTaskPointerErrorMessage_diskFull_includesFreeSpaceHint() {
        let error = CocoaError(.fileWriteOutOfSpace)
        let message = sut.activeTaskPointerErrorMessage(for: error)
        XCTAssertTrue(message.contains("disk may be full"),
                      "Disk-full should suggest freeing space; got: \(message)")
        XCTAssertTrue(message.contains(persistenceSuffix),
                      "Should retain the persistence-warning suffix; got: \(message)")
        XCTAssertTrue(message.contains(error.localizedDescription),
                      "Disk-full hint should retain OS-level localizedDescription (volume / path); got: \(message)")
    }

    // MARK: - Permission denied → "re-grant folder access"

    func testActiveTaskPointerErrorMessage_noPermission_suggestsReGrantingAccess() {
        let error = CocoaError(.fileWriteNoPermission)
        let message = sut.activeTaskPointerErrorMessage(for: error)
        XCTAssertTrue(message.contains("re-grant folder access"),
                      "Permission-denied should suggest re-granting access; got: \(message)")
        XCTAssertTrue(message.contains(persistenceSuffix),
                      "Should retain the persistence-warning suffix; got: \(message)")
        XCTAssertTrue(message.contains(error.localizedDescription),
                      "Permission hint should retain OS-level localizedDescription; got: \(message)")
    }

    func testActiveTaskPointerErrorMessage_readOnlyVolume_suggestsReGrantingAccess() {
        let error = CocoaError(.fileWriteVolumeReadOnly)
        let message = sut.activeTaskPointerErrorMessage(for: error)
        XCTAssertTrue(message.contains("re-grant folder access"),
                      "Read-only volume should land in the permission-recovery branch; got: \(message)")
        XCTAssertTrue(message.contains(persistenceSuffix),
                      "Should retain the persistence-warning suffix; got: \(message)")
    }

    func testActiveTaskPointerErrorMessage_fileLocking_suggestsReGrantingAccess() {
        // I3: classifier covers `.fileLocking` in code; this case pins it so
        // dropping `.fileLocking` from the bucket would fail.
        let error = CocoaError(.fileLocking)
        let message = sut.activeTaskPointerErrorMessage(for: error)
        XCTAssertTrue(message.contains("re-grant folder access"),
                      "fileLocking should land in the permission-recovery branch; got: \(message)")
        XCTAssertTrue(message.contains(persistenceSuffix))
    }

    // MARK: - `.fileNoSuchFile` (C2): falls through, NOT permission-denied

    func testActiveTaskPointerErrorMessage_fileNoSuchFile_fallsThroughToLocalizedDescription() {
        // Raised when the workfolder dir was deleted (typically mid-
        // `resetAllData`), the volume unmounted, or the path renamed. None
        // of these are recovered by re-granting folder access; the OS-level
        // message is more informative.
        let error = CocoaError(.fileNoSuchFile)
        let message = sut.activeTaskPointerErrorMessage(for: error)
        XCTAssertFalse(message.contains("re-grant folder access"),
                       "`.fileNoSuchFile` must NOT be bucketed as permission-denied; got: \(message)")
        XCTAssertFalse(message.contains("disk may be full"))
        XCTAssertTrue(message.contains(error.localizedDescription),
                      "Should surface localizedDescription so the user sees the actual cause; got: \(message)")
        XCTAssertTrue(message.contains(persistenceSuffix))
    }

    // MARK: - Generic fallback → underlying localizedDescription

    func testActiveTaskPointerErrorMessage_genericError_fallsBackToLocalizedDescription() {
        struct CustomError: LocalizedError {
            var errorDescription: String? { "Some weird unforeseen condition" }
        }
        let message = sut.activeTaskPointerErrorMessage(for: CustomError())
        XCTAssertTrue(message.contains("Some weird unforeseen condition"),
                      "Unrecognized errors should surface their localizedDescription; got: \(message)")
        XCTAssertFalse(message.contains("disk may be full"),
                       "Must not misclassify generic errors as disk-full")
        XCTAssertFalse(message.contains("re-grant folder access"),
                       "Must not misclassify generic errors as permission-denied")
        XCTAssertTrue(message.contains(persistenceSuffix),
                      "Generic fallback must keep the persistence suffix; got: \(message)")
    }

    // MARK: - Unrelated CocoaError code → fallback (not all CocoaErrors are recoverable)

    func testActiveTaskPointerErrorMessage_unrelatedCocoaCode_fallsBackToLocalizedDescription() {
        // .fileReadCorruptFile isn't a write-side error and shouldn't claim
        // disk-full or permission-denied. Falls through to the default arm.
        let error = CocoaError(.fileReadCorruptFile)
        let message = sut.activeTaskPointerErrorMessage(for: error)
        XCTAssertFalse(message.contains("disk may be full"))
        XCTAssertFalse(message.contains("re-grant folder access"))
        XCTAssertTrue(message.contains(persistenceSuffix))
    }
}
