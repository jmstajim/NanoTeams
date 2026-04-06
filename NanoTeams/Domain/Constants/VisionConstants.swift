import Foundation

/// Vision/image analysis size limits and supported formats.
enum VisionConstants {
    /// Maximum image file size in bytes (10 MB).
    static let maxImageBytes = 10_485_760

    /// Supported image file extensions.
    static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]

    /// Extension → MIME type mapping.
    static let mimeTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp",
    ]
}
