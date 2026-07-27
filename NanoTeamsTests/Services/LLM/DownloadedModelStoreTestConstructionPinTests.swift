import XCTest

@testable import NanoTeams

/// Structural invariant over the test target: **no test may construct an
/// `LMStudioDownloadedModelStore` without injecting a `homeDirectory`.**
///
/// The default home is the developer's real one, and this store's `delete`
/// moves directories under `~/.lmstudio/models` to the Trash. A forgotten
/// argument compiles cleanly and silently arms a test to Trash a 12 GB model —
/// the same failure shape `OrchestratorTestConstructionPinTests` exists to
/// prevent for `NTMSOrchestrator`.
///
/// Pinned structurally rather than behaviourally because the property is about
/// the SET of construction sites: a suite added tomorrow with a bare
/// `LMStudioDownloadedModelStore()` reopens the hole, and no behavioural test
/// can observe a suite that does not exist yet.
final class DownloadedModelStoreTestConstructionPinTests: XCTestCase {

    private func testTargetSwiftFiles() throws -> [URL] {
        let testsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
        let enumerator = FileManager.default.enumerator(
            at: testsRoot, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files
    }

    func testEveryTestConstructionInjectsAHomeDirectory() throws {
        // Assembled at runtime so this file's own prose can't match itself.
        let needle = "LMStudioDownloadedModelStore" + "("
        var offenders: [String] = []

        for file in try testTargetSwiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, raw) in lines.enumerated() {
                // Strip line comments so doc prose naming the type isn't flagged.
                let line = raw.components(separatedBy: "//").first ?? raw
                guard line.contains(needle) else { continue }
                // The injection may sit on a following line for a wrapped call.
                let window = lines[index..<min(index + 4, lines.count)].joined(separator: " ")
                if !window.contains("homeDirectory:") {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "\(offenders) construct an LMStudioDownloadedModelStore without `homeDirectory:`. "
                + "The default home is the developer's real one and `delete` moves model folders "
                + "to the Trash — always inject a temp home in tests.")
    }

    /// Anti-vacuity: a rename that made the needle unmatchable would leave the
    /// assertion above passing over an empty scan.
    func testThePinIsNotVacuous() throws {
        let needle = "LMStudioDownloadedModelStore" + "("
        let hits = try testTargetSwiftFiles().filter { file in
            (try? String(contentsOf: file, encoding: .utf8))?.contains(needle) == true
        }
        XCTAssertFalse(
            hits.isEmpty,
            "No construction sites found at all — the pin is scanning for the wrong symbol.")
    }
}
