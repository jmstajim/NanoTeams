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
        if isPresenting { return nil }
        isPresenting = true
        defer { isPresenting = false }

        let panel = sharedPanel
        panel.allowsMultipleSelection = multiple
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowDirectories
        panel.canCreateDirectories = false
        panel.directoryURL = nil
        panel.allowedContentTypes = allowedContentTypes
        return panel.runModal() == .OK ? panel.urls : []
    }

    private static var isPresenting = false

    private static let sharedPanel: NSOpenPanel = {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        return panel
    }()
}
