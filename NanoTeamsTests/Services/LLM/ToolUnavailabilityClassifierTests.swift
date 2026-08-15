import XCTest

@testable import NanoTeams

/// Pins the precondition-aware rejection envelope. Before this classifier,
/// every "tool not in `allowedToolNames`" rejection shipped a single
/// `tool_not_authorized` envelope with the message "Tool 'X' is not
/// available for this role" — true for hallucinations, but misleading
/// when the role IS configured with the tool and the work folder simply
/// lacks a precondition (no `.git`, no vision model, no xcode scheme,
/// no opened folder). Smaller models then loop, "fixing" arguments that
/// were never the cause.
///
/// This suite covers the pure-function classifier + envelope builder.
/// The runtime wiring (read live `delegate` state) is exercised by
/// integration suites that already drive `executeToolCalls`.
@MainActor
final class ToolUnavailabilityClassifierTests: XCTestCase {

    var tempDir: URL!
    let fm = FileManager.default

    override func setUp() async throws {
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("ToolUnavailabilityClassifierTests-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Classifier

    func testClassify_gitTool_noGitFolder_returnsGitRepoMissing() {
        // tempDir has no .git/ — exactly the screenshot case (calculator/
        // sample folder under default storage).
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: ToolNames.gitAdd,
            workFolderRoot: tempDir,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "Foo",
            fileManager: fm
        )
        XCTAssertEqual(reason, .gitRepoMissing)
    }

    func testClassify_gitTool_withGitFolder_returnsNotInRoleConfig() throws {
        try fm.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        // Real git repo present → git tool can't be filtered for `.git`
        // missing. Falling back to `notInRoleConfig` is correct: the only
        // remaining reason for the tool to be absent from `allowedToolNames`
        // is a genuine role-config mismatch (or hallucination).
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: ToolNames.gitAdd,
            workFolderRoot: tempDir,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "Foo",
            fileManager: fm
        )
        XCTAssertEqual(reason, .notInRoleConfig)
    }

    func testClassify_writeFile_inDefaultStorage_returnsWorkFolderClosed() {
        // Default-storage subsumes git/xcode/write — this branch must
        // win over `.gitRepoMissing` even though tempDir also lacks .git/.
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: ToolNames.writeFile,
            workFolderRoot: tempDir,
            isDefaultStorage: true,
            isVisionConfigured: true,
            selectedScheme: nil,
            fileManager: fm
        )
        XCTAssertEqual(reason, .workFolderClosed)
    }

    func testClassify_analyzeImage_visionDisabled_returnsVisionNotConfigured() throws {
        try fm.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: ToolNames.analyzeImage,
            workFolderRoot: tempDir,
            isDefaultStorage: false,
            isVisionConfigured: false,
            selectedScheme: "Foo",
            fileManager: fm
        )
        XCTAssertEqual(reason, .visionNotConfigured)
    }

    func testClassify_runXcodebuild_noScheme_returnsXcodeSchemeNotSelected() throws {
        try fm.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: ToolNames.runXcodebuild,
            workFolderRoot: tempDir,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: nil,
            fileManager: fm
        )
        XCTAssertEqual(reason, .xcodeSchemeNotSelected)
    }

    func testClassify_runXcodebuild_emptyScheme_returnsXcodeSchemeNotSelected() throws {
        // Empty string is treated identically to nil. Settings UI persists
        // the picker as a String which can land empty when the user clears
        // the field; without this the classifier would say "in role config"
        // and the executor would route to the handler, which then surfaces
        // a less actionable error.
        try fm.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: ToolNames.runXcodebuild,
            workFolderRoot: tempDir,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "",
            fileManager: fm
        )
        XCTAssertEqual(reason, .xcodeSchemeNotSelected)
    }

    func testClassify_computerUseTools_disabled_returnsComputerUseDisabled() {
        // All 5 computer-use tools route to the dedicated reason when the
        // feature is off — regardless of git/vision/scheme state (they're
        // disjoint categories).
        for tool in ToolHandlerRegistry.computerUseTools {
            let reason = LLMExecutionService.classifyUnavailability(
                toolName: tool,
                workFolderRoot: tempDir,
                isDefaultStorage: false,
                isVisionConfigured: true,
                selectedScheme: "Foo",
                isComputerUseEnabled: false,
                fileManager: fm
            )
            XCTAssertEqual(reason, .computerUseDisabled, "expected .computerUseDisabled for \(tool)")
        }
    }

    func testClassify_computerUseTool_disabled_inDefaultStorage_returnsComputerUseDisabled() {
        // Computer-use tools are NOT in `defaultStorageBlocked` (they operate the
        // desktop, not the work folder), so the default-storage branch — which is
        // checked FIRST — must not swallow them; the envelope names the actual
        // blocker (feature off), not a work-folder precondition.
        XCTAssertTrue(
            ToolHandlerRegistry.computerUseTools.isDisjoint(with: ToolHandlerRegistry.defaultStorageBlocked),
            "precedence reasoning below assumes computer-use tools are never default-storage-blocked")
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: ToolNames.screenCapture,
            workFolderRoot: tempDir,
            isDefaultStorage: true,
            isVisionConfigured: true,
            selectedScheme: nil,
            isComputerUseEnabled: false,
            fileManager: fm
        )
        XCTAssertEqual(reason, .computerUseDisabled)
    }

    func testClassify_computerUseTool_disabled_noGitRepo_returnsComputerUseDisabled() {
        // tempDir has no .git — the git-missing branch is category-disjoint and
        // must not claim a ui_* tool.
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: ToolNames.uiType,
            workFolderRoot: tempDir,
            isDefaultStorage: false,
            isVisionConfigured: false,
            selectedScheme: nil,
            isComputerUseEnabled: false,
            fileManager: fm
        )
        XCTAssertEqual(reason, .computerUseDisabled)
    }

    func testClassify_computerUseTool_enabled_returnsNotInRoleConfig() {
        // Feature is on but the tool still landed outside allowedToolNames →
        // the role was never granted it. Genuine role-config mismatch.
        let explicit = LLMExecutionService.classifyUnavailability(
            toolName: ToolNames.screenCapture,
            workFolderRoot: tempDir,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "Foo",
            isComputerUseEnabled: true,
            fileManager: fm
        )
        XCTAssertEqual(explicit, .notInRoleConfig)
        // Same call with the param omitted pins the default `true` — a caller
        // that can't see the policy must NOT blame the Computer Use setting
        // (mirrors the `xcodeSchemeKnown` "don't blame a setting you can't
        // see" contract).
        let defaulted = LLMExecutionService.classifyUnavailability(
            toolName: ToolNames.uiClick,
            workFolderRoot: tempDir,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "Foo",
            fileManager: fm
        )
        XCTAssertEqual(defaulted, .notInRoleConfig)
    }

    func testClassify_unknownTool_returnsNotInRoleConfig() throws {
        try fm.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        // Genuine hallucination — tool the role never had configured and
        // doesn't match any precondition-bound category.
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: "imaginary_tool",
            workFolderRoot: tempDir,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "Foo",
            fileManager: fm
        )
        XCTAssertEqual(reason, .notInRoleConfig)
    }

    // MARK: - Envelope builder

    func testEnvelope_gitRepoMissing_emitsPreconditionFailedCode() {
        let call = StepToolCall(name: "git_add", argumentsJSON: #"{"paths":["a.txt"]}"#)
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call,
            canonicalName: "git_add",
            scope: "for this role",
            reason: .gitRepoMissing
        )
        XCTAssertTrue(envelope.isError)
        XCTAssertTrue(
            envelope.outputJSON.contains("\"error\":\"precondition_failed\""),
            "expected precondition_failed code, got: \(envelope.outputJSON)"
        )
        XCTAssertTrue(
            envelope.outputJSON.contains("requires a git repository"),
            "expected git-specific message, got: \(envelope.outputJSON)"
        )
        XCTAssertFalse(
            envelope.outputJSON.contains("not available for this role"),
            "must NOT use the misleading role-config message — the role HAS git_add, the work folder lacks .git/. Got: \(envelope.outputJSON)"
        )
        // Precondition envelopes KEEP the structured `tool` field — it names a
        // real blocked tool (canonical name) that downstream tooling relies on.
        // Pins the scoping: only `.notInRoleConfig` drops it (see
        // `testEnvelope_notInRoleConfig_omitsToolField`). A future "drop it
        // everywhere" must be a conscious change, not an accident.
        XCTAssertTrue(
            envelope.outputJSON.contains("\"tool\":\"git_add\""),
            "precondition envelope must keep the 'tool' field, got: \(envelope.outputJSON)"
        )
    }

    func testEnvelope_notInRoleConfig_keepsLegacyToolNotAuthorizedCode() {
        // Regression-pin: the legacy code stays put for the genuine
        // hallucination case so existing guidance/tests
        // (`ToolErrorGuidanceTests`, `RepoBrowserNamespaceRejectionTests`)
        // keep matching. Only NEW preconditions get `precondition_failed`.
        let call = StepToolCall(name: "imaginary_tool", argumentsJSON: "{}")
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call,
            canonicalName: "imaginary_tool",
            scope: "for this role",
            reason: .notInRoleConfig
        )
        XCTAssertTrue(envelope.outputJSON.contains("\"error\":\"tool_not_authorized\""))
        XCTAssertTrue(envelope.outputJSON.contains("not available for this role"))
    }

    func testEnvelope_notInRoleConfig_omitsToolField() {
        // The hallucination envelope drops the `tool` field: echoing the
        // model's invented name back as `"tool":"X"` frames it as a real tool
        // and confuses weaker models (the name is often an artifact name).
        // Code + message still name it; only the structured field is gone.
        let call = StepToolCall(name: "Engineering Notes", argumentsJSON: "{}")
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call,
            canonicalName: "Engineering Notes",
            scope: "for this role",
            reason: .notInRoleConfig
        )
        XCTAssertFalse(
            envelope.outputJSON.contains("\"tool\":"),
            "tool_not_authorized envelope must not carry a 'tool' field, got: \(envelope.outputJSON)"
        )
        XCTAssertTrue(envelope.outputJSON.contains("\"error\":\"tool_not_authorized\""))
        XCTAssertTrue(envelope.outputJSON.contains("Tool 'Engineering Notes' is not available"))
    }

    func testEnvelope_notInRoleConfig_differingCanonicalName_leaksNeither() {
        // Namespaced emission: call.name "repo_browser.list_files" strips to
        // canonical "list_files". The hallucination branch must surface NEITHER
        // name in a structured `tool` field; the message keeps the as-emitted
        // name so the LLM can correlate with what it just typed.
        let call = StepToolCall(name: "repo_browser.list_files", argumentsJSON: "{}")
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call,
            canonicalName: "list_files",
            scope: "for this role",
            reason: .notInRoleConfig
        )
        XCTAssertFalse(
            envelope.outputJSON.contains("\"tool\":"),
            "must not surface a 'tool' field even when canonical ≠ as-emitted, got: \(envelope.outputJSON)"
        )
        XCTAssertTrue(envelope.outputJSON.contains("Tool 'repo_browser.list_files' is not available"))
    }

    func testEnvelope_workFolderClosed_namesDefaultStorage() {
        let call = StepToolCall(name: "write_file", argumentsJSON: "{}")
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call,
            canonicalName: "write_file",
            scope: "for this role",
            reason: .workFolderClosed
        )
        XCTAssertTrue(envelope.outputJSON.contains("\"error\":\"precondition_failed\""))
        XCTAssertTrue(envelope.outputJSON.contains("default storage"))
    }

    func testEnvelope_visionNotConfigured_pointsToSettings() {
        let call = StepToolCall(name: "analyze_image", argumentsJSON: "{}")
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call,
            canonicalName: "analyze_image",
            scope: "for this role",
            reason: .visionNotConfigured
        )
        XCTAssertTrue(envelope.outputJSON.contains("\"error\":\"precondition_failed\""))
        XCTAssertTrue(envelope.outputJSON.contains("vision model"))
    }

    func testEnvelope_xcodeSchemeNotSelected_namesScheme() {
        let call = StepToolCall(name: "run_xcodebuild", argumentsJSON: "{}")
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call,
            canonicalName: "run_xcodebuild",
            scope: "for this role",
            reason: .xcodeSchemeNotSelected
        )
        XCTAssertTrue(envelope.outputJSON.contains("\"error\":\"precondition_failed\""))
        XCTAssertTrue(envelope.outputJSON.contains("Xcode scheme"))
    }

    func testEnvelope_computerUseDisabled_namesComputerUse() {
        let call = StepToolCall(name: "ui_click", argumentsJSON: #"{"cx":10,"cy":10}"#)
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call,
            canonicalName: "ui_click",
            scope: "for this role",
            reason: .computerUseDisabled
        )
        XCTAssertTrue(envelope.isError)
        XCTAssertTrue(envelope.outputJSON.contains("\"error\":\"precondition_failed\""))
        XCTAssertTrue(
            envelope.outputJSON.contains("Computer Use"),
            "message must name the disabled feature, got: \(envelope.outputJSON)"
        )
        XCTAssertFalse(
            envelope.outputJSON.contains("not available for this role"),
            "must NOT use the misleading role-config message — the role HAS the tool, the feature is off. Got: \(envelope.outputJSON)"
        )
        // Precondition envelopes keep the structured `tool` field.
        XCTAssertTrue(envelope.outputJSON.contains("\"tool\":\"ui_click\""))
    }

    func testEnvelope_legacyHelperDelegatesToNotInRoleConfig() {
        // The deprecated `makeToolNotAuthorizedResult` wrapper must still
        // produce the exact legacy envelope shape so `MeetingToolExecutor`
        // and the existing guidance test corpus keep passing without a
        // sweep. If this drifts, hunt down the wrapper before chasing
        // ten unrelated test failures.
        let call = StepToolCall(name: "list_files", argumentsJSON: "{}")
        let legacy = LLMExecutionService.makeToolNotAuthorizedResult(
            call: call, canonicalName: "list_files", scope: "for this role"
        )
        let direct = LLMExecutionService.makeUnavailableToolResult(
            call: call, canonicalName: "list_files",
            scope: "for this role", reason: .notInRoleConfig
        )
        XCTAssertEqual(legacy.outputJSON, direct.outputJSON)
    }

    // MARK: - Guidance

    /// `precondition_failed` must NOT inherit the default branch's "Retry
    /// the tool call with the correct arguments" suffix — the precondition
    /// is set by the work folder, not by args. Generic retry guidance sends
    /// weaker models into a loop on the same blocked tool.
    // I7: `async` keeps this test off the Xcode 26.3 sync-method abort path
    // (CLAUDE.md "Common API pitfalls"). The classifier-only tests above
    // construct value types only and stay safe as sync.
    func testGuidance_preconditionFailed_directsAwayFromRetry() async throws {
        let call = StepToolCall(name: "git_add", argumentsJSON: "{}")
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call, canonicalName: "git_add",
            scope: "for this role", reason: .gitRepoMissing
        )

        // The blocker is named by the ENVELOPE, which the model reads one turn earlier;
        // the direction restating it was the duplication `ToolErrorNotePolicy` removed.
        XCTAssertTrue(
            envelope.outputJSON.contains("requires a git repository"),
            "the envelope must name the missing prerequisite, got: \(envelope.outputJSON)"
        )

        let guidance = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope))

        XCTAssertTrue(
            guidance.contains("Do not retry 'git_add'"),
            "anti-loop instruction must appear, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("with the correct arguments"),
            "generic retry suffix is misleading for preconditions, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("requires a git repository"),
            "the direction must not restate the envelope, got: \(guidance)"
        )
    }

    // MARK: - Planning phase (the one temporal rejection)

    /// The phase set is derived from the ALREADY-precondition-filtered tool
    /// array, so membership proves every other reason is inapplicable — hence it
    /// is checked first. Pinned against the strongest competing reason: a
    /// default-storage session would otherwise claim `write_file` needs a work
    /// folder, which is true but not why it was refused THIS iteration.
    func testClassify_phaseWithheldTool_outranksEveryOtherReason() {
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: ToolNames.writeFile,
            workFolderRoot: URL(fileURLWithPath: "/tmp"),
            isDefaultStorage: true,
            isVisionConfigured: false,
            selectedScheme: nil,
            phaseWithheldToolNames: [ToolNames.writeFile]
        )
        XCTAssertEqual(reason, .withheldUntilPlanRecorded)
    }

    /// A tool the role genuinely never had must NOT be promised for later.
    func testClassify_hallucinatedTool_isStillNotInRoleConfig() {
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: "run_shell_command",
            workFolderRoot: URL(fileURLWithPath: "/tmp"),
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "App",
            phaseWithheldToolNames: [ToolNames.writeFile]
        )
        XCTAssertEqual(reason, .notInRoleConfig)
    }

    /// The envelope keeps the structured `tool` field — unlike the hallucination
    /// case, this names a real, callable tool — and points at the exit channel.
    func testEnvelope_withheldUntilPlanRecorded_namesTheToolAndTheExitChannel() {
        let call = StepToolCall(name: ToolNames.writeFile, argumentsJSON: "{}")
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call, canonicalName: ToolNames.writeFile,
            scope: "for this role", reason: .withheldUntilPlanRecorded
        )

        XCTAssertTrue(envelope.isError)
        XCTAssertTrue(envelope.outputJSON.contains("plan_required"), envelope.outputJSON)
        XCTAssertTrue(envelope.outputJSON.contains(ToolNames.updateScratchpad), envelope.outputJSON)
        XCTAssertTrue(envelope.outputJSON.contains("\"\(ToolNames.writeFile)\""), envelope.outputJSON)
    }

    /// The rejection is TEMPORAL: the same call works next turn. Steering toward
    /// "pick a different tool" — what every other reason says — would send the
    /// model hunting a substitute that does not exist, and it would never record
    /// the plan that unblocks it.
    /// The whole instruction lives in the ENVELOPE, and that is why `ToolErrorNotePolicy`
    /// adds nothing here: the retired direction paraphrased "record the plan, then call it
    /// again" in different words, which reads as a second, different instruction.
    func testGuidance_planRequired_tellsTheModelToRetryAfterRecordingThePlan() {
        let call = StepToolCall(name: ToolNames.writeFile, argumentsJSON: "{}")
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call, canonicalName: ToolNames.writeFile,
            scope: "for this role", reason: .withheldUntilPlanRecorded
        )
        let message = envelope.outputJSON

        XCTAssertTrue(message.contains(ToolNames.updateScratchpad), message)
        XCTAssertTrue(message.contains("again"), "the retry IS the instruction: \(message)")
        XCTAssertFalse(message.contains("Do not retry"), message)
        XCTAssertFalse(message.contains("different tool"), message)

        XCTAssertNil(
            ToolErrorNotePolicy.direction(for: envelope),
            "the envelope states the remedy AND the retry — a paraphrase is a second instruction"
        )
    }
}
