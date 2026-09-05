import Foundation

/// What an atomic temp-and-replace write changes even when it lands byte-identical content:
/// `AtomicJSONStore.write` stages a temp file and `replaceItemAt` swaps it in, so the target
/// gets a NEW inode and a new mtime whether or not a single byte differs.
///
/// That is the assertion a "must not rewrite the file" test needs. A byte compare cannot make
/// it: the persistence encoder is deterministic (`.sortedKeys`, `.prettyPrinted`, ISO-8601
/// dates — `JSONCoderFactory`), so a path that re-writes an UNCHANGED value produces the same
/// bytes and the compare stays green over exactly the regression it claims to pin
/// (`NTMSRepositoryTests.testDeleteTask_nonExistentTask_throws`, 2026-09-02 review).
///
/// Precedent: `BenchmarkHistoryStoreTests.fileIdentity(of:)` reads `.systemFileNumber` for the
/// same reason; this is that helper with the mtime added, shared so the third consumer does not
/// write a fourth copy (CLAUDE.md #51). `NanoTeamsTests/Support/` because everything under
/// `NanoTeamsTests/` must reference only symbols that travel with it to the mirror.
struct FileIdentity: Equatable {
    let inode: UInt64
    let modified: Date

    init(of url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date
        else {
            throw CocoaError(.fileReadUnknown,
                             userInfo: [NSFilePathErrorKey: url.path,
                                        NSLocalizedDescriptionKey: "no inode/mtime in attributes"])
        }
        inode = number.uint64Value
        self.modified = modified
    }
}
