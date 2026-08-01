import SwiftUI

/// The one way to open the Settings window and land on a specific tab.
///
/// Exists because three of the call sites are rendered inside the **QuickCapture
/// NSPanel**, whose window-raising behaviour is not what the plain
/// `openWindow(id:)` idiom implies — and having each site decide activation for
/// itself produced two affordances in one panel that behaved differently.
///
/// **Measured behaviour** (bundled probe replicating the exact topology —
/// `WindowGroup` + `Window(id:"settings")` + a `.nonactivatingPanel` / `.floating`
/// NSPanel hosting a bare `NSHostingView`, launched via LaunchServices with another
/// app frontmost; 9 runs, 2026-08-01):
///
/// | call | result |
/// |---|---|
/// | `openWindow(id:)` | **creates the window every time (9/9)** — the environment action does resolve outside a Scene |
/// | `NSApp.activate()` (the macOS 14+ cooperative form) | **never activates** — it requires the other app to have called `yieldActivationToApplication:` first, and nothing does |
/// | `NSRunningApplication.current.activate(.activateAllWindows)` | never activates |
/// | `NSApp.activate(ignoringOtherApps:)` alone | window created, app still inactive |
/// | `orderFrontRegardless()` alone | window created, app still inactive |
/// | **forceful activate + orderFrontRegardless + makeKey** | app active, Settings frontmost AND key |
///
/// So `openWindow` alone is NOT enough: it creates the window *behind* the frontmost
/// application, which is user-visibly indistinguishable from a dead button. That is
/// the failure mode this type exists to prevent, and it is why the Vision badge and
/// the dictation mic button route through here too rather than calling `openWindow`
/// directly as they used to.
///
/// `activate(ignoringOtherApps:)` is documented as "will be deprecated in a future
/// release", but it is the only variant measured to work here; the cooperative
/// replacement is a no-op for an app that holds no activation token. Re-measure with
/// the probe before swapping it.
@MainActor
enum SettingsNavigation {

    /// SwiftUI assigns the scene's `id` verbatim as the `NSWindow.identifier`
    /// (measured: `ident=settings`), so the window is found by identity rather than
    /// by its localized title.
    static let settingsWindowID = "settings"

    /// Opens Settings on `tab` and brings it to the front.
    ///
    /// - Parameters:
    ///   - tab: the tab to land on. `nil` keeps whatever tab the user last had — the
    ///     behaviour the generic entry points (status-bar gear, command palette) want.
    ///   - openWindow: the caller's own `@Environment(\.openWindow)`. Passed in rather
    ///     than read here because an environment action is resolved during body
    ///     evaluation of the view that declares it; there is no view here to read from.
    static func open(tab: SettingsView.SettingsTab? = nil, using openWindow: OpenWindowAction) {
        if let tab {
            // Written through UserDefaults rather than an `@AppStorage` binding so this
            // stays callable from any context. `SettingsView` reads the same key as
            // `@AppStorage` and re-evaluates live, so an already-open window retargets
            // with no mount race.
            UserDefaults.standard.set(tab.rawValue, forKey: UserDefaultsKeys.selectedSettingsTab)
        }
        openWindow(id: settingsWindowID)
        raiseSettingsWindow()
    }

    /// Activation + window raise, in the order the probe measured as the working one.
    /// Split out so the ordering has a single home and cannot drift between callers.
    private static func raiseSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == settingsWindowID
        }) else { return }
        window.orderFrontRegardless()
        window.makeKey()
    }
}
