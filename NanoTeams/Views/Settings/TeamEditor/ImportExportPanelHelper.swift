import AppKit
import UniformTypeIdentifiers

// MARK: - Import/Export Panel Helper

/// AppKit panel helpers for team/role/artifact import and export.
/// Separated from TeamImportExportService to keep the service layer free of AppKit dependencies.
enum ImportExportPanelHelper {

    /// Present an NSSavePanel for JSON export and write data on success.
    @MainActor
    static func presentExportPanel(
        data: Data, fileName: String, message: String
    ) throws(ImportExportError) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = fileName
        panel.message = message

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            throw .fileAccessError
        }
    }

    /// Present an NSOpenPanel for JSON import and return the file data on success.
    @MainActor
    static func presentImportPanel(message: String) -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = message

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
    }
}
