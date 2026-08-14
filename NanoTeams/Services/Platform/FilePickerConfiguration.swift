import AppKit
import UniformTypeIdentifiers

// MARK: - File Picker Configuration

/// The `NSOpenPanel` settings one `FilePickerWarmup.present(...)` call implies.
///
/// A value, applied in one place, because the panel is SHARED and reused across every
/// composer surface in the app. That makes each call's configuration a full reset rather
/// than a delta: a field left over from the previous caller silently changes what the
/// next one accepts — a `+` click after an image-only picker would keep rejecting text
/// files, and `canChooseDirectories` left true from a work-folder picker lets a user
/// attach a directory to a message. Neither surfaces as an error.
///
/// `present(...)` runs `runModal()`, a nested modal event loop, so it cannot be driven
/// from a test. Every field below therefore had to be asserted through the panel it is
/// applied to, or not at all.
nonisolated struct FilePickerConfiguration: Equatable {
    var allowedContentTypes: [UTType]
    var multiple: Bool
    var allowDirectories: Bool

    /// Maps one `FilePickerWarmup.present(...)` call's arguments to a configuration.
    ///
    /// A named factory rather than the memberwise init at the call site so the mapping is
    /// covered: everything inside `present` is permanently unreachable behind
    /// `runModal()`, so any logic left there is logic no test can see.
    static func forRequest(
        allowedContentTypes: [UTType],
        multiple: Bool,
        allowDirectories: Bool
    ) -> FilePickerConfiguration {
        FilePickerConfiguration(allowedContentTypes: allowedContentTypes,
                                multiple: multiple,
                                allowDirectories: allowDirectories)
    }

    /// Applies every field this type owns, so the shared panel carries no state from a
    /// previous caller.
    ///
    /// `directoryURL = nil` is part of that reset and easy to mistake for a no-op:
    /// `NSOpenPanel` otherwise reopens at the last-visited directory, which is the
    /// previous CALLER's directory, not the user's last choice in this context.
    @MainActor
    func apply(to panel: NSOpenPanel) {
        panel.allowsMultipleSelection = multiple
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowDirectories
        panel.canCreateDirectories = false
        panel.directoryURL = nil
        panel.allowedContentTypes = allowedContentTypes
    }
}

// MARK: - Modal Re-entry Guard

/// Single-slot claim on a resource that runs a nested modal event loop.
///
/// `withClaim` pairs claim and release structurally, via `defer`, so no future early
/// return inside the body can leak the claim. The previous shape — a `private static var
/// isPresenting` flipped by hand at the top of `present(...)` with its own `defer` —
/// was correct but left the pairing as a convention, and a leaked claim disables the
/// feature permanently with no diagnostic.
@MainActor
final class ModalPresentationGuard {
    private var isClaimed = false

    /// Runs `body` iff nothing holds the claim, releasing on every exit path.
    /// Returns `nil` when refused — distinguishable from `body`'s own empty result,
    /// which is what lets `present(...)` report "already in flight" separately from
    /// "the user cancelled".
    func withClaim<T>(_ body: () -> T) -> T? {
        if isClaimed { return nil }
        isClaimed = true
        defer { isClaimed = false }
        return body()
    }

    #if DEBUG
    /// For the pin that the claim is released even when `body` throws its way out via a
    /// non-local exit. Reading it from inside `withClaim` is the only way to observe the
    /// claimed state, since the whole point is that it is invisible from outside.
    var _testIsClaimed: Bool { isClaimed }
    #endif
}
