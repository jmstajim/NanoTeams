import SwiftUI
import XCTest

@testable import NanoTeams

/// Collects notification names seen by `@Sendable` observer blocks.
private final class SiblingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func record(_ name: String) {
        lock.withLock { names.append(name) }
    }

    var recorded: [String] {
        lock.withLock { names }
    }
}

/// Covers the menu-bar command table extracted out of `NanoTeamsApp.body`'s
/// `.commands` builder.
///
/// **`.quickTask.perform()` is never called here.** Its effect is
/// `.toggleQuickCapture`, which puts a floating `NSPanel` on screen. It is
/// asserted structurally instead — that it is the one command whose effect is
/// not a notification post.
///
/// The eight `.post` commands ARE invoked. That is safe: the notification
/// observers all live in `.onReceive` inside `MainLayoutView` / `SidebarView` /
/// `TeamActivityFeedView`, and `NanoTeamsApp.body` swaps the whole scene for
/// `Color.clear` under XCTest (`isRunningTests`), so no view is ever installed
/// to receive them.
@MainActor
final class AppMenuCommandTests: XCTestCase {

    // MARK: - Table completeness

    /// A new command that forgets a title ships an empty menu item — visible,
    /// clickable, unlabelled.
    func testEveryCommand_hasANonEmptyTitle() {
        for command in AppMenuCommand.allCases {
            XCTAssertFalse(
                command.title.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(command.rawValue) has no title."
            )
        }
    }

    /// Pins the count so adding a case forces a visit to the shortcut table
    /// below (where the collision guard lives).
    func testCommandCount_isPinned() {
        XCTAssertEqual(AppMenuCommand.allCases.count, 9)
    }

    func testRawValues_areUniqueAndUsedAsIdentity() {
        let ids = AppMenuCommand.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(AppMenuCommand.watchtower.id, "watchtower")
    }

    // MARK: - Shortcut table

    /// The exact shortcuts the app advertises. Spelled out so a change to any
    /// of them is a deliberate edit to this list, not a silent side effect of
    /// touching the Scene body.
    func testShortcutTable_isPinned() {
        let expected: [AppMenuCommand: (Character, EventModifiers)] = [
            .openWorkFolder: ("o", .command),
            .closeWorkFolder: ("w", [.command, .shift]),
            .newTask: ("n", .command),
            .watchtower: ("1", .command),
            .activeTask: ("3", .command),
            .quickTask: ("0", [.command, .option, .control]),
            .startRun: ("r", .command),
            .pause: ("p", [.command, .shift]),
            .resume: (".", .command)
        ]
        XCTAssertEqual(expected.count, AppMenuCommand.allCases.count,
                       "Shortcut expectations must cover every command.")
        for command in AppMenuCommand.allCases {
            guard let (key, modifiers) = expected[command] else {
                XCTFail("No shortcut expectation for \(command.rawValue)"); continue
            }
            XCTAssertEqual(command.shortcutKey, key, "\(command.rawValue) key")
            XCTAssertEqual(command.shortcutModifiers, modifiers, "\(command.rawValue) modifiers")
        }
    }

    /// **The reason this table is a type.** macOS binds one item per
    /// (key, modifiers) pair and silently drops the rest — a duplicate would
    /// disable a menu item with no build error, no warning, and no crash.
    /// Nothing caught this while the shortcuts were nine separate literals
    /// spread across four `CommandGroup` closures.
    func testNoTwoCommands_claimTheSameShortcut() {
        var seen: [String: AppMenuCommand] = [:]
        for command in AppMenuCommand.allCases {
            let signature = "\(command.shortcutKey)|\(command.shortcutModifiers.rawValue)"
            if let clash = seen[signature] {
                XCTFail("\(command.rawValue) claims the same shortcut as \(clash.rawValue): \(signature)")
            }
            seen[signature] = command
        }
    }

    /// Every shortcut must include ⌘. A bare-letter menu shortcut would
    /// swallow that character from every text field in the app.
    func testEveryShortcut_includesCommand() {
        for command in AppMenuCommand.allCases {
            XCTAssertTrue(
                command.shortcutModifiers.contains(.command),
                "\(command.rawValue) has a shortcut without ⌘ — it would eat that keystroke app-wide."
            )
        }
    }

    func testKeyEquivalent_isDerivedFromTheComparableCharacter() {
        for command in AppMenuCommand.allCases {
            XCTAssertEqual(command.keyEquivalent.character, command.shortcutKey,
                           "\(command.rawValue) KeyEquivalent drifted from shortcutKey.")
        }
    }

    // MARK: - Effect table

    func testEffectTable_isPinned() {
        let expected: [AppMenuCommand: AppMenuCommand.Effect] = [
            .openWorkFolder: .post(.openProject),
            .closeWorkFolder: .post(.closeProject),
            .newTask: .post(.createNewTask),
            .watchtower: .post(.navigateToWatchtower),
            .activeTask: .post(.navigateToActiveTask),
            .quickTask: .toggleQuickCapture,
            .startRun: .post(.startRun),
            .pause: .post(.pauseRun),
            .resume: .post(.resumeRun)
        ]
        XCTAssertEqual(expected.count, AppMenuCommand.allCases.count)
        for command in AppMenuCommand.allCases {
            XCTAssertEqual(command.effect, expected[command], "\(command.rawValue) effect")
        }
    }

    /// Two commands posting the same notification would be two menu items that
    /// do the same thing under different names.
    func testNoTwoCommands_postTheSameNotification() {
        var seen: Set<Notification.Name> = []
        for command in AppMenuCommand.allCases {
            guard case .post(let name) = command.effect else { continue }
            XCTAssertTrue(seen.insert(name).inserted,
                          "\(command.rawValue) re-posts \(name.rawValue).")
        }
    }

    /// `.toggleQuickCapture` is the one non-notification effect. If a second
    /// appears, the dispatch below needs revisiting AND this suite needs to
    /// decide whether the new one is safe to invoke from a test.
    func testQuickTask_isTheOnlyCommandThatDrivesAnObjectDirectly() {
        let direct = AppMenuCommand.allCases.filter { $0.effect == .toggleQuickCapture }
        XCTAssertEqual(direct, [.quickTask])
    }

    // MARK: - Dispatch

    /// Drives `perform()`'s `.post` arm end to end for each notification-backed
    /// command and asserts it fires ITS name — a copy-paste slip between the
    /// nine near-identical entries (e.g. Pause posting `.startRun`) is exactly
    /// the failure this catches, and it produces no error at the time.
    func testPerform_postsExactlyItsOwnNotification() async {
        for command in AppMenuCommand.allCases {
            guard case .post(let expected) = command.effect else { continue }

            let fulfilled = expectation(description: "posted \(expected.rawValue)")
            let token = NotificationCenter.default.addObserver(
                forName: expected, object: nil, queue: .main
            ) { _ in fulfilled.fulfill() }
            defer { NotificationCenter.default.removeObserver(token) }

            command.perform()
            await fulfillment(of: [fulfilled], timeout: 2)
        }
    }

    /// Firing one command must not also fire a sibling's notification —
    /// guards against a future shared/fan-out dispatch.
    func testPerform_doesNotPostAnySiblingNotification() async {
        let subject = AppMenuCommand.watchtower
        guard case .post(let own) = subject.effect else {
            return XCTFail("Test subject must be a notification-backed command.")
        }
        let siblings: [Notification.Name] = AppMenuCommand.allCases.compactMap {
            guard case .post(let name) = $0.effect, name != own else { return nil }
            return name
        }

        // Lock-guarded box rather than a captured `var`: the observer block is
        // `@Sendable`, so mutating a local from inside it is a Swift 6 error.
        let recorder = SiblingRecorder()
        var tokens: [any NSObjectProtocol] = []
        for name in siblings {
            tokens.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in recorder.record(name.rawValue) })
        }
        let ownFired = expectation(description: "own notification")
        tokens.append(NotificationCenter.default.addObserver(
            forName: own, object: nil, queue: .main
        ) { _ in ownFired.fulfill() })
        defer { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

        subject.perform()
        await fulfillment(of: [ownFired], timeout: 2)
        XCTAssertTrue(recorder.recorded.isEmpty, "Also posted: \(recorder.recorded)")
    }

    // MARK: - Help link (DEFECT pin)

    /// **Regression pin for a shipped defect.**
    ///
    /// The Help menu carried its own literal, `https://github.com/NanoTeams/docs`
    /// — a different GitHub org from the one every other link in the app uses
    /// (`jmstajim/NanoTeams`, held in `AppURLs`). Failure scenario: a user picks
    /// Help → NanoTeams Help and lands on a 404, with no in-app signal that the
    /// link is wrong. `AppURLs` exists precisely to be the single source of
    /// truth for these; that one site bypassed it.
    func testHelpLink_resolvesThroughAppURLs() {
        XCTAssertEqual(AppMenuCommand.HelpLink.destination, AppURLs.documentation)
    }

    func testHelpLink_pointsAtTheSameRepositoryAsEveryOtherAppURL() {
        let host = AppMenuCommand.HelpLink.destination.host()
        XCTAssertEqual(host, AppURLs.githubRepository.host())

        let path = AppMenuCommand.HelpLink.destination.path()
        XCTAssertTrue(
            path.hasPrefix(AppURLs.githubRepository.path()),
            "Help link \(AppMenuCommand.HelpLink.destination) is outside the app's own repository "
                + "(\(AppURLs.githubRepository)) — this was a dead `NanoTeams/docs` link."
        )
    }

    func testHelpLink_hasANonEmptyTitle() {
        XCTAssertFalse(AppMenuCommand.HelpLink.title.isEmpty)
    }
}
