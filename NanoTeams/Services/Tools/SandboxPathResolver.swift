import Foundation

enum SandboxPathError: LocalizedError {
    case emptyPath
    case absolutePathNotAllowed(String)
    case parentTraversalNotAllowed(String)
    case outsideSandbox(String)
    case restrictedPath

    var errorDescription: String? {
        switch self {
        case .emptyPath:
            "Path is empty."
        case .absolutePathNotAllowed(let path):
            "Absolute paths are not allowed: \(path)"
        case .parentTraversalNotAllowed(let path):
            "Parent traversal (..) is not allowed: \(path)"
        case .outsideSandbox(let path):
            "Path resolves outside the selected work folder: \(path)"
        case .restrictedPath:
            "File not found."
        }
    }
}

struct SandboxPathResolver {
    let workFolderRoot: URL
    let internalDir: URL?

    init(workFolderRoot: URL, internalDir: URL? = nil) {
        self.workFolderRoot = workFolderRoot.standardizedFileURL
        self.internalDir = internalDir?.standardizedFileURL
    }

    func resolveFileURL(relativePath: String?) throws -> URL {
        let raw = (relativePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return workFolderRoot }

        // LLMs often pass the work folder name itself (e.g. "WorkFolder") as the path.
        // Since all paths are relative to the work folder root, treat it as ".".
        if raw == workFolderRoot.lastPathComponent { return workFolderRoot }

        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            throw SandboxPathError.absolutePathNotAllowed(raw)
        }

        let components = raw.split(separator: "/").map(String.init)
        if components.contains("..") {
            throw SandboxPathError.parentTraversalNotAllowed(raw)
        }

        var candidate = workFolderRoot
        for component in components where !component.isEmpty && component != "." {
            candidate.appendPathComponent(component, isDirectory: false)
        }

        let standardized = candidate.standardizedFileURL
        guard standardized == workFolderRoot || Self.isWithin(candidate: standardized, container: workFolderRoot) else {
            throw SandboxPathError.outsideSandbox(raw)
        }

        if let internalDir, Self.isWithin(candidate: standardized, container: internalDir) {
            throw SandboxPathError.restrictedPath
        }

        return standardized
    }

    /// Checks whether `candidate` is equal to or contained within `container` using path components.
    /// Robust against partial directory name matches (e.g., `/foo/internal-backup` does NOT match `/foo/internal`).
    static func isWithin(candidate: URL, container: URL) -> Bool {
        let containerComponents = container.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= containerComponents.count else { return false }
        return Array(candidateComponents.prefix(containerComponents.count)) == containerComponents
    }
}
