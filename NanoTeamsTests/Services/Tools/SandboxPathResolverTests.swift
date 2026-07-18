import XCTest
@testable import NanoTeams

/// Tests for SandboxPathResolver security validation
final class SandboxPathResolverTests: XCTestCase {

    private var tempProjectRoot: URL!
    private var resolver: SandboxPathResolver!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempProjectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempProjectRoot, withIntermediateDirectories: true)
        resolver = SandboxPathResolver(workFolderRoot: tempProjectRoot)
    }

    override func tearDownWithError() throws {
        if let tempProjectRoot {
            try? FileManager.default.removeItem(at: tempProjectRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Valid Paths

    func testResolveEmptyPath() throws {
        let url = try resolver.resolveFileURL(relativePath: "")
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    func testResolveNilPath() throws {
        let url = try resolver.resolveFileURL(relativePath: nil)
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    func testResolveSimpleFilename() throws {
        let url = try resolver.resolveFileURL(relativePath: "file.txt")
        let expected = tempProjectRoot.appendingPathComponent("file.txt").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolveNestedPath() throws {
        let url = try resolver.resolveFileURL(relativePath: "src/main/file.swift")
        let expected = tempProjectRoot
            .appendingPathComponent("src")
            .appendingPathComponent("main")
            .appendingPathComponent("file.swift")
            .standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolveDotPath() throws {
        let url = try resolver.resolveFileURL(relativePath: "./file.txt")
        let expected = tempProjectRoot.appendingPathComponent("file.txt").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolvePathWithWhitespace() throws {
        let url = try resolver.resolveFileURL(relativePath: "  file.txt  ")
        let expected = tempProjectRoot.appendingPathComponent("file.txt").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolvePathWithLeadingDot() throws {
        let url = try resolver.resolveFileURL(relativePath: ".hidden")
        let expected = tempProjectRoot.appendingPathComponent(".hidden").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolvePathWithMultipleDots() throws {
        // Current directory dots should be handled (./././file)
        let url = try resolver.resolveFileURL(relativePath: "././file.txt")
        let expected = tempProjectRoot.appendingPathComponent("file.txt").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolveDeepNestedPath() throws {
        let url = try resolver.resolveFileURL(relativePath: "a/b/c/d/e/f/g.txt")
        XCTAssertTrue(url.path.hasPrefix(tempProjectRoot.path))
        XCTAssertTrue(url.path.hasSuffix("a/b/c/d/e/f/g.txt"))
    }

    // MARK: - Invalid Paths - Absolute

    func testRejectAbsolutePath() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "/etc/passwd")) { error in
            guard let sandboxError = error as? SandboxPathError else {
                XCTFail("Expected SandboxPathError")
                return
            }
            if case .absolutePathNotAllowed(let path) = sandboxError {
                XCTAssertEqual(path, "/etc/passwd")
            } else {
                XCTFail("Expected absolutePathNotAllowed error")
            }
        }
    }

    func testRejectHomeTildePath() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "~/.ssh/id_rsa")) { error in
            guard let sandboxError = error as? SandboxPathError else {
                XCTFail("Expected SandboxPathError")
                return
            }
            if case .absolutePathNotAllowed(let path) = sandboxError {
                XCTAssertEqual(path, "~/.ssh/id_rsa")
            } else {
                XCTFail("Expected absolutePathNotAllowed error")
            }
        }
    }

    func testRejectTildeOnlyPath() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "~")) { error in
            guard case SandboxPathError.absolutePathNotAllowed = error else {
                XCTFail("Expected absolutePathNotAllowed error")
                return
            }
        }
    }

    // MARK: - Invalid Paths - Parent Traversal

    func testRejectParentTraversal() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "../secret.txt")) { error in
            guard let sandboxError = error as? SandboxPathError else {
                XCTFail("Expected SandboxPathError")
                return
            }
            if case .parentTraversalNotAllowed(let path) = sandboxError {
                XCTAssertEqual(path, "../secret.txt")
            } else {
                XCTFail("Expected parentTraversalNotAllowed error")
            }
        }
    }

    func testRejectHiddenParentTraversal() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "subdir/../../../etc/passwd")) { error in
            guard case SandboxPathError.parentTraversalNotAllowed = error else {
                XCTFail("Expected parentTraversalNotAllowed error")
                return
            }
        }
    }

    func testRejectParentTraversalInMiddle() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "a/b/../../../c")) { error in
            guard case SandboxPathError.parentTraversalNotAllowed = error else {
                XCTFail("Expected parentTraversalNotAllowed error")
                return
            }
        }
    }

    func testRejectParentTraversalAtEnd() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "subdir/..")) { error in
            guard case SandboxPathError.parentTraversalNotAllowed = error else {
                XCTFail("Expected parentTraversalNotAllowed error")
                return
            }
        }
    }

    func testRejectJustParentTraversal() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "..")) { error in
            guard case SandboxPathError.parentTraversalNotAllowed = error else {
                XCTFail("Expected parentTraversalNotAllowed error")
                return
            }
        }
    }

    // MARK: - Restricted Internal Paths

    func testRejectInternalPath_projectJSON() {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        XCTAssertThrowsError(
            try resolverWithInternal.resolveFileURL(relativePath: ".nanoteams/internal/project.json")
        ) { error in
            guard case SandboxPathError.restrictedPath = error else {
                XCTFail("Expected restrictedPath, got \(error)")
                return
            }
        }
    }

    func testRejectInternalPath_taskJSON() {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        XCTAssertThrowsError(
            try resolverWithInternal.resolveFileURL(
                relativePath: ".nanoteams/internal/tasks/ABC/task.json"
            )
        ) { error in
            guard case SandboxPathError.restrictedPath = error else {
                XCTFail("Expected restrictedPath, got \(error)")
                return
            }
        }
    }

    func testRejectInternalPath_networkLog() {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        XCTAssertThrowsError(
            try resolverWithInternal.resolveFileURL(
                relativePath: ".nanoteams/internal/runs/ABC/network_log.json"
            )
        ) { error in
            guard case SandboxPathError.restrictedPath = error else {
                XCTFail("Expected restrictedPath, got \(error)")
                return
            }
        }
    }

    func testRejectInternalPath_internalDirItself() {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        XCTAssertThrowsError(
            try resolverWithInternal.resolveFileURL(relativePath: ".nanoteams/internal")
        ) { error in
            guard case SandboxPathError.restrictedPath = error else {
                XCTFail("Expected restrictedPath, got \(error)")
                return
            }
        }
    }

    func testAllowAttachmentPath_withInternalDir() throws {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        let url = try resolverWithInternal.resolveFileURL(
            relativePath: ".nanoteams/tasks/ABC/attachments/file.png"
        )
        XCTAssertTrue(url.path.contains(".nanoteams/tasks/ABC/attachments/file.png"))
    }

    func testAllowArtifactPath_withInternalDir() throws {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        let url = try resolverWithInternal.resolveFileURL(
            relativePath: ".nanoteams/runs/ABC/steps/DEF/artifact_requirements.md"
        )
        XCTAssertTrue(url.path.contains("artifact_requirements.md"))
    }

    func testAllowRegularProjectFile_withInternalDir() throws {
        let internalDir = tempProjectRoot
            .appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolverWithInternal = SandboxPathResolver(
            workFolderRoot: tempProjectRoot, internalDir: internalDir
        )

        let url = try resolverWithInternal.resolveFileURL(relativePath: "Sources/main.swift")
        XCTAssertTrue(url.path.contains("Sources/main.swift"))
    }

    func testNoInternalDir_allowsAllNanoteamsPaths() throws {
        // Default resolver without internalDir should allow everything
        let url = try resolver.resolveFileURL(relativePath: ".nanoteams/internal/project.json")
        XCTAssertTrue(url.path.contains(".nanoteams/internal/project.json"))
    }

    // MARK: - Restricted Path Error Description

    func testRestrictedPathErrorDescription() {
        let error = SandboxPathError.restrictedPath
        XCTAssertEqual(error.errorDescription, "File not found.")
    }

    // MARK: - Error Descriptions

    func testEmptyPathErrorDescription() {
        let error = SandboxPathError.emptyPath
        XCTAssertEqual(error.errorDescription, "Path is empty.")
    }

    func testAbsolutePathErrorDescription() {
        let error = SandboxPathError.absolutePathNotAllowed("/etc/passwd")
        XCTAssertEqual(
            error.errorDescription,
            "Absolute paths are not allowed: /etc/passwd. Paths are relative to the work-folder root; use \".\" for the root.")
    }

    func testParentTraversalErrorDescription() {
        let error = SandboxPathError.parentTraversalNotAllowed("../secret")
        XCTAssertEqual(error.errorDescription, "Parent traversal (..) is not allowed: ../secret")
    }

    func testOutsideSandboxErrorDescription() {
        let error = SandboxPathError.outsideSandbox("escape")
        XCTAssertEqual(error.errorDescription, "Path resolves outside the selected work folder: escape")
    }

    // MARK: - Edge Cases

    func testResolvePathWithEmptyComponents() throws {
        // Multiple slashes should be handled
        let url = try resolver.resolveFileURL(relativePath: "src//file.txt")
        XCTAssertTrue(url.path.hasSuffix("src/file.txt"))
    }

    func testResolvePathWithOnlyWhitespace() throws {
        let url = try resolver.resolveFileURL(relativePath: "   ")
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    func testResolvePathWithNewlines() throws {
        let url = try resolver.resolveFileURL(relativePath: "\nfile.txt\n")
        let expected = tempProjectRoot.appendingPathComponent("file.txt").standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    // MARK: - Standardization

    func testProjectRootIsStandardized() {
        let nonStandardRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("./test/../test")
        let resolver = SandboxPathResolver(workFolderRoot: nonStandardRoot)

        // The workFolderRoot should be standardized
        XCTAssertFalse(resolver.workFolderRoot.path.contains(".."))
        XCTAssertFalse(resolver.workFolderRoot.path.contains("./"))
    }

    func testResolvedPathIsStandardized() throws {
        let url = try resolver.resolveFileURL(relativePath: "./subdir/./file.txt")
        XCTAssertFalse(url.path.contains("./"))
    }

    // MARK: - Absolute Paths Under Root (relativized)

    func testResolveAbsolutePathUnderRoot_succeeds() throws {
        let abs = tempProjectRoot.appendingPathComponent("src/engine/Game.js").path
        let url = try resolver.resolveFileURL(relativePath: abs)
        let expected = tempProjectRoot
            .appendingPathComponent("src")
            .appendingPathComponent("engine")
            .appendingPathComponent("Game.js")
            .standardizedFileURL
        XCTAssertEqual(url, expected)
    }

    func testResolveAbsolutePathEqualToRoot_returnsRoot() throws {
        let url = try resolver.resolveFileURL(relativePath: tempProjectRoot.path)
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    func testResolveAbsolutePathOutsideRoot_throwsAbsolutePathNotAllowed() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "/etc/hosts")) { error in
            guard case SandboxPathError.absolutePathNotAllowed(let p) = error else {
                XCTFail("Expected absolutePathNotAllowed, got \(error)"); return
            }
            XCTAssertEqual(p, "/etc/hosts")  // original raw string preserved
        }
    }

    func testAbsolutePathRelativizingIntoInternalDir_throwsRestrictedPath() throws {
        let internalDir = tempProjectRoot.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let r = SandboxPathResolver(workFolderRoot: tempProjectRoot, internalDir: internalDir)
        let abs = tempProjectRoot.appendingPathComponent(".nanoteams/internal/project.json").path
        XCTAssertThrowsError(try r.resolveFileURL(relativePath: abs)) { error in
            guard case SandboxPathError.restrictedPath = error else {
                XCTFail("Expected restrictedPath, got \(error)"); return
            }
        }
    }

    // MARK: - Chroot-Style Root ("/" means work-folder root)

    /// The reported bug: a model called `list_files(path: "/")` meaning the work-folder
    /// root (chroot mental model) and got PERMISSION_DENIED. Bare "/" can never be a
    /// legitimate outside target NOR a real work folder, so it resolves to the root —
    /// mirroring the existing ""/"."/"./" → root behavior.
    func testResolveBareSlash_returnsRoot() throws {
        let url = try resolver.resolveFileURL(relativePath: "/")
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    func testResolveDoubleSlash_returnsRoot() throws {
        let url = try resolver.resolveFileURL(relativePath: "//")
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    func testResolveSlashDot_returnsRoot() throws {
        XCTAssertEqual(try resolver.resolveFileURL(relativePath: "/."), tempProjectRoot.standardizedFileURL)
        XCTAssertEqual(try resolver.resolveFileURL(relativePath: "/./"), tempProjectRoot.standardizedFileURL)
    }

    func testResolveWhitespacePaddedSlash_returnsRoot() throws {
        let url = try resolver.resolveFileURL(relativePath: "  /  ")
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    /// "/.." standardizes to "/" (root's parent is root — chroot semantics), so it lands
    /// on the work-folder root too. Deliberate: consistent with the absolute-branch `..`
    /// asymmetry pinned by testResolveAbsolutePathWithDotDotInsideRoot_resolves. Note
    /// "/../x" standardizes to "/x" — NOT bare root — and still throws (pinned below by
    /// the outside-root tests).
    func testResolveSlashDotDot_returnsRoot() throws {
        let url = try resolver.resolveFileURL(relativePath: "/..")
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    /// THE BOUNDARY: `/../x` standardizes to `/x` (NOT bare root), so the chroot early
    /// return is skipped and it still throws `.absolutePathNotAllowed` with the raw string
    /// preserved. This is what separates "root" from "escape" — the guard the code comment
    /// claims. Without this pin, a future change to the `== "/"` check could silently start
    /// resolving `/../x` to `<root>/x`.
    func testResolveSlashDotDotThenContent_stillThrows() {
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "/../x")) { error in
            guard case SandboxPathError.absolutePathNotAllowed(let p) = error else {
                return XCTFail("Expected absolutePathNotAllowed, got \(error)")
            }
            XCTAssertEqual(p, "/../x")  // original raw string preserved
        }
    }

    /// The check is on the STANDARDIZED path, not the raw string: `/a/..` collapses to `/`
    /// lexically (root's parent is root), so a non-literal-`/` input that resolves there
    /// still lands on the work-folder root. Documents that `addressesFilesystemRoot(absURL)` —
    /// not `raw == "/"` — is the condition.
    func testResolveDotDotCollapsingToRoot_returnsRoot() throws {
        let url = try resolver.resolveFileURL(relativePath: "/a/..")
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    /// The chroot early return fires BEFORE the internalDir restriction check, but that's
    /// safe: the work-folder root is never inside `<root>/.nanoteams/internal`. Pins that
    /// `/` resolves to root even when an internalDir is configured (no false restrictedPath).
    func testResolveBareSlash_withInternalDir_returnsRootNotRestricted() throws {
        let internalDir = tempProjectRoot.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let r = SandboxPathResolver(workFolderRoot: tempProjectRoot, internalDir: internalDir)
        let url = try r.resolveFileURL(relativePath: "/")
        XCTAssertEqual(url, tempProjectRoot.standardizedFileURL)
    }

    // MARK: - Cross-Foundation Root Detection (macOS 15 runtime vs macOS 26 runtime)

    /// Every spelling that must mean "the work-folder root".
    private static let rootishSpellings = [
        "/", "//", "/.", "/./", "/./.", "//.", "/.//", "/..", "/../.", "/./..", "/a/..",
    ]

    /// Legacy CFURL-backed standardization — what macOS 15's Foundation does. Still reachable on
    /// macOS 26 through `NSURL`, which is what makes the CI runner's semantics testable locally.
    private func legacyStandardized(_ path: String) throws -> URL {
        try XCTUnwrap(NSURL(fileURLWithPath: path).standardizingPath as URL?)
    }

    /// THE CROSS-VERSION PIN. `URL.standardizedFileURL` is not the same function on every macOS:
    /// macOS 26's swift-foundation standardizes via RFC-3986 `remove_dot_segments` and strips a
    /// terminal `.`; macOS 15's CFURL-backed `URL` does not (swift-corelibs-foundation #3725 /
    /// SR-7289). So `/.` and `/./` arrive on macOS 15 as `["/", "."]`, the old `absURL.path == "/"`
    /// check missed, and the work-folder root was rejected with `absolutePathNotAllowed` — for
    /// every user on the deployment-target OS, and on CI (which runs `macos-15`).
    ///
    /// Asserting THROUGH `resolveFileURL` cannot catch this locally: it inherits whichever
    /// Foundation the host happens to ship. Driving the predicate with BOTH standardizers does.
    func testAddressesFilesystemRoot_agreesUnderLegacyAndModernStandardization() throws {
        for raw in Self.rootishSpellings {
            let modern = URL(fileURLWithPath: raw).standardizedFileURL
            let legacy = try legacyStandardized(raw)
            XCTAssertTrue(
                SandboxPathResolver.addressesFilesystemRoot(modern),
                "modern standardization of \(raw) → \(modern.pathComponents) must classify as root")
            XCTAssertTrue(
                SandboxPathResolver.addressesFilesystemRoot(legacy),
                "legacy standardization of \(raw) → \(legacy.pathComponents) must classify as root")
        }
    }

    /// The negative half — the boundary between "root" and "a real path" must hold under both
    /// standardizers too, otherwise tolerating a residual `.` would start swallowing real paths.
    /// `/../x` is the escape boundary; `/...` and `..foo` are ordinary filenames, not dot-segments.
    func testAddressesFilesystemRoot_negatives_underBothStandardizations() throws {
        let nonRoot = [
            "/../x", "/x", "/...", "/a/./b", "/etc/hosts",
            tempProjectRoot.path, tempProjectRoot.path + "/.", tempProjectRoot.path + "/..foo",
        ]
        for raw in nonRoot {
            let modern = URL(fileURLWithPath: raw).standardizedFileURL
            let legacy = try legacyStandardized(raw)
            XCTAssertFalse(
                SandboxPathResolver.addressesFilesystemRoot(modern),
                "modern standardization of \(raw) → \(modern.pathComponents) must NOT be root")
            XCTAssertFalse(
                SandboxPathResolver.addressesFilesystemRoot(legacy),
                "legacy standardization of \(raw) → \(legacy.pathComponents) must NOT be root")
        }
    }

    /// A terminal `.` on a NON-root path is not the root — it addresses that directory. Both
    /// Foundations agree here (`/a/.` → `/a`); pinned so a future widening of the root predicate
    /// cannot start collapsing real directories onto the work-folder root.
    func testResolveTrailingDotUnderRoot_resolvesToThatDirectory() throws {
        let src = tempProjectRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

        XCTAssertEqual(
            try resolver.resolveFileURL(relativePath: tempProjectRoot.path + "/."),
            tempProjectRoot.standardizedFileURL)
        XCTAssertEqual(
            try resolver.resolveFileURL(relativePath: tempProjectRoot.path + "/./src"),
            src.standardizedFileURL)
    }

    /// Why the tool-execution fallback sandbox root is a non-existent sentinel and never `/`
    /// (`LLMExecutionService+ToolExecution`): with `/` as the root, containment is universally
    /// true and every absolute path on the machine resolves — the sandbox stops being a sandbox.
    /// Pins the property, not the sentinel string.
    func testRootOfSlash_exposesWholeFilesystem_whileDeadSentinelRootDoesNot() throws {
        let wideOpen = SandboxPathResolver(workFolderRoot: URL(fileURLWithPath: "/"))
        XCTAssertEqual(try wideOpen.resolveFileURL(relativePath: "/etc/hosts").path, "/etc/hosts")

        let sentinel = SandboxPathResolver(
            workFolderRoot: URL(fileURLWithPath: "/dev/null/nanoteams-no-work-folder", isDirectory: true))
        XCTAssertThrowsError(try sentinel.resolveFileURL(relativePath: "/etc/hosts")) { error in
            guard case SandboxPathError.absolutePathNotAllowed = error else {
                return XCTFail("Expected absolutePathNotAllowed, got \(error)")
            }
        }
    }

    // MARK: - Tilde That Does Not Expand

    /// `expandingTildeInPath` returns the string UNCHANGED for an unknown user, so the expanded
    /// value is not absolute and `URL(fileURLWithPath:)` used to resolve it against the PROCESS
    /// working directory — making the verdict depend on where the app happens to be running, and
    /// accepting the path outright if the CWD sat inside the work folder. Pinned with the CWD
    /// deliberately moved inside the root: the one configuration where the old code could resolve.
    func testResolveUnknownTilde_throws_regardlessOfProcessWorkingDirectory() throws {
        let fm = FileManager.default
        let previousCWD = fm.currentDirectoryPath
        defer { fm.changeCurrentDirectoryPath(previousCWD) }

        for cwd in [tempProjectRoot.path, previousCWD] {
            XCTAssertTrue(fm.changeCurrentDirectoryPath(cwd), "could not chdir to \(cwd)")
            XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: "~nosuchuser999/x")) { error in
                guard case SandboxPathError.absolutePathNotAllowed(let p) = error else {
                    return XCTFail("Expected absolutePathNotAllowed, got \(error)")
                }
                XCTAssertEqual(p, "~nosuchuser999/x")  // original raw string preserved
            }
        }
    }

    // MARK: - Foundation-Owned Resolution (characterization — do NOT hand-roll these)

    /// macOS reports many paths in the `/private`-prefixed form (a shell's `pwd` under `/tmp`, for
    /// instance), so a model can legitimately paste one back. `standardizedFileURL` collapses that
    /// prefix only for paths that EXIST: an existing file resolves into the (already collapsed)
    /// root, while a not-yet-created one keeps `/private`, falls outside the root, and is rejected.
    ///
    /// CHARACTERIZATION of today's Foundation-owned behavior — the axis a hand-rolled dot-segment
    /// normalizer would silently break, and previously covered by no test at all. The same-named
    /// subdirectory is deliberate: without it the redundant-work-folder-name strip loop would mask
    /// a component-space offset and this test would pass even with the relativization broken.
    func testAbsolutePathWithPrivatePrefix_existingResolves_missingThrows() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("nt_private_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(
            at: root.appendingPathComponent(root.lastPathComponent, isDirectory: true),
            withIntermediateDirectories: true)

        let existing = root.appendingPathComponent("real.txt")
        try "x".write(to: existing, atomically: true, encoding: .utf8)
        let r = SandboxPathResolver(workFolderRoot: root)

        XCTAssertEqual(
            try r.resolveFileURL(relativePath: "/private" + existing.path),
            existing.standardizedFileURL)

        let missing = root.appendingPathComponent("missing.txt")
        XCTAssertThrowsError(try r.resolveFileURL(relativePath: "/private" + missing.path)) { error in
            guard case SandboxPathError.absolutePathNotAllowed = error else {
                return XCTFail("Expected absolutePathNotAllowed, got \(error)")
            }
        }
    }

    /// Foundation resolves SYMLINKS when (and only when) the path contains `..`, so a `..` that
    /// steps back out of a symlinked component lands where the link pointed — not where the
    /// lexical parent would be. `<root>/link/../<rootName>/real.txt` therefore comes back INSIDE
    /// the root, and `<root>/link/../<outsideName>/secret.txt` lands outside it and is rejected.
    ///
    /// CHARACTERIZATION: a lexical `..`-popping normalizer answers differently for BOTH of these,
    /// and re-standardizing afterwards cannot recover the difference. That is why the resolver
    /// keeps `.standardizedFileURL` and overrides only ROOT DETECTION.
    func testAbsolutePathThroughSymlinkAndDotDot_keepsFoundationSymlinkAwareResolution() throws {
        let fm = FileManager.default
        let base = tempProjectRoot.appendingPathComponent("symlink_case", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "r".write(to: root.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)
        try "s".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let r = SandboxPathResolver(workFolderRoot: root)

        XCTAssertEqual(
            try r.resolveFileURL(relativePath: root.path + "/link/../root/real.txt"),
            root.appendingPathComponent("real.txt").standardizedFileURL)

        XCTAssertThrowsError(
            try r.resolveFileURL(relativePath: root.path + "/link/../outside/secret.txt")
        ) { error in
            guard case SandboxPathError.absolutePathNotAllowed = error else {
                return XCTFail("Expected absolutePathNotAllowed, got \(error)")
            }
        }
    }

    // MARK: - Redundant Work-Folder-Name Prefix (existence-aware strip)

    /// The reported bug: work folder named `Survivors`, model passes `Survivors/src/...`.
    func testRedundantWorkFolderNamePrefix_stripped_whenSubdirMissing() throws {
        let named = tempProjectRoot.appendingPathComponent("Survivors", isDirectory: true)
        try FileManager.default.createDirectory(
            at: named.appendingPathComponent("src/engine"), withIntermediateDirectories: true)
        let r = SandboxPathResolver(workFolderRoot: named)
        let url = try r.resolveFileURL(relativePath: "Survivors/src/engine/Game.js")
        XCTAssertEqual(url, named.appendingPathComponent("src/engine/Game.js").standardizedFileURL)
    }

    func testRedundantPrefix_caseInsensitiveMatch_stripped() throws {
        let named = tempProjectRoot.appendingPathComponent("Survivors", isDirectory: true)
        try FileManager.default.createDirectory(
            at: named.appendingPathComponent("src"), withIntermediateDirectories: true)
        let r = SandboxPathResolver(workFolderRoot: named)
        let url = try r.resolveFileURL(relativePath: "survivors/src/x.js")
        XCTAssertEqual(url, named.appendingPathComponent("src/x.js").standardizedFileURL)
    }

    /// A genuine same-named subdirectory that EXISTS wins over the strip.
    func testGenuineSameNamedSubdir_isNotStripped_whenExists() throws {
        let named = tempProjectRoot.appendingPathComponent("Survivors", isDirectory: true)
        let subdir = named.appendingPathComponent("Survivors", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "x".write(to: subdir.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        let r = SandboxPathResolver(workFolderRoot: named)
        let url = try r.resolveFileURL(relativePath: "Survivors/keep.txt")
        XCTAssertEqual(url, subdir.appendingPathComponent("keep.txt").standardizedFileURL)
    }

    /// New-file write under a redundant prefix (nothing exists) → stripped.
    func testNewFileUnderRedundantPrefix_strips() throws {
        let named = tempProjectRoot.appendingPathComponent("Survivors", isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        let r = SandboxPathResolver(workFolderRoot: named)
        let url = try r.resolveFileURL(relativePath: "Survivors/new/output.txt")
        XCTAssertEqual(url, named.appendingPathComponent("new/output.txt").standardizedFileURL)
    }

    /// The directory-existence fix: a NEW file into a real same-named subdir is NOT stripped,
    /// even though the file itself doesn't exist yet (full-path existence would have stripped it).
    func testNewFileIntoGenuineSameNamedSubdir_isNotStripped() throws {
        let named = tempProjectRoot.appendingPathComponent("app", isDirectory: true)
        let subdir = named.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let r = SandboxPathResolver(workFolderRoot: named)
        let url = try r.resolveFileURL(relativePath: "app/new/Button.tsx")
        XCTAssertEqual(url, subdir.appendingPathComponent("new/Button.tsx").standardizedFileURL)
    }

    // MARK: - relativizePathspec (git best-effort normalization)

    func testRelativizePathspec_redundantPrefix_relativized() throws {
        let named = tempProjectRoot.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: named.appendingPathComponent("src"), withIntermediateDirectories: true)
        let r = SandboxPathResolver(workFolderRoot: named)
        XCTAssertEqual(r.relativizePathspec("repo/src/main.swift"), "src/main.swift")
    }

    func testRelativizePathspec_absoluteUnderRoot_relativized() {
        let abs = tempProjectRoot.appendingPathComponent("a/b.txt").path
        XCTAssertEqual(resolver.relativizePathspec(abs), "a/b.txt")
    }

    func testRelativizePathspec_glob_unchanged() {
        XCTAssertEqual(resolver.relativizePathspec("*.swift"), "*.swift")
        XCTAssertEqual(resolver.relativizePathspec("src/**/*.ts"), "src/**/*.ts")
    }

    func testRelativizePathspec_magic_unchanged() {
        XCTAssertEqual(resolver.relativizePathspec(":(exclude)foo"), ":(exclude)foo")
    }

    func testRelativizePathspec_plainRelative_unchanged() {
        XCTAssertEqual(resolver.relativizePathspec("src/x.js"), "src/x.js")
    }

    func testRelativizePathspec_escape_returnsRaw() {
        XCTAssertEqual(resolver.relativizePathspec("../x"), "../x")
    }

    func testRelativizePathspec_bareWorkspaceName_unchanged() {
        let name = resolver.workFolderRoot.lastPathComponent
        XCTAssertEqual(resolver.relativizePathspec(name), name)
    }

    // MARK: - Corner Cases: Absolute Path Arithmetic

    /// Absolute path containing `..` that standardizes back INSIDE the root resolves
    /// (the absolute branch standardizes before the boundary check) — unlike a RELATIVE
    /// `..` which is rejected outright. Pins that intentional asymmetry.
    func testResolveAbsolutePathWithDotDotInsideRoot_resolves() throws {
        let raw = tempProjectRoot.path + "/src/../lib/x.js"
        let url = try resolver.resolveFileURL(relativePath: raw)
        XCTAssertEqual(url, tempProjectRoot.appendingPathComponent("lib/x.js").standardizedFileURL)
    }

    /// Absolute path with `..` that escapes the root after standardization is rejected,
    /// with the ORIGINAL raw string preserved — `..` can't be smuggled via the absolute branch.
    func testResolveAbsolutePathWithDotDotEscaping_throwsAbsolutePathNotAllowed() {
        let raw = tempProjectRoot.path + "/../sibling/secret.txt"
        XCTAssertThrowsError(try resolver.resolveFileURL(relativePath: raw)) { error in
            guard case SandboxPathError.absolutePathNotAllowed(let p) = error else {
                return XCTFail("Expected absolutePathNotAllowed, got \(error)")
            }
            XCTAssertEqual(p, raw)
        }
    }

    func testResolveAbsolutePathWithDoubleSlashesAndTrailing_normalizes() throws {
        let absDouble = tempProjectRoot.path + "//src///x.js"
        XCTAssertEqual(
            try resolver.resolveFileURL(relativePath: absDouble),
            tempProjectRoot.appendingPathComponent("src/x.js").standardizedFileURL)

        let absTrailing = tempProjectRoot.appendingPathComponent("src").path + "/"
        XCTAssertEqual(
            try resolver.resolveFileURL(relativePath: absTrailing),
            tempProjectRoot.appendingPathComponent("src").standardizedFileURL)
    }

    // MARK: - Corner Cases: Redundant Prefix (loop + existence gate)

    /// A DOUBLED prefix (`Foo/Foo/src`) strips BOTH leading components when no `Foo` subdir
    /// exists — the strip loops. Without looping only one would be removed.
    func testDoubleRedundantPrefix_stripsAllLeading_whenNoSubdir() throws {
        let named = tempProjectRoot.appendingPathComponent("Foo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: named.appendingPathComponent("src"), withIntermediateDirectories: true)
        let r = SandboxPathResolver(workFolderRoot: named)
        XCTAssertEqual(
            try r.resolveFileURL(relativePath: "Foo/Foo/src/x.js"),
            named.appendingPathComponent("src/x.js").standardizedFileURL)
    }

    /// When a genuine same-named subdir exists, the loop breaks on the first iteration and
    /// keeps the whole path (the model's nested `Foo/Foo/...` is honored).
    func testDoubleRedundantPrefix_keptWhenSubdirExists() throws {
        let named = tempProjectRoot.appendingPathComponent("Foo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: named.appendingPathComponent("Foo"), withIntermediateDirectories: true)
        let r = SandboxPathResolver(workFolderRoot: named)
        XCTAssertEqual(
            try r.resolveFileURL(relativePath: "Foo/Foo/x.js"),
            named.appendingPathComponent("Foo/Foo/x.js").standardizedFileURL)
    }

    func testRedundantPrefixTrailingSlash_resolvesToRoot() throws {
        let named = tempProjectRoot.appendingPathComponent("Foo", isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        XCTAssertEqual(try r(named).resolveFileURL(relativePath: "Foo/"), named.standardizedFileURL)
    }

    /// Regression pin for the removed bare-name shortcut: bare work-folder name → root.
    func testBareRedundantName_resolvesToRoot_whenNoSubdir() throws {
        let named = tempProjectRoot.appendingPathComponent("Survivors", isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        XCTAssertEqual(try r(named).resolveFileURL(relativePath: "Survivors"), named.standardizedFileURL)
    }

    /// Bare name with a genuine same-named subdir resolves to the subdir (existence gate
    /// flips the bare-name case too, not just multi-component).
    func testBareName_resolvesToSubdir_whenSameNamedSubdirExists() throws {
        let named = tempProjectRoot.appendingPathComponent("app", isDirectory: true)
        let subdir = named.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        XCTAssertEqual(try r(named).resolveFileURL(relativePath: "app"), subdir.standardizedFileURL)
    }

    /// A same-named regular FILE (not directory) does NOT block the strip — pins the isDir gate.
    func testRedundantPrefix_sameNamedFileNotDirectory_isStripped() throws {
        let named = tempProjectRoot.appendingPathComponent("Foo", isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        try "x".write(to: named.appendingPathComponent("Foo"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try r(named).resolveFileURL(relativePath: "Foo/bar.txt"),
            named.appendingPathComponent("bar.txt").standardizedFileURL)
    }

    /// A same-named DANGLING SYMLINK is a real named entity → NOT stripped. `fileExists`
    /// follows the link and reports false, which would otherwise silently redirect
    /// `Foo/bar.txt` to `<root>/bar.txt`; keeping it instead fails loudly downstream
    /// (not-found), the safer mode. Pins the symlink branch of the strip gate.
    func testRedundantPrefix_sameNamedDanglingSymlink_isNotStripped() throws {
        let named = tempProjectRoot.appendingPathComponent("Foo", isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: named.appendingPathComponent("Foo"),
            withDestinationURL: named.appendingPathComponent("nonexistent-target"))
        XCTAssertEqual(
            try r(named).resolveFileURL(relativePath: "Foo/bar.txt"),
            named.appendingPathComponent("Foo/bar.txt").standardizedFileURL)
    }

    // MARK: - Corner Cases: relativizePathspec decision table

    func testRelativizePathspec_emptyAndWhitespace_returnsRaw() {
        XCTAssertEqual(resolver.relativizePathspec(""), "")
        XCTAssertEqual(resolver.relativizePathspec("   "), "   ")
    }

    /// `:` is treated as pathspec magic only at position 0; elsewhere it's an ordinary
    /// filename char that round-trips losslessly.
    func testRelativizePathspec_colonNotAtStart_roundTripsIdentity() {
        XCTAssertEqual(resolver.relativizePathspec("src:lib"), "src:lib")
    }

    /// Glob heuristic is `{*, ?, [}` only: `[` triggers raw passthrough; `]` alone does not.
    func testRelativizePathspec_bracketHeuristic_asymmetric() {
        XCTAssertEqual(resolver.relativizePathspec("src/[abc"), "src/[abc")
        XCTAssertEqual(resolver.relativizePathspec("a]b.txt"), "a]b.txt")
    }

    /// A pathspec resolving into `.nanoteams/internal` throws restrictedPath inside the
    /// resolver → swallowed → raw handed back to git.
    func testRelativizePathspec_internalDirPath_returnsRaw() {
        let internalDir = tempProjectRoot.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let withInternal = SandboxPathResolver(workFolderRoot: tempProjectRoot, internalDir: internalDir)
        XCTAssertEqual(
            withInternal.relativizePathspec(".nanoteams/internal/workfolder.json"),
            ".nanoteams/internal/workfolder.json")
    }

    func testRelativizePathspec_absoluteOutsideRoot_returnsRaw() {
        XCTAssertEqual(resolver.relativizePathspec("/etc/passwd"), "/etc/passwd")
    }

    /// Bare "/" now resolves to the work-folder root, whose relative form is empty →
    /// the bare-root guard returns the raw pathspec unchanged (no over-broadening to ".").
    func testRelativizePathspec_bareSlash_returnsRaw() {
        XCTAssertEqual(resolver.relativizePathspec("/"), "/")
    }

    /// Root-standardizing variant `//` also relativizes to empty → raw handed back
    /// verbatim (same bare-root guard as "/"), never broadened to ".".
    func testRelativizePathspec_doubleSlash_returnsRaw() {
        XCTAssertEqual(resolver.relativizePathspec("//"), "//")
    }

    /// `/.` is the spelling macOS 15's Foundation leaves as `["/", "."]` — it must reach the same
    /// bare-root guard as "/" and "//" rather than falling through the `try?` as unresolvable.
    func testRelativizePathspec_slashDot_returnsRaw() {
        XCTAssertEqual(resolver.relativizePathspec("/."), "/.")
    }

    /// Redundant prefix that resolves to bare root → empty relative → returns raw (don't
    /// over-broaden a bare-name pathspec to `.`).
    func testRelativizePathspec_bareRootViaRedundantPrefix_returnsRaw() throws {
        let named = tempProjectRoot.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        XCTAssertEqual(r(named).relativizePathspec("repo"), "repo")
    }

    func testRelativizePathspec_absoluteEqualToRoot_returnsRaw() {
        XCTAssertEqual(resolver.relativizePathspec(tempProjectRoot.path), tempProjectRoot.path)
    }

    // MARK: - Helpers

    private func r(_ root: URL) -> SandboxPathResolver { SandboxPathResolver(workFolderRoot: root) }
}
