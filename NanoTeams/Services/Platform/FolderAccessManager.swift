import Foundation
import AppKit
import Observation

@Observable @MainActor
final class FolderAccessManager {
    private(set) var workFolderURL: URL?

    private static let bookmarkDefaultsKey = "NanoTeams.projectFolderBookmark.v1"
    private var securityScopedAccessActive = false
    private let storage: any ConfigurationStorage

    init(storage: any ConfigurationStorage = UserDefaults.standard) {
        self.storage = storage
    }

    deinit {
        MainActor.assumeIsolated {
            stopSecurityScopedAccessIfNeeded()
        }
    }

    func restoreLastFolderIfPossible() async {
        guard let data = storage.data(forKey: Self.bookmarkDefaultsKey) else { return }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )

            if stale {
                // Refresh the bookmark data to keep it valid.
                try persistBookmark(for: url)
            }

            setProjectFolder(url)
        } catch {
            // If restoration fails, clear stored bookmark.
            storage.removeObject(forKey: Self.bookmarkDefaultsKey)
        }
    }

    private func setProjectFolder(_ url: URL) {
        stopSecurityScopedAccessIfNeeded()

        do {
            try persistBookmark(for: url)
        } catch {
            // If bookmark cannot be created, still set URL (useful for non-sandbox builds).
        }

        _ = url.startAccessingSecurityScopedResource()
        securityScopedAccessActive = true

        workFolderURL = url
    }

    private func stopSecurityScopedAccessIfNeeded() {
        guard securityScopedAccessActive, let url = workFolderURL else { return }
        url.stopAccessingSecurityScopedResource()
        securityScopedAccessActive = false
    }

    private func persistBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        storage.set(data, forKey: Self.bookmarkDefaultsKey)
    }
}
