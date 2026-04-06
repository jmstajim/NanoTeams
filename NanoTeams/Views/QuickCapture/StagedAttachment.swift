import Foundation
import UniformTypeIdentifiers
import AppKit

// MARK: - Staged Attachment

/// A staged file attachment (used by Quick Capture and Supervisor answer input).
struct StagedAttachment: Identifiable, Hashable {
    let stagedRelativePath: String
    let url: URL
    let fileName: String
    let fileType: UTType?
    let fileSize: Int64
    /// When `true`, the file lives inside the project folder and was NOT copied to staging.
    /// `removeStagedAttachment` must skip deletion for these — they point to the user's real file.
    let isProjectReference: Bool

    var id: String { stagedRelativePath }

    var isImage: Bool {
        fileType?.conforms(to: .image) ?? false
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    enum InitError: LocalizedError {
        case fileNotAccessible(URL, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .fileNotAccessible(let url, let underlying):
                "Cannot read file \(url.lastPathComponent): \(underlying.localizedDescription)"
            }
        }
    }

    init(url: URL, stagedRelativePath: String, isProjectReference: Bool = false) throws {
        self.isProjectReference = isProjectReference
        self.stagedRelativePath = stagedRelativePath
        self.url = url
        self.fileName = url.lastPathComponent
        self.fileType = UTType(filenameExtension: url.pathExtension)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            self.fileSize = (attrs[.size] as? Int64) ?? 0
        } catch {
            throw InitError.fileNotAccessible(url, underlying: error)
        }
    }

    // MARK: - Hashable (by id only)

    static func == (lhs: StagedAttachment, rhs: StagedAttachment) -> Bool {
        lhs.stagedRelativePath == rhs.stagedRelativePath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(stagedRelativePath)
    }

    // MARK: - Thumbnail

    /// Returns a thumbnail image for this attachment.
    /// Images get a scaled-down preview; other files get their system icon.
    func thumbnail(size: CGFloat = 60) -> NSImage {
        if isImage, let image = NSImage(contentsOf: url) {
            let aspect = image.size.width / image.size.height
            let targetSize: NSSize
            if aspect > 1 {
                targetSize = NSSize(width: size, height: size / aspect)
            } else {
                targetSize = NSSize(width: size * aspect, height: size)
            }
            let thumb = NSImage(size: targetSize)
            thumb.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: targetSize),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy, fraction: 1.0)
            thumb.unlockFocus()
            return thumb
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
