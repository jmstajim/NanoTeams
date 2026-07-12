import Foundation

nonisolated struct WorkFolderContextInput: Hashable {
    struct FileExcerpt: Hashable {
        var path: String
        var content: String
        /// Matched one of `priorityNames` (README / manifest / entry point).
        /// The planner gives priority excerpts a larger share of the budget.
        var isPriority: Bool = false
        /// The raw read hit the byte window, so the file may continue past
        /// `content` and the true line count is unknown. Drives the honest
        /// "file continues" truncation marker instead of "first N of M lines".
        var wasReadCapped: Bool = false
    }

    var rootName: String
    var fileList: [String]
    var fileTypeCounts: [String: Int]
    var excerpts: [FileExcerpt]
}

struct WorkFolderContextBuilder {
    nonisolated static func buildInput(
        workFolderRoot: URL,
        maxExcerpts: Int = 6,
        // Raw read window per excerpt. Generous (64 KB) because the planner
        // trims the excerpt down to first-N-lines under the model's context
        // budget — big-context models get long excerpts, small ones hit the
        // 50-line floor. Memory stays bounded at maxExcerpts × this.
        maxBytesPerExcerpt: Int = 65_536,
        fileManager: FileManager = .default
    ) -> WorkFolderContextInput {
        // Standardize path to resolve symlinks (e.g., /var -> /private/var on macOS)
        let basePath = workFolderRoot.standardizedFileURL.path
        let basePrefix = basePath.hasSuffix("/") ? basePath : (basePath + "/")

        let ignoredDirectories: Set<String> = [
            ".nanoteams",
            ".git",
            ".github",
            ".swiftpm",
            "DerivedData",
            "build",
            ".build",
            "Pods",
            "Carthage",
            "node_modules"
        ]

        let textExtensions: Set<String> = [
            "md", "markdown", "txt",
            "swift", "m", "mm", "h",
            "json", "yml", "yaml", "toml", "plist", "xcconfig",
            "js", "ts", "tsx", "css", "html", "xml",
            "py", "rb", "java", "kt", "go", "rs", "c", "cpp"
        ]

        let priorityNames: [String] = [
            "README.md",
            "README.txt",
            "Package.swift",
            "NanoTeamsApp.swift",
            "ContentView.swift",
            "main.swift",
            "AppDelegate.swift",
            "Info.plist"
        ]

        var fileList: [String] = []
        var fileTypeCounts: [String: Int] = [:]
        var filesByName: [String: URL] = [:]
        var excerptCandidates: [URL] = []

        guard let enumerator = fileManager.enumerator(
            at: workFolderRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return WorkFolderContextInput(
                rootName: workFolderRoot.lastPathComponent,
                fileList: [],
                fileTypeCounts: [:],
                excerpts: []
            )
        }

        for case let url as URL in enumerator {
            let rel = url.standardizedFileURL.path.replacingOccurrences(of: basePrefix, with: "")
            if rel.isEmpty { continue }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                if ignoredDirectories.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") || name.hasSuffix(".xcassets") {
                    fileList.append(rel)
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty {
                fileTypeCounts[ext, default: 0] += 1
            }

            fileList.append(rel)

            if filesByName[url.lastPathComponent] == nil {
                filesByName[url.lastPathComponent] = url
            }

            if textExtensions.contains(ext) {
                excerptCandidates.append(url)
            }
        }

        var excerpts: [WorkFolderContextInput.FileExcerpt] = []
        var usedPaths: Set<String> = []
        var usedFilenames: Set<String> = []

        func addExcerpt(from url: URL, isPriority: Bool) {
            guard excerpts.count < maxExcerpts else { return }
            let rel = url.standardizedFileURL.path.replacingOccurrences(of: basePrefix, with: "")
            guard !usedPaths.contains(rel) else { return }
            // Only one excerpt per unique filename (first found wins)
            let filename = url.lastPathComponent
            guard !usedFilenames.contains(filename) else { return }
            guard let read = readExcerpt(from: url, maxBytes: maxBytesPerExcerpt) else { return }
            excerpts.append(WorkFolderContextInput.FileExcerpt(
                path: rel,
                content: read.content,
                isPriority: isPriority,
                wasReadCapped: read.wasReadCapped
            ))
            usedPaths.insert(rel)
            usedFilenames.insert(filename)
        }

        for name in priorityNames {
            if let url = filesByName[name] {
                addExcerpt(from: url, isPriority: true)
            }
        }

        for url in excerptCandidates {
            if excerpts.count >= maxExcerpts { break }
            addExcerpt(from: url, isPriority: false)
        }

        return WorkFolderContextInput(
            rootName: workFolderRoot.lastPathComponent,
            fileList: fileList.sorted(),
            fileTypeCounts: fileTypeCounts,
            excerpts: excerpts
        )
    }

    /// Reads up to `maxBytes` of `url` as UTF-8 text. `wasReadCapped` is true
    /// when the read filled the whole window (the file may continue past it),
    /// so the planner can mark the excerpt honestly. `nil` for unreadable /
    /// empty / non-UTF-8 files (unchanged contract).
    nonisolated private static func readExcerpt(
        from url: URL,
        maxBytes: Int
    ) -> (content: String, wasReadCapped: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let dataChunk = try? handle.read(upToCount: maxBytes) else { return nil }
        guard !dataChunk.isEmpty else { return nil }
        let wasReadCapped = dataChunk.count >= maxBytes
        guard var text = decodeUTF8TrimmingPartialTail(dataChunk) else { return nil }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (text, wasReadCapped)
    }

    /// Decodes `data` as UTF-8. If the read terminated mid-multibyte-sequence
    /// (the cap fell inside a 2/3/4-byte codepoint — common with Cyrillic,
    /// CJK, or emoji at offset `maxBytes`), strict UTF-8 decode returns nil
    /// and the whole excerpt would be lost. Falls back by trimming up to 3
    /// trailing bytes — the maximum continuation tail. Non-UTF-8 files still
    /// return nil after exhausting the budget (no regression).
    nonisolated private static func decodeUTF8TrimmingPartialTail(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let maxDrop = min(3, data.count - 1)
        guard maxDrop >= 1 else { return nil }
        for drop in 1...maxDrop {
            if let s = String(data: data.prefix(data.count - drop), encoding: .utf8) {
                return s
            }
        }
        return nil
    }
}
