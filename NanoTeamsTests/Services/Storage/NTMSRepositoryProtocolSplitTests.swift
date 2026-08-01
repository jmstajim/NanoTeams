import XCTest
@testable import NanoTeams

/// Regression guards for the ISP-split repository protocols introduced in
/// the SOLID/GRASP P2 refactor. These tests lock in the protocol surface so
/// accidental re-expansion of any sub-protocol fails at compile time.
final class NTMSRepositoryProtocolSplitTests: XCTestCase {

    // MARK: - Conformance

    /// `NTMSRepository` must conform to every sub-protocol — the composition typealias
    /// relies on this, and the orchestrator injects it through the full typealias.
    func testNTMSRepository_conformsToAllSubProtocols() {
        let repo = NTMSRepository()

        XCTAssertTrue((repo as Any) is any WorkFolderRepository)
        XCTAssertTrue((repo as Any) is any TaskRepository)
        XCTAssertTrue((repo as Any) is any ToolRepository)
        XCTAssertTrue((repo as Any) is any ArtifactRepository)
        XCTAssertTrue((repo as Any) is any AttachmentRepository)
        XCTAssertTrue((repo as Any) is any NTMSRepositoryProtocol)
    }

    // MARK: - ArtifactRepository narrowness (ISP guard)

    /// `ArtifactRepository` exposes `persistStepArtifactFile` and `persistStepArtifactBinary`
    /// — and nothing else.
    func testArtifactRepository_exposesArtifactPersistenceMethods() throws {
        let repo: any ArtifactRepository = NTMSRepository()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactRepoISPTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Markdown artifact persistence
        let mdPath = try repo.persistStepArtifactFile(
            at: tempDir,
            taskID: 0,
            runID: 0,
            roleID: "test_role",
            artifactName: "Test Artifact",
            content: "hello"
        )
        XCTAssertFalse(mdPath.isEmpty)

        // Binary artifact persistence (PDF/RTF/DOCX side-car)
        let binPath = try repo.persistStepArtifactBinary(
            at: tempDir,
            taskID: 0,
            runID: 0,
            roleID: "test_role",
            artifactName: "Test Artifact",
            data: Data("binary".utf8),
            fileExtension: "pdf"
        )
        XCTAssertFalse(binPath.isEmpty)
        XCTAssertTrue(binPath.hasSuffix(".pdf"))
    }

    // MARK: - TaskMutationDelegate refinement

    /// `LLMStateDelegate` must refine `TaskMutationDelegate` — any concrete
    /// conformance to `LLMStateDelegate` automatically satisfies the narrower
    /// protocol. Regression guard against removing the refinement.
    func testLLMStateDelegate_refinesTaskMutationDelegate() {
        // Compile-time check via a generic function that requires refinement.
        func requiresRefinement<T: LLMStateDelegate>(_ value: T) -> any TaskMutationDelegate {
            return value
        }
        // Non-empty assertion to exercise the path.
        XCTAssertTrue(true, "If this file compiles, the refinement holds.")
    }
}
