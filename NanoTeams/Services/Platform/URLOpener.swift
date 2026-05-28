import AppKit
import Foundation

/// Wrapper around `NSWorkspace.shared.open(_:)` that surfaces failures via a
/// caller-supplied closure. AppKit returns `false` when no default browser is
/// configured, the URL is malformed, or the host app is denied launch services
/// access — without surfacing, the user clicks "Update Now" / "Star on GitHub"
/// and nothing happens with no explanation.
nonisolated enum URLOpener {

    /// Opens `url`; routes a generic failure description through `surfacing`
    /// when AppKit refuses. The default message names the URL host so the user
    /// knows what didn't open.
    static func open(_ url: URL, onFailure surfacing: (String) -> Void) {
        if !NSWorkspace.shared.open(url) {
            surfacing(failureMessage(for: url))
        }
    }

    /// Pure helper — extracted for unit testing without an `NSWorkspace` seam.
    /// Names the URL host (or full string when host is nil) and points at the
    /// System Settings location for setting a default browser.
    static func failureMessage(for url: URL) -> String {
        let target = url.host ?? url.absoluteString
        return "Could not open \(target). Set a default web browser in System Settings → Desktop & Dock → Default web browser."
    }
}
