import AppKit
import Foundation

/// Pure classification of a Cmd+V pasteboard into a `MessageComposerPasteAction`.
/// Kept top-level (not nested in `MessageComposer<SettingsMenu>`) so the type
/// isn't tied to the composer's generic parameter — tests reference a single
/// canonical enum regardless of which settings-menu variant the view uses.
enum MessageComposerPasteAction: Equatable {
    case stageFiles([URL])
    case stageImages(extraction: PasteboardImageExtractor.ExtractionResult, alsoHasText: Bool)
    case passThrough
}

enum MessageComposerPasteHandler {
    /// Classifies pasteboard contents without performing any I/O. The view's
    /// `handlePasteEvent` does the staging and decides whether to forward or
    /// suppress the underlying NSEvent based on the returned action.
    static func dispatch(
        pasteboard: NSPasteboard,
        extractImages: (NSPasteboard) -> PasteboardImageExtractor.ExtractionResult = {
            PasteboardImageExtractor.extractImages($0)
        }
    ) -> MessageComposerPasteAction {
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: NSNumber(value: true)]
        ) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            return .stageFiles(fileURLs)
        }
        if PasteboardImageExtractor.hasImage(pasteboard) {
            let result = extractImages(pasteboard)
            let alsoHasText = pasteboard.string(forType: .string) != nil
            return .stageImages(extraction: result, alsoHasText: alsoHasText)
        }
        return .passThrough
    }
}
