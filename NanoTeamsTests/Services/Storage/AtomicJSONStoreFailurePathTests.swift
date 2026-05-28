import XCTest
@testable import NanoTeams

/// Tests covering `AtomicJSONStore` failure + edge paths that the main test
/// file doesn't reach: orphaned temp-file cleanup, `writeIfMissing` atomicity
/// across existing/missing targets, verification that no `.tmp` side-files
/// linger in the target directory after a successful write, and concurrent-write
/// safety. The write path uses `dir/.<filename>.<uuid>.tmp` + `replaceItemAt`
/// (per-call UUID so concurrent writers to the same target don't clobber each
/// other's temp file).
final class AtomicJSONStoreFailurePathTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var store: AtomicJSONStore!

    /// Returns all `.tmp` side-files for a given target name in `dir`. Matches
    /// `.<filename>.<anything>.tmp` so the asserts work against the unique-per-call
    /// temp-filename scheme — a literal `.<filename>.tmp` check would vacuously
    /// pass since that exact name is never written.
    private func tempSideFiles(for targetURL: URL, in dir: URL) -> [String] {
        let prefix = "." + targetURL.lastPathComponent + "."
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".tmp") }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = AtomicJSONStore()
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private struct Model: Codable, Equatable {
        var value: Int
    }

    // MARK: - Temp-file hygiene

    /// After a successful write no `.<name>.<uuid>.tmp` side-file must linger in
    /// the target directory. Regression against implementations that forget
    /// to remove or atomically replace the temp file.
    func testWrite_success_leavesNoTempFile() throws {
        let url = tempDir.appendingPathComponent("data.json")
        try store.write(Model(value: 1), to: url)

        XCTAssertEqual(tempSideFiles(for: url, in: tempDir), [],
                       "No `.<name>.*.tmp` side-files must remain after successful atomic replace")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// Three sequential writes to the same URL must leave no `.tmp` side-files.
    /// With unique per-call temp names, leftovers would accumulate without bound
    /// if `replaceItemAt`/`moveItem` failed to consume them.
    func testWrite_sequentialSameURL_noTempFileBuildup() throws {
        let url = tempDir.appendingPathComponent("data.json")
        try store.write(Model(value: 1), to: url)
        try store.write(Model(value: 2), to: url)
        try store.write(Model(value: 3), to: url)

        XCTAssertEqual(tempSideFiles(for: url, in: tempDir), [],
                       "No `.<name>.*.tmp` side-files must remain after sequential writes")
        XCTAssertEqual(try store.read(Model.self, from: url).value, 3)
    }

    // MARK: - writeIfMissing

    func testWriteIfMissing_createsWhenAbsent_valueEqualsProvided() throws {
        let url = tempDir.appendingPathComponent("missing.json")
        try store.writeIfMissing(Model(value: 42), to: url)

        let loaded = try store.read(Model.self, from: url)
        XCTAssertEqual(loaded.value, 42)
    }

    func testWriteIfMissing_preservesExistingFileContent() throws {
        let url = tempDir.appendingPathComponent("existing.json")
        try store.write(Model(value: 100), to: url)

        // Even though the new value differs, existing file must be preserved.
        try store.writeIfMissing(Model(value: 999), to: url)

        let loaded = try store.read(Model.self, from: url)
        XCTAssertEqual(loaded.value, 100,
                       "writeIfMissing must be a no-op when the target already exists")
    }

    func testWriteIfMissing_doesNotCreateTempSideFile_whenTargetExists() throws {
        let url = tempDir.appendingPathComponent("existing.json")
        try store.write(Model(value: 1), to: url)
        try store.writeIfMissing(Model(value: 2), to: url)

        XCTAssertEqual(tempSideFiles(for: url, in: tempDir), [],
                       "writeIfMissing on existing target must not open/create any `.<name>.*.tmp` file")
    }

    // MARK: - Intermediate directory creation

    func testWrite_createsDeeplyNestedIntermediateDirectories() throws {
        let url = tempDir
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("c", isDirectory: true)
            .appendingPathComponent("deep.json")

        try store.write(Model(value: 7), to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Encode failure propagation

    /// Non-encodable values throw `EncodingError`, NOT a wrapped
    /// `AtomicJSONStoreError`. The store must not swallow encode errors.
    func testWrite_nonEncodableValue_propagatesEncodingError() {
        struct BadModel: Encodable {
            func encode(to encoder: Encoder) throws {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(codingPath: [], debugDescription: "forced failure")
                )
            }
        }

        let url = tempDir.appendingPathComponent("bad.json")
        XCTAssertThrowsError(try store.write(BadModel(), to: url)) { error in
            XCTAssertTrue(error is EncodingError,
                          "Encode failures must propagate raw, not be wrapped in AtomicJSONStoreError")
        }
        // No file should have been created for a failed encode.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Failed encode must not leave a partial target file")
    }

    /// When encode fails, no `.<name>.*.tmp` file must be left on disk.
    /// (Encode happens BEFORE temp-file write in the current implementation,
    /// so this is a spec assertion — if the order ever reverses, we'd leak.)
    func testWrite_encodeFailure_leavesNoTempFile() {
        struct BadModel: Encodable {
            func encode(to encoder: Encoder) throws {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(codingPath: [], debugDescription: "forced")
                )
            }
        }

        let url = tempDir.appendingPathComponent("bad.json")
        _ = try? store.write(BadModel(), to: url)

        XCTAssertEqual(tempSideFiles(for: url, in: tempDir), [],
                       "Failed encode path must not leak any `.<name>.*.tmp` side-file")
    }

    // MARK: - Replace semantics

    /// Overwriting must keep the same inode path visible (no orphan files
    /// with `.tmp` suffix in the same directory).
    func testWrite_overwrite_onlyOneJSONFileRemains() throws {
        let url = tempDir.appendingPathComponent("one.json")
        try store.write(Model(value: 1), to: url)
        try store.write(Model(value: 2), to: url)

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        let jsonLike = Set(entries.filter { $0.hasSuffix(".json") || $0.hasSuffix(".tmp") })
        XCTAssertEqual(jsonLike, Set(["one.json"]),
                       "After overwrite only the target file must remain; got \(jsonLike)")
    }

    // MARK: - Concurrent writes

    /// Concurrent writes to the same URL must all succeed, none must hang or
    /// throw, the final file must decode to one of the inputs (last-write-wins
    /// is non-deterministic but consistent), and no `.tmp` side-files must
    /// linger. Pre-fix (shared `.{name}.tmp` temp filename) this would race:
    /// some writers' `replaceItemAt` would find the temp consumed and fail
    /// with `atomicReplaceFailed`, dropping their data. Per-call UUID temp
    /// names eliminate the race.
    func testWrite_concurrent_sameURL_allSucceed() async throws {
        let url = tempDir.appendingPathComponent("contended.json")
        let writerCount = 20

        // Capture `self` (test class is `@unchecked Sendable`) and access
        // `self.store` inside each task body. Pulling a local
        // `let store = self.store!` above the group would trip Swift 6's
        // sending-closure check because `AtomicJSONStore` itself is not
        // declared Sendable; routing through `@unchecked Sendable` self
        // sidesteps that without weakening the struct's contract — same
        // pattern as `AtomicJSONStoreTests.testConcurrentWrites`.
        let outcomes = await withTaskGroup(of: Result<Int, Error>.self, returning: [Result<Int, Error>].self) { [self] group in
            for value in 0..<writerCount {
                group.addTask { [self] in
                    do {
                        try self.store.write(Model(value: value), to: url)
                        return .success(value)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<Int, Error>] = []
            for await result in group { collected.append(result) }
            return collected
        }

        let failures = outcomes.compactMap { result -> Error? in
            if case .failure(let error) = result { return error } else { return nil }
        }
        XCTAssertTrue(failures.isEmpty,
                      "All \(writerCount) concurrent writes must succeed; got failures: \(failures)")

        let final = try store.read(Model.self, from: url)
        XCTAssertTrue((0..<writerCount).contains(final.value),
                      "Final file must decode to one of the inputs (got \(final.value))")

        XCTAssertEqual(tempSideFiles(for: url, in: tempDir), [],
                       "No `.<name>.*.tmp` side-files must linger after concurrent writes")
    }
}
