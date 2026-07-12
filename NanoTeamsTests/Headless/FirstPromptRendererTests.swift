import XCTest
@testable import NanoTeams

@MainActor
final class FirstPromptRendererTests: XCTestCase {

    // MARK: - Driver test (skipped on a bare `xcodebuild test` run)

    /// Reads config from `.nanoteams/internal/first_prompt_renderer.json` in
    /// the project root. Skips loudly via `XCTSkip` if the config is missing —
    /// render-mode has no LM Studio dependency, but it does need a workfolder
    /// + a target (team, role) tuple supplied by the caller. The wrapper
    /// `./run_first_prompt_renderer.sh` writes this file from a user-supplied
    /// config before invoking xcodebuild.
    func testRenderFirstPrompt() async throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent() // Headless/
            .deletingLastPathComponent() // NanoTeamsTests/
            .deletingLastPathComponent() // project root

        let configURL = projectRoot
            .appendingPathComponent(".nanoteams")
            .appendingPathComponent("internal")
            .appendingPathComponent("first_prompt_renderer.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("""
            No renderer config at \(configURL.path).
            Invoke via ./run_first_prompt_renderer.sh <config.json> or ./train_first_prompt.sh — \
            this test is driver-only and is intentionally not exercised on a bare `xcodebuild test` run.
            """)
        }

        let configData = try Data(contentsOf: configURL)
        let config = try JSONCoderFactory.makeWireDecoder().decode(
            FirstPromptRendererConfig.self, from: configData
        )

        print("[RENDERER] ==========================================")
        print("[RENDERER] Workfolder: \(config.projectPath)")
        print("[RENDERER] Team: \(config.target.team.displayHint)")
        print("[RENDERER] Role: \(config.target.role.displayHint)")
        print("[RENDERER] Output: \(config.outputPath)")
        print("[RENDERER] Model: \(config.resolvedModelName)")
        print("[RENDERER] ==========================================")

        let bytesWritten = try FirstPromptRenderer.run(config: config)

        print("[RENDERER] Wrote \(bytesWritten) bytes to \(config.outputPath)")

        // Sanity-check the envelope round-trips and the wire half carries the
        // required fields.
        let outData = try Data(contentsOf: URL(fileURLWithPath: config.outputPath))
        let parsed = try JSONSerialization.jsonObject(with: outData) as? [String: Any]
        XCTAssertNotNil(parsed, "output must be a JSON object")
        let wire = parsed?["wire"] as? [String: Any]
        XCTAssertNotNil(wire, "envelope must carry a `wire` object")
        XCTAssertNotNil(wire?["system_prompt"], "wire payload must have system_prompt")
        XCTAssertNotNil(wire?["input"], "wire payload must have input")
        XCTAssertNotNil(wire?["model"], "wire payload must have model")
        XCTAssertNotNil(parsed?["render_meta"], "envelope must carry render_meta")
    }

    // MARK: - Filter parity with production (git availability)

    /// Coding Agent's `toolIDs` include `gitReadOnlyTools`. When the workfolder
    /// has no `.git`, `filterForGitAvailability` strips those four tools before
    /// they reach the wire — the renderer must do the same or it ships a
    /// system_prompt that advertises tools production has already filtered out.
    func testRender_nonGitWorkfolder_stripsGitTools() throws {
        let (tmpDir, outputPath) = try makeIsolatedWorkfolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = makeCodingAgentConfig(workfolder: tmpDir, outputPath: outputPath)
        _ = try FirstPromptRenderer.run(config: config)

        let toolNames = try readWireToolNames(at: outputPath)
        let leaked = toolNames.intersection(Self.gitTools)
        XCTAssertTrue(leaked.isEmpty, "git tools leaked into wire when workfolder has no .git: \(leaked)")
    }

    /// Pins the positive direction — git tools must survive when `.git` is
    /// present, so the previous test can't pass by stripping git tools
    /// unconditionally.
    func testRender_gitWorkfolder_keepsGitTools() throws {
        let (tmpDir, outputPath) = try makeIsolatedWorkfolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let gitDir = tmpDir.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)

        let config = makeCodingAgentConfig(workfolder: tmpDir, outputPath: outputPath)
        _ = try FirstPromptRenderer.run(config: config)

        let toolNames = try readWireToolNames(at: outputPath)
        let missing = Self.gitTools.subtracting(toolNames)
        XCTAssertTrue(missing.isEmpty, "git tools must be present in wire when workfolder has .git: missing \(missing)")
    }

    // MARK: - Agent instruction file discovery parity

    /// The renderer must discover agent instruction files (CLAUDE.md, …) off the
    /// on-disk workfolder exactly as `NTMSOrchestrator.refreshAgentInstructions`
    /// does at run start, so the MAIN file's content is injected into the wire
    /// system_prompt and the OTHER files are listed as paths.
    func testRender_workfolderWithAgentInstructions_injectsContentAndPaths() throws {
        let (tmpDir, outputPath) = try makeIsolatedWorkfolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Project rules\nBe terse and correct."
            .write(to: tmpDir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let docs = tmpDir.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "nested agents".write(to: docs.appendingPathComponent("AGENTS.md"),
                                  atomically: true, encoding: .utf8)

        let config = makeCodingAgentConfig(workfolder: tmpDir, outputPath: outputPath)
        _ = try FirstPromptRenderer.run(config: config)

        let systemPrompt = try readWireSystemPrompt(at: outputPath)
        XCTAssertTrue(systemPrompt.contains("### Agent instructions (CLAUDE.md)"),
                      "main file section missing from wire system_prompt")
        XCTAssertTrue(systemPrompt.contains("Be terse and correct."),
                      "main file CONTENT must be injected in full")
        XCTAssertTrue(systemPrompt.contains("### Other agent instruction files"),
                      "other files section missing")
        XCTAssertTrue(systemPrompt.contains("- docs/AGENTS.md"),
                      "nested instruction file must be listed as a path")
    }

    // MARK: - Helpers

    private static let gitTools: Set<String> = [
        "git_status", "git_diff", "git_log", "git_branch_list",
    ]

    private func readWireSystemPrompt(at path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard
            let wire = parsed?["wire"] as? [String: Any],
            let systemPrompt = wire["system_prompt"] as? String
        else {
            throw RenderTestError.missingToolList
        }
        return systemPrompt
    }

    /// Default workfolder has no `.git` — the positive test adds it explicitly.
    private func makeIsolatedWorkfolder() throws -> (workfolder: URL, outputPath: String) {
        let workfolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirstPromptRendererTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workfolder, withIntermediateDirectories: true)
        let outputPath = workfolder.appendingPathComponent("render.json").path
        return (workfolder, outputPath)
    }

    private func makeCodingAgentConfig(workfolder: URL, outputPath: String) -> FirstPromptRendererConfig {
        FirstPromptRendererConfig(
            projectPath: workfolder.path,
            target: ResolutionTarget(
                team: .name("Coding Agent"),
                role: .name("Coding Agent")
            ),
            supervisorTaskBrief: "filter parity test",
            outputPath: outputPath,
            modelName: nil,
            temperature: nil,
            maxTokens: nil,
            globalContext: nil,
            selectedScheme: nil,
            visionConfigured: nil,
            computerUseEnabled: nil
        )
    }

    /// Reads the structured tool list from `render_meta.tools[].name`. Asserting
    /// against this set (rather than substring-matching `**name**:` headers in
    /// `wire.system_prompt`) keeps the regression intact if the prompt's
    /// markdown rendering ever changes — the filter contract is over tool
    /// identities, not over the text format that surfaces them.
    private func readWireToolNames(at path: String) throws -> Set<String> {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard
            let renderMeta = parsed?["render_meta"] as? [String: Any],
            let tools = renderMeta["tools"] as? [[String: Any]]
        else {
            throw RenderTestError.missingToolList
        }
        return Set(tools.compactMap { $0["name"] as? String })
    }

    private enum RenderTestError: Error {
        case missingToolList
    }
}
