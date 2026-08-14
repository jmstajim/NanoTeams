import Foundation
import UniformTypeIdentifiers
import AppKit

// MARK: - Staged Attachment

/// A staged file attachment (used by Quick Capture and Supervisor answer input).
nonisolated struct StagedAttachment: Identifiable, Hashable {
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
    ///
    /// Image-derived thumbnails are cached process-wide by `(url, size)` to avoid
    /// re-decoding from disk on every SwiftUI body re-evaluation.
    /// Workspace-icon fallbacks are NOT cached: a transient `NSImage(contentsOf:)`
    /// failure (file briefly missing, sandbox handoff in flight) would otherwise
    /// pin the generic icon under that key for the rest of the process lifetime.
    ///
    /// Keyed on the absolute `url`, not `stagedRelativePath`: for an in-project
    /// attachment that path is relative to the WORK FOLDER, so two projects that both
    /// keep `assets/icon.png` shared one entry and the second one attached rendered the
    /// first one's picture. A relative path identifies a file only within the folder it
    /// is relative to, and this cache outlives the folder.
    func thumbnail(size: CGFloat = 60) -> NSImage {
        let key = "\(url.path)|\(Int(size))" as NSString
        if let cached = StagedAttachment.thumbnailCache.object(forKey: key) {
            return cached
        }
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
            StagedAttachment.thumbnailCache.setObject(thumb, forKey: key)
            return thumb
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Process-wide LRU cache for `thumbnail(size:)`. `NSCache` is thread-safe.
    nonisolated(unsafe) private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()
}
