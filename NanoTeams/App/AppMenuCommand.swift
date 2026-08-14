import SwiftUI

// MARK: - App Menu Command Catalog

/// The menu-bar command table, split out of `NanoTeamsApp.body`'s `.commands`
/// builder.
///
/// Why this is a type and not nine inline `Button` closures: the title, the
/// keyboard shortcut, and the effect of a menu item are three facts that must
/// agree, and inside a `CommandsBuilder` nothing can read any of them. That
/// made two classes of bug unobservable — a shortcut claimed twice by different
/// menus (macOS silently binds one and drops the other), and an item whose
/// effect is a `NotificationCenter.post` for a name nothing observes (a menu
/// entry that looks live and does nothing).
///
/// The Scene body keeps ownership of WHICH commands appear in WHICH menu and in
/// what order — that is genuine SwiftUI declaration. This type owns what each
/// one IS.
///
/// `@MainActor` (not `nonisolated`) matching its view-adjacent neighbours
/// (`SidebarViewLogic`, `MainLayoutView.onScreenTaskID`): it names SwiftUI's
/// `KeyEquivalent` / `EventModifiers` and its `perform()` drives a `@MainActor`
/// singleton.
enum AppMenuCommand: String, CaseIterable, Identifiable, Sendable {
    case openWorkFolder
    case closeWorkFolder
    case newTask
    case watchtower
    case activeTask
    case quickTask
    case startRun
    case pause
    case resume

    nonisolated var id: String { rawValue }

    // MARK: - Effect

    /// What firing the item does. Separating the DECISION from the side effect
    /// is what makes the table testable: `.post` can be asserted end-to-end
    /// through `NotificationCenter`, while `.toggleQuickCapture` — which would
    /// put a floating panel on screen — is asserted structurally and never
    /// invoked from a test.
    enum Effect: Equatable, Sendable {
        case post(Notification.Name)
        case toggleQuickCapture
    }

    nonisolated var effect: Effect {
        switch self {
        case .openWorkFolder: return .post(.openProject)
        case .closeWorkFolder: return .post(.closeProject)
        case .newTask: return .post(.createNewTask)
        case .watchtower: return .post(.navigateToWatchtower)
        case .activeTask: return .post(.navigateToActiveTask)
        case .quickTask: return .toggleQuickCapture
        case .startRun: return .post(.startRun)
        case .pause: return .post(.pauseRun)
        case .resume: return .post(.resumeRun)
        }
    }

    // MARK: - Presentation

    nonisolated var title: String {
        switch self {
        case .openWorkFolder: return "Open Work Folder..."
        case .closeWorkFolder: return "Close Work Folder"
        case .newTask: return "New Task..."
        case .watchtower: return "Watchtower"
        case .activeTask: return "Active Task"
        case .quickTask: return "Quick Task..."
        case .startRun: return "Start Run..."
        case .pause: return "Pause"
        case .resume: return "Resume"
        }
    }

    /// The literal character of the shortcut. Kept as `Character` rather than
    /// `KeyEquivalent` so the table is comparable — `KeyEquivalent` is not
    /// `Equatable`, which is exactly what a collision check needs.
    nonisolated var shortcutKey: Character {
        switch self {
        case .openWorkFolder: return "o"
        case .closeWorkFolder: return "w"
        case .newTask: return "n"
        case .watchtower: return "1"
        case .activeTask: return "3"
        case .quickTask: return "0"
        case .startRun: return "r"
        case .pause: return "p"
        case .resume: return "."
        }
    }

    var shortcutModifiers: EventModifiers {
        switch self {
        case .openWorkFolder, .newTask, .watchtower, .activeTask, .startRun, .resume:
            return .command
        case .closeWorkFolder, .pause:
            return [.command, .shift]
        case .quickTask:
            return [.command, .option, .control]
        }
    }

    var keyEquivalent: KeyEquivalent { KeyEquivalent(shortcutKey) }

    // MARK: - Dispatch

    @MainActor
    func perform() {
        switch effect {
        case .post(let name):
            NotificationCenter.default.post(name: name, object: nil)
        case .toggleQuickCapture:
            QuickCaptureController.shared.togglePanel()
        }
    }
}

extension AppMenuCommand {
    /// The Help menu's single item. Not an `AppMenuCommand` case — it is a
    /// `Link` with no shortcut and no in-app effect — but it lives beside the
    /// command table so the whole menu bar has one source of truth and the
    /// destination is assertable.
    ///
    /// The destination MUST come from `AppURLs`. It previously carried its own
    /// literal (`https://github.com/NanoTeams/docs`) which pointed at a
    /// different GitHub org than every other link in the app
    /// (`jmstajim/NanoTeams`), so Help → NanoTeams Help opened a dead page.
    enum HelpLink {
        static let title = "NanoTeams Help"
        static let destination = AppURLs.documentation
    }
}

/// One catalog entry rendered as a menu item. Exists so the `.commands` builder
/// stays a list of `AppMenuButton(.watchtower)` declarations instead of
/// re-spelling the title/shortcut/action triple at each site.
struct AppMenuButton: View {
    let command: AppMenuCommand

    init(_ command: AppMenuCommand) {
        self.command = command
    }

    var body: some View {
        Button(command.title) { command.perform() }
            .keyboardShortcut(command.keyEquivalent, modifiers: command.shortcutModifiers)
    }
}
