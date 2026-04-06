import Foundation

struct WorkFolderDescriptionInput: Hashable {
    struct FileExcerpt: Hashable {
        var path: String
        var content: String
    }

    var rootName: String
    var fileList: [String]
    var fileTypeCounts: [String: Int]
    var excerpts: [FileExcerpt]
}

struct WorkFolderDescriptionBuilder {
    nonisolated static func buildInput(
        workFolderRoot: URL,
        maxFiles: Int = 120,
        maxExcerpts: Int = 6,
        maxBytesPerExcerpt: Int = 3000,
        fileManager: FileManager = .default
    ) -> WorkFolderDescriptionInput {
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
            "README_LLM.md",
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
            return WorkFolderDescriptionInput(
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
                    if fileList.count < maxFiles {
                        fileList.append(rel)
                    }
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty {
                fileTypeCounts[ext, default: 0] += 1
            }

            if fileList.count < maxFiles {
                fileList.append(rel)
            }

            if filesByName[url.lastPathComponent] == nil {
                filesByName[url.lastPathComponent] = url
            }

            if textExtensions.contains(ext) {
                excerptCandidates.append(url)
            }
        }

        var excerpts: [WorkFolderDescriptionInput.FileExcerpt] = []
        var usedPaths: Set<String> = []
        var usedFilenames: Set<String> = []

        func addExcerpt(from url: URL) {
            guard excerpts.count < maxExcerpts else { return }
            let rel = url.standardizedFileURL.path.replacingOccurrences(of: basePrefix, with: "")
            guard !usedPaths.contains(rel) else { return }
            // Only one excerpt per unique filename (first found wins)
            let filename = url.lastPathComponent
            guard !usedFilenames.contains(filename) else { return }
            guard let content = readExcerpt(from: url, maxBytes: maxBytesPerExcerpt) else { return }
            excerpts.append(WorkFolderDescriptionInput.FileExcerpt(path: rel, content: content))
            usedPaths.insert(rel)
            usedFilenames.insert(filename)
        }

        for name in priorityNames {
            if let url = filesByName[name] {
                addExcerpt(from: url)
            }
        }

        for url in excerptCandidates {
            if excerpts.count >= maxExcerpts { break }
            addExcerpt(from: url)
        }

        return WorkFolderDescriptionInput(
            rootName: workFolderRoot.lastPathComponent,
            fileList: fileList.sorted(),
            fileTypeCounts: fileTypeCounts,
            excerpts: excerpts
        )
    }

    nonisolated private static func readExcerpt(from url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let dataChunk = try? handle.read(upToCount: maxBytes) else { return nil }
        guard !dataChunk.isEmpty else { return nil }
        guard var text = String(data: dataChunk, encoding: .utf8) else { return nil }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
