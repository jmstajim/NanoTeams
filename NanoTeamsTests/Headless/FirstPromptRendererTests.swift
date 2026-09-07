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

    // MARK: - The hidden singleton renders without a folder that has ever enabled it

    /// The Autovisor team is materialised lazily by the app (`ensureAutovisorTeam`, on first
    /// enable), so a fresh workfolder's `teams.json` never holds it and the render failed with
    /// `teamNotFound` — the 2026-06-15 audit had to copy another folder's persisted teams to
    /// render the Manager at all, and the record's own "Next" asked for this affordance. The
    /// renderer now materialises the team IN MEMORY exactly as the app does (factory + template
    /// sync), and never writes it: the renderer reads the real folder and must not change it.
    func testRender_autovisorAbsentFromTeamsJSON_materialisesTheHiddenSingletonInMemory() throws {
        let (tmpDir, outputPath) = try makeIsolatedWorkfolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = FirstPromptRendererConfig(
            projectPath: tmpDir.path,
            target: ResolutionTarget(team: .name("Autovisor"), role: .name("Autovisor")),
            supervisorTaskBrief: "shows error Load failed",
            outputPath: outputPath,
            modelName: nil, temperature: nil, globalContext: nil,
            selectedScheme: nil, visionConfigured: nil, computerUseMode: nil, bashMode: nil, kind: nil)
        _ = try FirstPromptRenderer.run(config: config)

        let toolNames = try readWireToolNames(at: outputPath)
        XCTAssertTrue(toolNames.contains(ToolNames.waitForEvents),
                      "the Manager's mandatory tools must reach the wire; got \(toolNames.sorted())")
        let systemPrompt = try readWireSystemPrompt(at: outputPath)
        XCTAssertTrue(systemPrompt.contains("## Tool Calling"), "a tool-loop system prompt")

        let teamsJSON = tmpDir.appendingPathComponent(".nanoteams/internal/teams.json")
        let persisted = try String(contentsOf: teamsJSON, encoding: .utf8)
        XCTAssertFalse(persisted.contains("\"templateID\" : \"\(AutovisorConstants.teamTemplateID)\""),
                       "the render must not persist the singleton into the folder's teams.json")
        XCTAssertFalse(persisted.contains("\"templateID\":\"\(AutovisorConstants.teamTemplateID)\""),
                       "the render must not persist the singleton into the folder's teams.json")
    }

    /// A render with no `globalContext` carries the PRODUCTION default. Since 2026-09-07
    /// that default is EMPTY — the slot belongs to the user and the one-tool rule rides the
    /// `## Tool Calling` body — so the default render has no `## Global guidance` section
    /// and is byte-identical to an explicitly cleared one, while a folder's own text
    /// renders as the section. (Until 2026-09-06 `resolvedGlobalContext` defaulted to the
    /// empty string INSTEAD of the production value, which is the distinction this test
    /// keeps: the renderer reads the production default, whatever it is.)
    func testRender_globalContext_defaultsToTheProductionValue_andAFolderValueRendersTheSection() throws {
        let (tmpDir, outputPath) = try makeIsolatedWorkfolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try FirstPromptRenderer.run(config: makeCodingAgentConfig(workfolder: tmpDir, outputPath: outputPath))
        let defaulted = try readWireSystemPrompt(at: outputPath)
        XCTAssertEqual(AppDefaults.globalContext, "", "the production default is the empty user slot")
        XCTAssertFalse(defaulted.contains("## Global guidance"),
                       "an empty default renders no section — the header is stripped, not left dangling")
        XCTAssertEqual(defaulted.components(separatedBy: NativeLMStudioClient.oneToolPerResponseRule).count - 1, 1,
                       "the one-tool rule rides the `## Tool Calling` body exactly once")

        func render(globalContext: String?) throws -> String {
            let config = FirstPromptRendererConfig(
                projectPath: tmpDir.path,
                target: ResolutionTarget(team: .name("Coding Agent"), role: .name("Coding Agent")),
                supervisorTaskBrief: "filter parity test",
                outputPath: outputPath,
                modelName: nil, temperature: nil, globalContext: globalContext,
                selectedScheme: nil, visionConfigured: nil, computerUseMode: nil, bashMode: nil, kind: nil)
            _ = try FirstPromptRenderer.run(config: config)
            return try readWireSystemPrompt(at: outputPath)
        }
        XCTAssertEqual(try render(globalContext: ""), defaulted,
                       "an explicit empty string and the empty default are the same render")
        let folderValue = "Answer in Russian."
        let withSection = try render(globalContext: folderValue)
        XCTAssertTrue(withSection.contains("## Global guidance\n\(folderValue)"),
                      "a folder's own text is the section")
        XCTAssertEqual(withSection.utf8.count - defaulted.utf8.count,
                       "## Global guidance\n\(folderValue)\n\n".utf8.count,
                       "the section is the only difference between the two renders")
    }

    // MARK: - The approval-gated families ride the render the way they ride the wire (B3)

    private func startupSWEConfig(workfolder: URL, outputPath: String, bashMode: BashExecutionMode? = nil, kind: RenderKind? = nil) -> FirstPromptRendererConfig {
        FirstPromptRendererConfig(
            projectPath: workfolder.path,
            target: ResolutionTarget(team: .name("Startup"), role: .name("Software Engineer")),
            supervisorTaskBrief: "Build a calculator",
            outputPath: outputPath,
            modelName: nil, temperature: nil, globalContext: nil,
            selectedScheme: nil, visionConfigured: nil, computerUseMode: nil, bashMode: bashMode, kind: kind)
    }

    private func readRenderMeta(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let renderMeta = parsed?["render_meta"] as? [String: Any] else { throw RenderTestError.missingToolList }
        return renderMeta
    }

    /// Flips the persisted Startup team's Supervisor mode — what a headless run leaves behind in
    /// its folder (`HeadlessRunner` sets `.autonomous` and never restores it).
    private func setStartupSupervisorMode(_ mode: SupervisorMode, in workfolder: URL) throws {
        let repository = NTMSRepository()
        _ = try repository.openOrCreateWorkFolder(at: workfolder)
        _ = try repository.updateTeams(at: workfolder, activeTask: nil) { teams in
            guard let i = teams.firstIndex(where: { $0.name == "Startup" }) else { return }
            teams[i].settings.supervisorMode = mode
        }
    }

    /// A fresh folder: the team is `.manual` (a human), the modes are the fresh-install
    /// defaults, so `bash` ships — and `render_meta` says from what.
    func testRender_freshFolder_shipsBash_andRecordsThePresenceInputs() throws {
        let (tmpDir, outputPath) = try makeIsolatedWorkfolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try FirstPromptRenderer.run(config: startupSWEConfig(workfolder: tmpDir, outputPath: outputPath))

        let tools = try readWireToolNames(at: outputPath)
        XCTAssertTrue(tools.contains(ToolNames.bash), "a human is present and Manual bash ships; got \(tools.sorted())")
        let meta = try readRenderMeta(at: outputPath)
        XCTAssertEqual(meta["supervisor_mode"] as? String, SupervisorMode.manual.rawValue)
        XCTAssertEqual(meta["bash_mode"] as? String, BashConstants.defaultMode.rawValue)
        XCTAssertEqual(meta["computer_use_mode"] as? String, ComputerUseMode.manual.rawValue)
        XCTAssertEqual(meta["human_present"] as? Bool, true)
    }

    /// The folder a headless run left in `.autonomous`: rendered as the wire would send it —
    /// no `bash`, no `bash_output` under the default Manual mode — and the meta names why, so
    /// a diff against the fresh render explains itself instead of surprising the auditor.
    func testRender_autonomousTeamOnDisk_withholdsBash_andSaysNoHumanIsPresent() throws {
        let (tmpDir, outputPath) = try makeIsolatedWorkfolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try setStartupSupervisorMode(.autonomous, in: tmpDir)

        _ = try FirstPromptRenderer.run(config: startupSWEConfig(workfolder: tmpDir, outputPath: outputPath))

        let tools = try readWireToolNames(at: outputPath)
        XCTAssertFalse(tools.contains(ToolNames.bash), "nobody can approve: \(tools.sorted())")
        XCTAssertFalse(tools.contains(ToolNames.bashOutput))
        let meta = try readRenderMeta(at: outputPath)
        XCTAssertEqual(meta["supervisor_mode"] as? String, SupervisorMode.autonomous.rawValue)
        XCTAssertEqual(meta["human_present"] as? Bool, false)
    }

    /// The config's `bashMode` is read against the same presence answer: Semi-automatic keeps
    /// the tool with no human (its read-only commands run), so the audit's semi arm renders it.
    func testRender_autonomousTeamOnDisk_semiAutomaticBash_keepsBash() throws {
        let (tmpDir, outputPath) = try makeIsolatedWorkfolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try setStartupSupervisorMode(.autonomous, in: tmpDir)

        _ = try FirstPromptRenderer.run(
            config: startupSWEConfig(workfolder: tmpDir, outputPath: outputPath, bashMode: .semiAutomatic, kind: nil))

        let tools = try readWireToolNames(at: outputPath)
        XCTAssertTrue(tools.contains(ToolNames.bash), "Semi-automatic keeps the tool unattended; got \(tools.sorted())")
        let meta = try readRenderMeta(at: outputPath)
        XCTAssertEqual(meta["bash_mode"] as? String, BashExecutionMode.semiAutomatic.rawValue)
        XCTAssertEqual(meta["human_present"] as? Bool, false)
    }

    /// The config decodes the modes by RAW value and refuses a typo, like `provider` does —
    /// a misspelled mode must fail the load, never render under a silent default.
    func testConfig_decodesModesByRawValue_andRefusesATypo() throws {
        let decoder = JSONCoderFactory.makeWireDecoder()
        let good = """
        {"projectPath":"/tmp/x","target":{"team":{"name":"Startup"},"role":{"name":"Software Engineer"}},
         "supervisorTaskBrief":"b","outputPath":"/tmp/o.json","bashMode":"manual","computerUseMode":"semiAutomatic"}
        """
        let config = try decoder.decode(FirstPromptRendererConfig.self, from: Data(good.utf8))
        XCTAssertEqual(config.bashMode, .semiAutomatic, "`manual` is the legacy raw value of Semi-automatic")
        XCTAssertEqual(config.computerUseMode, .semiAutomatic)
        XCTAssertEqual(config.resolvedBashMode, .semiAutomatic)

        let absent = """
        {"projectPath":"/tmp/x","target":{"team":{"name":"Startup"},"role":{"name":"Software Engineer"}},
         "supervisorTaskBrief":"b","outputPath":"/tmp/o.json"}
        """
        let defaults = try decoder.decode(FirstPromptRendererConfig.self, from: Data(absent.utf8))
        XCTAssertNil(defaults.bashMode)
        XCTAssertEqual(defaults.resolvedBashMode, BashConstants.defaultMode)
        XCTAssertEqual(defaults.resolvedComputerUseMode, .manual)

        let typo = """
        {"projectPath":"/tmp/x","target":{"team":{"name":"Startup"},"role":{"name":"Software Engineer"}},
         "supervisorTaskBrief":"b","outputPath":"/tmp/o.json","bashMode":"semi-automatic"}
        """
        XCTAssertThrowsError(try decoder.decode(FirstPromptRendererConfig.self, from: Data(typo.utf8)))
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
            globalContext: nil,
            selectedScheme: nil,
            visionConfigured: nil,
            computerUseMode: nil, bashMode: nil, kind: nil
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

    // MARK: - Kinds

    private func discussionObserverConfig(workfolder: URL, outputPath: String, kind: RenderKind) -> FirstPromptRendererConfig {
        FirstPromptRendererConfig(
            projectPath: workfolder.path,
            target: ResolutionTarget(team: .name("Discussion Club"), role: .name("The Open")),
            supervisorTaskBrief: "Debate the four-day week",
            outputPath: outputPath,
            modelName: nil, temperature: nil, globalContext: nil,
            selectedScheme: nil, visionConfigured: nil, computerUseMode: nil, bashMode: nil, kind: kind)
    }

    /// `--kind consultation`: the consultation template, no tools (production passes
    /// `tools: []`), and therefore neither the Harmony body nor the one-tool rule.
    func testRender_kindConsultation_rendersTheConsultationPromptWithoutTools() throws {
        let (workfolder, outputPath) = try makeIsolatedWorkfolder()
        defer { try? FileManager.default.removeItem(at: workfolder) }
        try FirstPromptRenderer.run(config: startupSWEConfig(workfolder: workfolder, outputPath: outputPath, kind: .consultation))

        let meta = try readRenderMeta(at: outputPath)
        XCTAssertEqual(meta["kind"] as? String, "consultation")
        XCTAssertEqual((meta["sizes"] as? [String: Any])?["tools_count"] as? Int, 0)
        let system = try readWireSystemPrompt(at: outputPath)
        XCTAssertFalse(system.contains(NativeLMStudioClient.harmonyBodyMarker))
        XCTAssertFalse(system.contains(NativeLMStudioClient.oneToolPerResponseRule))
        XCTAssertTrue(system.contains("## Final reminder"), "the consultation template's tail reminder ships")

        let stepPath = workfolder.appendingPathComponent("step.json").path
        try FirstPromptRenderer.run(config: startupSWEConfig(workfolder: workfolder, outputPath: stepPath))
        XCTAssertNotEqual(system, try readWireSystemPrompt(at: stepPath), "a different call site is a different prompt")
    }

    /// `--kind meeting` for a tool-less observer: the meeting template says "None available"
    /// and NOT "Call one tool per response." — the two sentences stood together on this exact
    /// surface until 2026-09-07 (A7) — and `## Final reminder` is the last section.
    func testRender_kindMeeting_observerReadsNoneAvailableWithoutTheOneToolRule_andTheReminderIsLast() throws {
        let (workfolder, outputPath) = try makeIsolatedWorkfolder()
        defer { try? FileManager.default.removeItem(at: workfolder) }
        try FirstPromptRenderer.run(config: discussionObserverConfig(workfolder: workfolder, outputPath: outputPath, kind: .meeting))

        let meta = try readRenderMeta(at: outputPath)
        XCTAssertEqual(meta["kind"] as? String, "meeting")
        XCTAssertEqual((meta["sizes"] as? [String: Any])?["tools_count"] as? Int, 0, "The Open holds no tools")
        let system = try readWireSystemPrompt(at: outputPath)
        XCTAssertFalse(system.contains(NativeLMStudioClient.oneToolPerResponseRule), "a rule about calls with nothing to call")
        XCTAssertTrue(system.contains("None available"), "the tool-less sentence is the one that stays")
        let lastH2 = system.components(separatedBy: "\n").last { $0.hasPrefix("## ") }
        XCTAssertEqual(lastH2, "## Final reminder")
    }

    func testConfig_decodesKindByRawValue_andRefusesATypo() throws {
        func decode(_ kind: String) throws -> FirstPromptRendererConfig {
            let json = """
            {"projectPath":"/tmp/x","target":{"team":{"name":"Startup"},"role":{"name":"Software Engineer"}},
             "supervisorTaskBrief":"b","outputPath":"/tmp/o.json","kind":"\(kind)"}
            """
            return try JSONDecoder().decode(FirstPromptRendererConfig.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode("meeting").resolvedKind, .meeting)
        XCTAssertThrowsError(try decode("meting"), "a typo fails the load, not the render")
    }
}
