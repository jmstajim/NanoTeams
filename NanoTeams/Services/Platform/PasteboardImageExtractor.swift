import AppKit
import Foundation

/// Reads images from an `NSPasteboard` and writes each as a PNG temp file.
/// Stateless; pasteboard, file manager, temp root, and clock are injectable for tests.
enum PasteboardImageExtractor {

    /// Outcome of an extraction call. `urls` are PNG files written successfully;
    /// `failures` are per-image error descriptions (encode or write failure) so the
    /// caller can surface the count + reason instead of silently dropping images.
    struct ExtractionResult: Equatable {
        let urls: [URL]
        let failures: [String]
    }

    static func hasImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Extracts every `NSImage` from `pasteboard`, encodes each as PNG, and writes
    /// the result to a uniquely-named file under `tempRoot`. Returns successful URLs
    /// and per-image failure messages — never silently drops images.
    static func extractImages(
        _ pasteboard: NSPasteboard = .general,
        tempRoot: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        now: Date = Date()
    ) -> ExtractionResult {
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              !images.isEmpty else {
            return ExtractionResult(urls: [], failures: [])
        }

        let timestamp = Self.timestampFormatter.string(from: now)
        let needsIndex = images.count > 1

        var urls: [URL] = []
        var failures: [String] = []
        for (index, image) in images.enumerated() {
            let label = needsIndex ? "image \(index + 1)" : "image"

            guard let png = pngData(for: image) else {
                failures.append("\(label): could not encode as PNG")
                continue
            }

            let suffix = needsIndex ? "-\(index + 1)" : ""
            let fileName = "Screenshot-\(timestamp)\(suffix).png"
            let url = tempRoot.appendingPathComponent(fileName, isDirectory: false)

            do {
                try png.write(to: url, options: .atomic)
                urls.append(url)
            } catch {
                failures.append("\(label): \(error.localizedDescription)")
            }
        }
        return ExtractionResult(urls: urls, failures: failures)
    }

    // MARK: - Private

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd-HHmmssSSS"
        return f
    }()
}
