import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import NanoTeams

/// Covers `FilePickerConfiguration` and `ModalPresentationGuard`, split out of
/// `FilePickerWarmup.present(...)`.
///
/// All 14 lines of `present` were uncovered and unreachable: it ends in `runModal()`, a
/// nested modal event loop, so a test that called it would hang until someone dismissed a
/// real open panel. What the loop was hiding is not the modal call but everything before
/// it — the panel is SHARED across every composer surface in the app, so each call's
/// configuration is a full reset rather than a delta, and a field left over from the
/// previous caller silently changes what the next one accepts.
///
/// Every test here is `async` on purpose. A sync test method in a `@MainActor` XCTestCase
/// enters through a protocol-witness path that does not re-establish main-actor isolation,
/// so touching a main-actor type from its body aborts the entire XCTest worker on the
/// mirror's CI runner (Xcode 26.3) while passing locally. `ModalPresentationGuard` is the
/// purest case in the tree — a lone `Bool` behind one method, nothing in it can fail — which
/// is what makes it evidence that the abort is the isolation check and not the constructor.
///
/// The whole class is converted rather than just the four that crashed: `NSOpenPanel` and
/// `FilePickerWarmup._testSharedPanel` are main-actor too, so the three `testApply_*` and
/// `testWarmup_*` are the same shape and were surviving on scheduling luck — one of them
/// was already reported as collateral of `testGuards_areIndependent`'s abort.
@MainActor
final class FilePickerConfigurationTests: XCTestCase {

    // MARK: - Configuration

    /// The reset property: applying a configuration must leave the panel in exactly the
    /// state that configuration describes, whatever the previous caller left behind.
    ///
    /// RED: drop any single assignment from `apply(to:)` → the corresponding assertion
    /// fails. Each one is a real bug: a stale `allowedContentTypes` keeps rejecting files
    /// the current caller accepts, and a stale `canChooseDirectories` lets a user attach a
    /// directory to a chat message.
    func testApply_overwritesEveryFieldTheSharedPanelCarries() async {
        let panel = NSOpenPanel()
        // Poison every field with the opposite of what we are about to apply.
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]

        FilePickerConfiguration(allowedContentTypes: [.png, .jpeg],
                                multiple: true,
                                allowDirectories: false).apply(to: panel)

        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.canChooseFiles, "a file picker that cannot choose files is inert")
        XCTAssertFalse(panel.canChooseDirectories,
                       "a stale `true` lets a user attach a directory to a message")
        XCTAssertFalse(panel.canCreateDirectories,
                       "the attach flow never creates directories")
        XCTAssertEqual(panel.allowedContentTypes, [.png, .jpeg],
                       "a stale content-type filter silently rejects the files the "
                       + "current caller accepts")
    }

    /// `directoryURL = nil` is part of the reset and reads like a no-op. It is not:
    /// `NSOpenPanel` otherwise reopens at the last-visited directory, which belongs to the
    /// PREVIOUS caller — a work-folder picker's directory showing up in an image attach.
    ///
    /// RED: remove the `panel.directoryURL = nil` line → this fails.
    func testApply_clearsTheInheritedStartDirectory() async {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/tmp")

        FilePickerConfiguration(allowedContentTypes: [], multiple: true,
                                allowDirectories: false).apply(to: panel)

        XCTAssertNil(panel.directoryURL,
                     "the panel must not reopen at the previous caller's directory")
    }

    /// The directory-picking caller (work folder selection) and the file-picking caller
    /// (attachments) must not resolve to the same panel state.
    func testApply_directoryPickerAndFilePickerDiffer() async {
        let files = NSOpenPanel()
        let dirs = NSOpenPanel()

        FilePickerConfiguration(allowedContentTypes: [], multiple: true,
                                allowDirectories: false).apply(to: files)
        FilePickerConfiguration(allowedContentTypes: [], multiple: false,
                                allowDirectories: true).apply(to: dirs)

        XCTAssertNotEqual(files.canChooseDirectories, dirs.canChooseDirectories)
        XCTAssertNotEqual(files.allowsMultipleSelection, dirs.allowsMultipleSelection)
    }

    /// An empty `allowedContentTypes` means "accept anything", which is the default for
    /// the generic `+` button. It must be applied, not skipped as an absent value.
    ///
    /// RED: guard the assignment with `if !allowedContentTypes.isEmpty` → the previous
    /// caller's filter survives and this fails.
    func testApply_emptyContentTypesClearsAnInheritedFilter() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]

        FilePickerConfiguration(allowedContentTypes: [], multiple: true,
                                allowDirectories: false).apply(to: panel)

        XCTAssertTrue(panel.allowedContentTypes.isEmpty,
                      "'accept anything' must clear the filter, not inherit one")
    }

    /// `forRequest` is where `present(...)`'s arguments become a configuration. It exists
    /// so that mapping is covered — inside `present` it would sit behind `runModal()`,
    /// permanently unreachable, and an argument wired to the wrong field there is exactly
    /// the silent bug the tests above are written against.
    ///
    /// RED: swap `multiple` and `allowDirectories` in `forRequest` → this fails.
    func testForRequest_mapsEachArgumentToItsOwnField() async {
        let config = FilePickerConfiguration.forRequest(
            allowedContentTypes: [.pdf], multiple: false, allowDirectories: true)

        XCTAssertEqual(config.allowedContentTypes, [.pdf])
        XCTAssertFalse(config.multiple)
        XCTAssertTrue(config.allowDirectories)
        XCTAssertEqual(config, FilePickerConfiguration(allowedContentTypes: [.pdf],
                                                      multiple: false,
                                                      allowDirectories: true))
    }

    // MARK: - The re-entry guard

    /// The claim must be released on the normal exit path, or the first `+` click disables
    /// every subsequent one for the life of the process — with no error anywhere.
    ///
    /// RED: remove the `defer { isClaimed = false }` → the second claim is refused and
    /// this fails.
    func testWithClaim_releasesAfterTheBody() async {
        let guardian = ModalPresentationGuard()

        XCTAssertEqual(guardian.withClaim { 1 }, 1)
        XCTAssertEqual(guardian.withClaim { 2 }, 2,
                       "a released claim must be re-claimable — a leaked one wedges the "
                       + "file picker permanently")
    }

    /// The reason the guard exists: `runModal()` runs a NESTED event loop, so a second `+`
    /// click dispatched during it re-enters on the same panel instance. That must be
    /// refused, and refusal must be distinguishable from the user cancelling.
    ///
    /// RED: remove the `if isClaimed { return nil }` → the inner claim runs and this fails.
    func testWithClaim_refusesReentryFromInsideTheBody() async {
        let guardian = ModalPresentationGuard()
        // Deliberately NOT an `Int??`: assigning an `Int?` into one FLATTENS, so a refused
        // inner claim and "never assigned" both read as `.none` and the assertion is
        // vacuous (measured — `inner == .some(nil)` is false after `inner = <nil Int?>`).
        var innerRan = false
        var innerRefused = false

        let outer = guardian.withClaim { () -> Int in
            XCTAssertTrue(guardian._testIsClaimed, "the claim is held for the body's duration")
            if let value = guardian.withClaim({ 99 }) {
                innerRan = true
                XCTAssertEqual(value, 99)
            } else {
                innerRefused = true
            }
            return 1
        }

        XCTAssertEqual(outer, 1)
        XCTAssertFalse(innerRan, "the nested modal loop must not re-enter the same panel")
        XCTAssertTrue(innerRefused,
                      "re-entry must yield nil — the caller reports 'already in flight', "
                      + "which is NOT the same as the user cancelling (empty array)")
        XCTAssertFalse(guardian._testIsClaimed, "released on exit")
    }

    /// `nil` (refused) and `[]` (cancelled) are different answers, and `present`'s return
    /// type keeps them apart. Collapsing them would make a re-entrant click look like a
    /// deliberate cancel and silently drop the user's second attempt.
    func testWithClaim_refusalIsDistinguishableFromAnEmptyResult() async {
        let guardian = ModalPresentationGuard()

        let cancelled: [URL]? = guardian.withClaim { [URL]() }
        XCTAssertNotNil(cancelled, "a completed body is never a refusal")
        XCTAssertEqual(cancelled ?? [URL(fileURLWithPath: "/sentinel")], [],
                       "the body's own empty result survives the wrapper")

        var refusedIsNil = false
        _ = guardian.withClaim { () -> [URL] in
            refusedIsNil = guardian.withClaim { [URL]() } == nil
            return []
        }
        XCTAssertTrue(refusedIsNil,
                      "a refusal is nil, so `present` can report it separately from the "
                      + "empty array a cancel produces")
    }

    /// Anti-vacuity: the guard must not be a global. Two pickers are independent, so one
    /// in flight cannot block the other.
    func testGuards_areIndependent() async {
        let a = ModalPresentationGuard()
        let b = ModalPresentationGuard()

        var bValue: Int?
        _ = a.withClaim { () -> Int in
            bValue = b.withClaim { 7 }
            return 1
        }
        XCTAssertEqual(bValue, 7, "a claim on one guard must not block another")
    }

    // MARK: - Warmup

    /// `warmup()` exists so the first `+` click does not pay AppKit's cold start. Its only
    /// observable contract is that the shared panel is a stable instance — a fresh panel
    /// per call would make the warmup pointless AND lose the re-entry guard's meaning.
    func testWarmup_forcesOneStableSharedPanel() async {
        FilePickerWarmup.warmup()
        let first = FilePickerWarmup._testSharedPanel
        FilePickerWarmup.warmup()
        XCTAssertTrue(first === FilePickerWarmup._testSharedPanel,
                      "the panel must be shared, or the re-entry guard guards nothing")
    }
}
