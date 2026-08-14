import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import NanoTeams

/// The pre-instantiated `NSOpenPanel` behind the composer's `+` button.
///
/// The whole point of this type is that the panel is allocated ONCE, at launch, so the first `+`
/// click doesn't pay AppKit's cold-start cost — and that `present(...)` hands that same instance
/// back configured for each call rather than building a fresh one. Both properties are invisible
/// if they break: a second instance still works, it just makes the click slow again, which is
/// exactly the regression this type was introduced to prevent.
///
/// `present(...)` itself is deliberately never called — it runs `NSOpenPanel.runModal()`, a nested
/// event loop that would put a real file-picker on the developer's screen and block the suite
/// until someone dismissed it. Its re-entry guard is only reachable from inside that loop.
@MainActor
final class FilePickerWarmupTests: XCTestCase, @unchecked Sendable {

    /// `warmup()` forces the lazy allocation. It must be safe to call before any window exists
    /// and safe to call more than once — `NanoTeamsApp` calls it from scene setup, and a second
    /// call must not allocate a second panel.
    func testWarmup_isIdempotentAndDoesNotThrow() {
        FilePickerWarmup.warmup()
        FilePickerWarmup.warmup()
    }

    /// The panel is shared, so whatever `present(...)` last configured persists into the next
    /// call. That is precisely why `present(...)` re-sets every flag it cares about on entry
    /// instead of trusting the initial state — this pins the initial state it starts from.
    func testSharedPanel_startsConfiguredForMultiFileSelection() {
        FilePickerWarmup.warmup()
        let panel = FilePickerWarmup._testSharedPanel

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.canCreateDirectories,
                       "the composer attaches existing files; offering New Folder is noise")
        XCTAssertTrue(panel.allowsMultipleSelection)
    }

    /// The identity that makes the warm-up worth having at all. Two calls returning different
    /// instances would compile, pass every other test, and quietly restore the cold-start delay.
    func testSharedPanel_isTheSameInstanceEveryTime() {
        FilePickerWarmup.warmup()

        XCTAssertTrue(FilePickerWarmup._testSharedPanel === FilePickerWarmup._testSharedPanel)
    }
}
