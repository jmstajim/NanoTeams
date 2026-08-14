import XCTest

@testable import NanoTeams

/// The failure ladder inside `AtomicJSONStore.write` — what it does when the filesystem refuses.
///
/// This matters more than its size suggests: this store persists `task.json`, `teams.json` and
/// `workfolder.json`, so its error surface is the only thing between a failed disk write and
/// silent data loss. The rung that must never be skipped is the last one — when the atomic
/// replace, the fallback move AND the cleanup all fail, the caller still has to receive the
/// PRIMARY error, or it will believe the write landed.
///
/// Reaching those rungs needs a real refusal, not a mock: `replaceItemAt` is declared in an
/// extension of `FileManager` and therefore cannot be overridden. Measured on APFS/macOS 26, it
/// SUCCEEDS against a missing target and even against a non-empty directory — so the trigger
/// these tests use is a read-only target FILE inside a still-writable directory, which is also
/// the only refusal the fallback can actually rescue.
final class AtomicJSONStoreInjectedFailureTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            // Restore write permission first or the recursive remove fails on the fixtures.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: tempDir.appendingPathComponent(entry).path)
            }
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    private struct Model: Codable, Equatable { var value: Int }

    private struct Refused: Error {}

    /// A real `FileManager` with individual operations switched off. Everything not switched off
    /// behaves normally, so the temp file is genuinely written and the cleanup assertions are
    /// about real files on disk. `replaceItemAt` is absent on purpose — it is unoverridable, and
    /// the tests trigger it through the filesystem instead.
    private final class FailingFileManager: FileManager, @unchecked Sendable {
        var failCreateDirectory = false
        var failMoveItem = false
        /// Fail `removeItem` only for paths with this suffix, so a test can let the fallback's
        /// remove-the-old-target succeed while making the temp-file cleanup fail.
        var failRemoveItemWithSuffix: String?
        private(set) var removedPaths: [String] = []

        override func createDirectory(
            at url: URL, withIntermediateDirectories createIntermediates: Bool,
            attributes: [FileAttributeKey: Any]? = nil
        ) throws {
            if failCreateDirectory { throw Refused() }
            try super.createDirectory(
                at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }

        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if failMoveItem { throw Refused() }
            try super.moveItem(at: srcURL, to: dstURL)
        }

        override func removeItem(at URL: URL) throws {
            removedPaths.append(URL.lastPathComponent)
            if let suffix = failRemoveItemWithSuffix, URL.lastPathComponent.hasSuffix(suffix) {
                throw Refused()
            }
            try super.removeItem(at: URL)
        }
    }

    private func tempSideFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [])
            .filter { $0.hasSuffix(".tmp") }
    }

    /// Writes `data.json` and makes it unwritable — `replaceItemAt` then refuses (measured:
    /// NSCocoaErrorDomain 513) while the parent directory stays writable, so the fallback can
    /// still remove it and move the temp into place.
    private func makeReadOnlyTarget() throws -> URL {
        let url = tempDir.appendingPathComponent("data.json")
        try AtomicJSONStore().write(Model(value: 1), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Rung 1: the directory can't be created

    /// The raw error is deliberately NOT propagated: the caller needs the PATH it failed on,
    /// which a bare POSIX error doesn't carry. This is the one rung where the store knows
    /// something the underlying error doesn't.
    func testCreateDirectoryFails_throwsUnableToCreateDirectoryNamingThePath() {
        let fm = FailingFileManager()
        fm.failCreateDirectory = true
        let url = tempDir.appendingPathComponent("nested/deep/data.json")

        XCTAssertThrowsError(try AtomicJSONStore(fileManager: fm).write(Model(value: 1), to: url)) { error in
            guard case AtomicJSONStoreError.unableToCreateDirectory(let dir) = error else {
                return XCTFail("expected .unableToCreateDirectory, got \(error)")
            }
            XCTAssertEqual(dir.lastPathComponent, "deep")
            XCTAssertTrue(
                error.localizedDescription.contains("deep"),
                "the message must name the path that failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Rung 2: atomic replace refuses, the move rescues it

    /// A rescued write must actually land. A fallback that "succeeded" while leaving the old
    /// bytes — or an empty file — in place would be worse than throwing.
    func testReplaceRefused_fallbackMoveCompletesTheWriteWithTheNewBytes() throws {
        let url = try makeReadOnlyTarget()

        try AtomicJSONStore().write(Model(value: 42), to: url)

        XCTAssertEqual(try AtomicJSONStore().read(Model.self, from: url), Model(value: 42))
        XCTAssertEqual(tempSideFiles(), [], "the temp file was consumed by the move")
    }

    /// The old target has to be removed before the move — `moveItem` refuses to overwrite. Miss
    /// that and the fallback fails on every target that already exists, i.e. on every save after
    /// the first.
    func testReplaceRefused_removesTheOldTargetBeforeMoving() throws {
        let url = try makeReadOnlyTarget()
        let fm = FailingFileManager()

        try AtomicJSONStore(fileManager: fm).write(Model(value: 42), to: url)

        XCTAssertEqual(fm.removedPaths, ["data.json"])
    }

    // MARK: - Rung 3: the move fails too

    func testReplaceAndMoveBothFail_throwsAtomicReplaceFailedNamingTheFile() throws {
        let url = try makeReadOnlyTarget()
        let fm = FailingFileManager()
        fm.failMoveItem = true

        XCTAssertThrowsError(try AtomicJSONStore(fileManager: fm).write(Model(value: 2), to: url)) { error in
            guard case AtomicJSONStoreError.atomicReplaceFailed(let failedURL, _) = error else {
                return XCTFail("expected .atomicReplaceFailed, got \(error)")
            }
            XCTAssertEqual(failedURL.lastPathComponent, "data.json")
            XCTAssertTrue(error.localizedDescription.contains("data.json"),
                          "got: \(error.localizedDescription)")
        }
    }

    /// A failed write must not leave a temp file behind: these directories are swept at bootstrap
    /// and an orphan there is indistinguishable from real state.
    func testReplaceAndMoveBothFail_cleansUpTheTempFile() throws {
        let url = try makeReadOnlyTarget()
        let fm = FailingFileManager()
        fm.failMoveItem = true

        _ = try? AtomicJSONStore(fileManager: fm).write(Model(value: 2), to: url)

        XCTAssertEqual(tempSideFiles(), [])
    }

    /// The last rung. When cleanup ALSO fails, the store must still throw the primary error —
    /// losing "your save failed" behind "and I couldn't tidy up afterwards" would let a caller
    /// believe the write landed. The orphan is reaped at next launch by the bootstrap sweep,
    /// which is why it is only logged.
    func testEvenWhenCleanupFails_thePrimaryErrorStillReachesTheCaller() throws {
        let url = try makeReadOnlyTarget()
        let fm = FailingFileManager()
        fm.failMoveItem = true
        fm.failRemoveItemWithSuffix = ".tmp"

        XCTAssertThrowsError(try AtomicJSONStore(fileManager: fm).write(Model(value: 2), to: url)) { error in
            guard case AtomicJSONStoreError.atomicReplaceFailed = error else {
                return XCTFail("the cleanup failure must not displace the primary error: \(error)")
            }
        }
        XCTAssertEqual(fm.removedPaths.filter { $0.hasSuffix(".tmp") }.count, 1,
                       "cleanup was attempted exactly once")
    }

    // MARK: - Anti-vacuity

    /// Without this, every test above passes against a store that never writes anything — and in
    /// particular against a `FailingFileManager` broken by a future edit.
    func testUnmodifiedFailingFileManager_writesNormally() throws {
        let url = tempDir.appendingPathComponent("plain.json")

        try AtomicJSONStore(fileManager: FailingFileManager()).write(Model(value: 9), to: url)

        XCTAssertEqual(try AtomicJSONStore().read(Model.self, from: url), Model(value: 9))
    }

    /// Pins the measurement the fallback's reachability rests on: a MISSING target is not a
    /// refusal. If a future macOS changes that, this fails and the comment above the fallback
    /// needs revisiting rather than silently describing the wrong trigger again.
    func testReplaceAgainstAMissingTarget_succeedsAndNeedsNoFallback() throws {
        let url = tempDir.appendingPathComponent("fresh.json")
        let fm = FailingFileManager()
        fm.failMoveItem = true   // the fallback would fail loudly if it were taken

        try AtomicJSONStore(fileManager: fm).write(Model(value: 5), to: url)

        XCTAssertEqual(try AtomicJSONStore().read(Model.self, from: url), Model(value: 5))
        XCTAssertTrue(fm.removedPaths.isEmpty, "no fallback was needed")
    }
}
