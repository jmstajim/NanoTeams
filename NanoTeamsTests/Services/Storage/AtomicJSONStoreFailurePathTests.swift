import XCTest
@testable import NanoTeams

/// Tests covering `AtomicJSONStore` failure + edge paths that the main test
/// file doesn't reach: orphaned temp-file cleanup, `writeIfMissing` atomicity
/// across existing/missing targets, and verification that the `.tmp`
/// side-file is never left behind in the target directory after a successful
/// write (important because the write path uses
/// `dir/.<filename>.tmp` + `replaceItemAt`).
final class AtomicJSONStoreFailurePathTests: XCTestCase {

    private var tempDir: URL!
    private var store: AtomicJSONStore!

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

    /// After a successful write the `.<name>.tmp` side-file must not linger in
    /// the target directory. Regression against implementations that forget
    /// to remove or atomically replace the temp file.
    func testWrite_success_leavesNoTempFile() throws {
        let url = tempDir.appendingPathComponent("data.json")
        try store.write(Model(value: 1), to: url)

        let tempURL = tempDir.appendingPathComponent(".data.json.tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "`.<name>.tmp` must not remain after successful atomic replace")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// Two sequential writes to the same URL must not accumulate `.tmp` files
    /// (each write uses the same temp name — if the first write's temp
    /// survived, the second would conflict).
    func testWrite_sequentialSameURL_noTempFileBuildup() throws {
        let url = tempDir.appendingPathComponent("data.json")
        try store.write(Model(value: 1), to: url)
        try store.write(Model(value: 2), to: url)
        try store.write(Model(value: 3), to: url)

        let tempURL = tempDir.appendingPathComponent(".data.json.tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
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

        let tempURL = tempDir.appendingPathComponent(".existing.json.tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "writeIfMissing on existing target must not open/create any .tmp file")
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

    /// When encode fails, the `.tmp` file must also NOT be left on disk.
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

        let tempURL = tempDir.appendingPathComponent(".bad.json.tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "Failed encode path must not leak a .tmp side-file")
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
}
