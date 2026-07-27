import XCTest

@testable import NanoTeams

/// `HeadlessConfig` decoding, with emphasis on the provider field.
///
/// It used to be `String?` resolved via `flatMap(LLMProvider.init(rawValue:)) ?? .lmStudio`,
/// so `"ollama "` or `"Ollama"` silently ran a 10-minute job against LM Studio.
final class HeadlessConfigTests: XCTestCase {

    private func decode(_ json: String) throws -> HeadlessConfig {
        try JSONCoderFactory.makeWireDecoder().decode(HeadlessConfig.self, from: Data(json.utf8))
    }

    private let minimal = """
        {"projectPath":"/p","taskTitle":"T","supervisorTask":"S"}
        """

    // MARK: - Provider

    func testProvider_omitted_resolvesToLMStudio() throws {
        let c = try decode(minimal)
        XCTAssertNil(c.provider)
        XCTAssertEqual(c.resolvedProvider, .lmStudio)
        XCTAssertEqual(c.resolvedBaseURL, LLMProvider.lmStudio.defaultBaseURL)
        XCTAssertEqual(c.resolvedModel, LLMProvider.lmStudio.defaultModel)
    }

    func testProvider_ollama_decodesAndDrivesTheResolvedDefaults() throws {
        let c = try decode("""
            {"projectPath":"/p","taskTitle":"T","supervisorTask":"S","provider":"ollama"}
            """)
        XCTAssertEqual(c.resolvedProvider, .ollama)
        XCTAssertEqual(c.resolvedBaseURL, LLMProvider.ollama.defaultBaseURL)
        XCTAssertEqual(c.resolvedModel, LLMProvider.ollama.defaultModel)
    }

    /// The regression: a typo must fail at load, not 20 minutes into a run
    /// against the wrong server. The message has to name both the bad value and
    /// the legal set, or the operator cannot act on it.
    func testProvider_unknownValue_failsLoudlyNamingTheLegalValues() {
        XCTAssertThrowsError(try decode("""
            {"projectPath":"/p","taskTitle":"T","supervisorTask":"S","provider":"lmstdio"}
            """)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("lmstdio"), "must quote the offending value: \(text)")
            for provider in LLMProvider.allCases {
                XCTAssertTrue(text.contains(provider.rawValue),
                              "must list \(provider.rawValue): \(text)")
            }
        }
    }

    /// Case matters — `LLMProvider` raw values are exact, and accepting
    /// `"Ollama"` here would diverge from every other provider decode site.
    func testProvider_wrongCase_isRejectedRatherThanSilentlyDegraded() {
        XCTAssertThrowsError(try decode("""
            {"projectPath":"/p","taskTitle":"T","supervisorTask":"S","provider":"Ollama"}
            """))
    }

    func testProvider_roundTripsThroughEncode() throws {
        let c = try decode("""
            {"projectPath":"/p","taskTitle":"T","supervisorTask":"S","provider":"ollama"}
            """)
        let data = try JSONCoderFactory.makeWireEncoder().encode(c)
        XCTAssertEqual(try decode(String(decoding: data, as: UTF8.self)).provider, .ollama)
    }

    // MARK: - Required fields and legacy migration

    func testMissingRequiredField_throws() {
        XCTAssertThrowsError(try decode("""
            {"taskTitle":"T","supervisorTask":"S"}
            """))
    }

    /// Pre-rename configs used `projectDescription`; re-encoding completes the
    /// migration in place rather than round-tripping the dead key forever.
    func testLegacyProjectDescription_isAcceptedAndNotReWritten() throws {
        let c = try decode("""
            {"projectPath":"/p","taskTitle":"T","supervisorTask":"S","projectDescription":"legacy"}
            """)
        XCTAssertEqual(c.workFolderContext, "legacy")

        let json = String(decoding: try JSONCoderFactory.makeWireEncoder().encode(c), as: UTF8.self)
        XCTAssertTrue(json.contains("workFolderContext"))
        XCTAssertFalse(json.contains("projectDescription"))
    }

    // MARK: - The tracked sample

    /// `.gitignore` excludes `.nanoteams/` at every depth, so the only viable
    /// home for a committed example is `Fixtures/`. It must stay decodable —
    /// a sample that no longer parses is worse than none.
    func testTrackedSampleConfig_decodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()            // Headless/
            .deletingLastPathComponent()            // NanoTeamsTests/
            .appendingPathComponent("Fixtures/Headless/headless_task.sample.json")
        let data = try Data(contentsOf: url)
        let c = try JSONCoderFactory.makeWireDecoder().decode(HeadlessConfig.self, from: data)
        XCTAssertFalse(c.taskTitle.isEmpty)
        XCTAssertFalse(c.supervisorTask.isEmpty)
        XCTAssertEqual(c.resolvedProvider, .lmStudio)
    }
}
