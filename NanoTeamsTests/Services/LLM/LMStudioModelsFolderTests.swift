import XCTest

@testable import NanoTeams

/// Corner coverage for the pure half of LM Studio's filesystem-based model
/// deletion. This is where the feature's whole risk sits: `isLocalEndpoint`
/// decides whether we may touch files at all, and `resolveModelDirectory`
/// decides WHICH directory gets moved to the Trash. Both are total functions
/// over strings, so they can be pinned exhaustively without a real models
/// folder.
final class LMStudioModelsFolderTests: XCTestCase {

    // MARK: - isLocalEndpoint

    func testIsLocalEndpoint_acceptsLoopbackForms() {
        for url in [
            "http://127.0.0.1:1234",
            "http://127.0.0.1:1234/",
            "http://localhost:1234",
            "http://LOCALHOST:1234",
            "http://[::1]:1234",
            "http://0.0.0.0:1234",
            // The whole 127.0.0.0/8 block is loopback, not only .0.1.
            "http://127.1.2.3:1234",
            "https://127.0.0.1:1234",
        ] {
            XCTAssertTrue(
                LMStudioModelsFolder.isLocalEndpoint(baseURLString: url),
                "\(url) should be treated as local")
        }
    }

    func testIsLocalEndpoint_rejectsEverythingElse() {
        for url in [
            "http://192.168.1.5:1234",
            "http://10.0.0.2:1234",
            "http://example.com:1234",
            // Deliberately NOT resolved: a hostname that happens to point at
            // this machine still reads as remote, because the safe failure
            // direction is "don't touch files".
            "http://my-mac.local:1234",
            // Not loopback despite the leading digits.
            "http://127.0.0:1234",
            "http://1270.0.0.1:1234",
            "http://127.0.0.999:1234",
            "",
            "   ",
            "not a url at all",
        ] {
            XCTAssertFalse(
                LMStudioModelsFolder.isLocalEndpoint(baseURLString: url),
                "\(url) should NOT be treated as local")
        }
    }

    func testIsLocalEndpoint_toleratesSurroundingWhitespace() {
        XCTAssertTrue(LMStudioModelsFolder.isLocalEndpoint(baseURLString: "  http://127.0.0.1:1234  "))
    }

    // MARK: - resolveModelDirectory

    private func makeRoot() -> URL {
        URL(fileURLWithPath: "/tmp/nanoteams-models-root-fixture")
    }

    func testResolveModelDirectory_acceptsTwoComponentID() {
        let root = makeRoot()
        let resolved = LMStudioModelsFolder.resolveModelDirectory(
            id: "lmstudio-community/gpt-oss-20b-GGUF", root: root)
        XCTAssertEqual(
            resolved?.standardizedFileURL,
            root.appending(path: "lmstudio-community").appending(path: "gpt-oss-20b-GGUF")
                .standardizedFileURL)
    }

    func testResolveModelDirectory_rejectsWrongComponentCounts() {
        let root = makeRoot()
        for id in [
            "",
            "publisher",                                   // whole publisher, not a model
            "publisher/repo/file.gguf",                    // a file inside a model
            "a/b/c/d",
            "/publisher/repo",                             // leading empty component
            "publisher/repo/",                             // trailing empty component
            "publisher//repo",
        ] {
            XCTAssertNil(
                LMStudioModelsFolder.resolveModelDirectory(id: id, root: root),
                "id \"\(id)\" must not resolve")
        }
    }

    func testResolveModelDirectory_rejectsTraversal() {
        let root = makeRoot()
        for id in ["../etc", "publisher/..", "../../Users", "./publisher", "publisher/."] {
            XCTAssertNil(
                LMStudioModelsFolder.resolveModelDirectory(id: id, root: root),
                "id \"\(id)\" must not resolve")
        }
    }

    func testResolveModelDirectory_rejectsAbsolutePath() {
        XCTAssertNil(
            LMStudioModelsFolder.resolveModelDirectory(id: "/etc/passwd", root: makeRoot()))
    }

    /// A symlink planted inside the models root must not redirect the delete.
    /// Containment is re-checked on the resolved paths precisely for this.
    func testResolveModelDirectory_rejectsSymlinkEscapingTheRoot() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "nt-symlink-escape-\(UUID().uuidString)")
        let root = base.appending(path: "models")
        let outside = base.appending(path: "outside")
        try fm.createDirectory(at: root.appending(path: "publisher"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        try fm.createSymbolicLink(
            at: root.appending(path: "publisher").appending(path: "escape"), withDestinationURL: outside)

        XCTAssertNil(
            LMStudioModelsFolder.resolveModelDirectory(id: "publisher/escape", root: root),
            "A symlink pointing outside the models root must not resolve to a delete target")
    }

    /// The inverse: a models root that IS a symlink (models parked on an
    /// external drive is a common setup with 20 GB downloads) must keep working.
    func testResolveModelDirectory_symlinkedRootStillResolves() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "nt-symlink-root-\(UUID().uuidString)")
        let real = base.appending(path: "real-models")
        try fm.createDirectory(at: real.appending(path: "publisher").appending(path: "repo"),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let link = base.appending(path: "linked-models")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertNotNil(
            LMStudioModelsFolder.resolveModelDirectory(id: "publisher/repo", root: link),
            "A symlinked models root must still resolve its models")
    }

    // MARK: - resolveRoot

    func testResolveRoot_prefersConfiguredDownloadsFolder() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "nt-home-\(UUID().uuidString)")
        let custom = home.appending(path: "Elsewhere/Models")
        try fm.createDirectory(at: custom, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".lmstudio/models"),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let settings = #"{"downloadsFolder":"\#(custom.path)","other":1}"#
        try Data(settings.utf8).write(to: home.appending(path: ".lmstudio/settings.json"))

        XCTAssertEqual(
            LMStudioModelsFolder.resolveRoot(home: home, fileManager: fm)?.standardizedFileURL.path,
            custom.standardizedFileURL.path)
    }

    func testResolveRoot_fallsBackToDefaultWhenSettingsMissingOrUnusable() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "nt-home-\(UUID().uuidString)")
        let stock = home.appending(path: ".lmstudio/models")
        try fm.createDirectory(at: stock, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        // No settings file at all.
        XCTAssertEqual(
            LMStudioModelsFolder.resolveRoot(home: home, fileManager: fm)?.standardizedFileURL.path,
            stock.standardizedFileURL.path)

        // Present but unusable: malformed, empty value, and a path that doesn't exist.
        for body in [
            "not json",
            #"{"downloadsFolder":""}"#,
            #"{"downloadsFolder":"   "}"#,
            #"{"downloadsFolder":"/definitely/not/here/nanoteams"}"#,
            #"{"somethingElse":true}"#,
        ] {
            try Data(body.utf8).write(to: home.appending(path: ".lmstudio/settings.json"))
            XCTAssertEqual(
                LMStudioModelsFolder.resolveRoot(home: home, fileManager: fm)?.standardizedFileURL.path,
                stock.standardizedFileURL.path,
                "settings body \(body) should fall back to the stock folder")
        }
    }

    /// `downloadsFolder` is a plain string in someone else's settings file, and
    /// `/` is what a mangled value degrades into. Accepting it would list every
    /// `/<dir>/<subdir>` on the machine as a deletable "model".
    func testResolveRoot_rejectsFilesystemRootAndFallsBack() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "nt-home-\(UUID().uuidString)")
        let stock = home.appending(path: ".lmstudio/models")
        try fm.createDirectory(at: stock, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        for rootish in ["/", "/.", "//", "/./"] {
            try Data(#"{"downloadsFolder":"\#(rootish)"}"#.utf8)
                .write(to: home.appending(path: ".lmstudio/settings.json"))
            XCTAssertEqual(
                LMStudioModelsFolder.resolveRoot(home: home, fileManager: fm)?.standardizedFileURL.path,
                stock.standardizedFileURL.path,
                "downloadsFolder \"\(rootish)\" must be rejected, not used as the models root")
        }
    }

    func testResolveRoot_nilWhenNothingExists() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "nt-home-absent-\(UUID().uuidString)")
        XCTAssertNil(LMStudioModelsFolder.resolveRoot(home: home, fileManager: .default))
    }

    /// A `downloadsFolder` pointing at a FILE is not a models folder.
    func testResolveRoot_ignoresConfiguredPathThatIsAFile() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "nt-home-\(UUID().uuidString)")
        let stock = home.appending(path: ".lmstudio/models")
        try fm.createDirectory(at: stock, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let file = home.appending(path: "not-a-folder.txt")
        try Data("x".utf8).write(to: file)
        try Data(#"{"downloadsFolder":"\#(file.path)"}"#.utf8)
            .write(to: home.appending(path: ".lmstudio/settings.json"))

        XCTAssertEqual(
            LMStudioModelsFolder.resolveRoot(home: home, fileManager: fm)?.standardizedFileURL.path,
            stock.standardizedFileURL.path)
    }

    // MARK: - referenceHints

    func testReferenceHints_stripsGGUFSuffixAndIncludesBareRepo() {
        let hints = LMStudioModelsFolder.referenceHints(
            publisher: "unsloth", repoDir: "gpt-oss-20b-GGUF")
        XCTAssertTrue(hints.contains("unsloth/gpt-oss-20b-GGUF"))
        // LM Studio's own index maps that path to the key `unsloth/gpt-oss-20b`.
        XCTAssertTrue(hints.contains("unsloth/gpt-oss-20b"))
        XCTAssertTrue(hints.contains("gpt-oss-20b-GGUF"))
    }

    func testReferenceHints_keepsMLXSuffix() {
        let hints = LMStudioModelsFolder.referenceHints(
            publisher: "lmstudio-community", repoDir: "Qwen3.5-9B-MLX-4bit")
        XCTAssertTrue(hints.contains("lmstudio-community/Qwen3.5-9B-MLX-4bit"))
        XCTAssertFalse(
            hints.contains("lmstudio-community/Qwen3.5-9B"),
            "MLX keys keep their suffix — stripping it would invent a key LM Studio never uses")
    }

    func testReferenceHints_areDeduplicated() {
        let hints = LMStudioModelsFolder.referenceHints(publisher: "p", repoDir: "p")
        XCTAssertEqual(Set(hints).count, hints.count)
    }
}
