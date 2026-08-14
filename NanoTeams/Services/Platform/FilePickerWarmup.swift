import AppKit
import UniformTypeIdentifiers

/// Pre-instantiated, reusable `NSOpenPanel` so the first `+` click in
/// `MessageComposer` doesn't pay the AppKit/XPC cold-start cost. Call
/// `warmup()` once at app launch (after the main window is up) so the
/// allocation runs while the user is reading the watchtower.
///
/// `present(...)` is the only sanctioned entry point for callers; it
/// resets per-call state, guards against re-entry inside the nested
/// modal event loop, and returns the user's selection.
@MainActor
enum FilePickerWarmup {
    /// Forces lazy initialization of `sharedPanel`. Call from app startup.
    static func warmup() {
        _ = sharedPanel
    }

    /// Presents the shared `NSOpenPanel` modally and returns the selected
    /// URLs (empty on cancel). Returns `nil` if a presentation is already
    /// in flight on the same panel — `runModal()` runs a nested event
    /// loop, so a `+` click in another composer dispatched during that
    /// loop must not re-enter onto the same panel instance.
    static func present(
        allowedContentTypes: [UTType] = [],
        multiple: Bool = true,
        allowDirectories: Bool = false
    ) -> [URL]? {
        presentationGuard.withClaim { runModally(FilePickerConfiguration.forRequest(
            allowedContentTypes: allowedContentTypes,
            multiple: multiple,
            allowDirectories: allowDirectories)) }
    }

    /// The modal leg, and the only part of this file that cannot be reached from a test.
    /// Kept to three statements deliberately: `runModal()` runs a nested event loop, so
    /// everything left in here is permanently uncovered and the honest move is to leave as
    /// little in here as possible rather than to arrange it more pleasantly.
    private static func runModally(_ configuration: FilePickerConfiguration) -> [URL] {
        let panel = sharedPanel
        configuration.apply(to: panel)
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Guards the one shared panel against re-entry from inside its own nested modal
    /// loop. A named guard rather than a bare `static var` because the claim/release
    /// pairing is the only part of `present(...)` that can misbehave and it is invisible
    /// when it does: a claim that is never released wedges every subsequent `+` click in
    /// the app, with no error anywhere.
    private static let presentationGuard = ModalPresentationGuard()

    #if DEBUG
    /// The shared instance, for tests that pin its identity and initial configuration.
    /// `present(...)` cannot be driven from a test — it runs a nested modal event loop.
    static var _testSharedPanel: NSOpenPanel { sharedPanel }
    #endif

    private static let sharedPanel: NSOpenPanel = {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        return panel
    }()
}
