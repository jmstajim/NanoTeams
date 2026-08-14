import Foundation

// MARK: - Asset Inventory Seam

/// One pending model install, as a seam.
///
/// Deliberately carries no Speech types, so this protocol and the installer below are
/// free of the `@available(macOS 26, *)` gate the rest of the dictation catalogue lives
/// under. That is the difference between logic that can be tested on the machine
/// measuring coverage and logic that can only be tested on one OS version.
protocol DictationInstallRequest: Sendable {
    nonisolated func downloadAndInstall() async throws
    /// Signals the underlying `Progress` to abort. Named for the intent rather than the
    /// mechanism because Apple's installer may not honour it — which is precisely why the
    /// installer below ALSO rolls back after the fact.
    ///
    /// `nonisolated` is required, not stylistic: this runs inside
    /// `withTaskCancellationHandler`'s `onCancel`, which is a synchronous non-isolated
    /// closure. Without it the app target's default `@MainActor` isolation makes the call
    /// site fail to compile.
    nonisolated func cancelProgress()
}

/// The asset operations `DictationModelInstaller` drives.
///
/// `isInstalled` returns a `Bool` rather than `AssetInventory.Status` on purpose: the
/// installer only ever asks the yes/no question, and a Speech-typed answer would drag the
/// availability gate across the whole seam for no gain.
protocol DictationAssetInventory: Sendable {
    /// `nil` means "already installed" per Apple's documentation — which the installer
    /// deliberately does not trust.
    nonisolated func installationRequest(for locale: Locale) async throws -> (any DictationInstallRequest)?
    nonisolated func isInstalled(locale: Locale) async -> Bool
    /// Drops the locale reservation, uninstalling anything that landed. Returns whether
    /// the locale was actually reserved.
    @discardableResult
    nonisolated func release(reservedLocale: Locale) async -> Bool
}

// MARK: - Installer

/// The install state machine for an on-device dictation model.
///
/// Lifted out of `DictationModelCatalog.install` because the real one downloads a
/// multi-gigabyte model: every branch below was reachable only by hand, on a fast
/// connection, with a stopwatch. The three that matter are all rollback paths, and each
/// one leaves a different mess if it is wrong:
///
/// - **Undocumented nil.** Apple says a nil installation request means "already
///   installed". Observed otherwise for locales with no model available in the device's
///   region: the request is silently refused and nothing is installed. Trusting the
///   documentation there reports success and leaves the user with dictation that does
///   nothing.
/// - **Cancelled mid-download.** `Progress.cancel()` is a request, not a guarantee, so a
///   cancelled download can still finish. Without the post-hoc `release`, the model stays
///   installed while the UI shows the locale as `.supported` — the row's button offers to
///   download something already on disk.
/// - **Cancelled after the download finished.** The narrow race where the cancel lands
///   between the installer returning and this function returning. Same rollback, and it
///   is the one an implementation is most likely to omit, because the download
///   "succeeded".
nonisolated enum DictationModelInstaller {

    /// Reasons an install fails beyond Apple's own errors.
    enum InstallError: Error, LocalizedError, Equatable {
        /// A nil installation request that did NOT correspond to a completed install.
        case nothingInstallable

        var errorDescription: String? {
            switch self {
            case .nothingInstallable:
                return "No dictation model is available for download for this language."
            }
        }
    }

    /// Downloads and installs the model for `locale`, rolling back on cancellation.
    ///
    /// Throws `CancellationError` on either cancellation path so the caller's `try await`
    /// unblocks promptly, and rethrows Apple's error otherwise — the two must stay
    /// distinguishable or a genuine failure (unsupported locale, no disk space) is
    /// reported to the user as "you cancelled".
    static func install(locale: Locale, inventory: any DictationAssetInventory) async throws {
        guard let request = try await inventory.installationRequest(for: locale) else {
            // Verify rather than trust: still not installed means the request was refused.
            if await inventory.isInstalled(locale: locale) { return }
            throw InstallError.nothingInstallable
        }

        do {
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: {
                request.cancelProgress()
            }
        } catch {
            if Task.isCancelled {
                await inventory.release(reservedLocale: locale)
                throw CancellationError()
            }
            throw error
        }

        // The download finished, but the cancel may have raced in behind it.
        if Task.isCancelled {
            await inventory.release(reservedLocale: locale)
            throw CancellationError()
        }
    }
}
