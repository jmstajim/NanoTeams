import XCTest

@testable import NanoTeams

/// Run 6 regression: CR called `create_artifact(format: "zip", ...)` and the
/// handler silently accepted it, producing a broken artifact. Unsupported
/// formats must now return an actionable error envelope.
final class CreateArtifactFormatValidationTests: XCTestCase {

    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try FileManager.default.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: 0,
            runID: 0,
            roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    func testCreateArtifact_unsupportedFormat_returnsError() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Code Review\",\"content\":\"# r\",\"format\":\"zip\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertTrue(results[0].isError, "zip must be rejected")
        let out = results[0].outputJSON
        XCTAssertTrue(out.contains("Unsupported format"), "Error message must be actionable")
        XCTAssertTrue(out.contains("markdown") && out.contains("pdf") && out.contains("rtf") && out.contains("docx"),
                      "Error must list supported formats")
    }

    // MARK: - File-shaped name rejection (defense-in-depth on top of GeneratedTeamBuilder cleanup)

    /// Regression: tasks/8/subtasks/9 — Frontend Developer called
    /// `create_artifact("index.html", …)` instead of `write_file("index.html", …)`.
    /// The team-level cleanup catches this in generated configs, but a runtime guard
    /// on `create_artifact` covers user-curated teams + LLMs that hallucinate
    /// file-shaped names regardless of their team's `produces_artifacts`.
    func testCreateArtifact_fileShapedHTMLName_rejected() throws {
        // Realistic context: the role has a declared deliverable (`create_artifact`
        // is auto-injected only for roles with non-empty producesArtifacts).
        let ctx = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role",
            expectedArtifacts: ["Implementation Notes"]
        )
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"index.html\",\"content\":\"<html></html>\"}"
        )
        let results = runtime.executeAll(context: ctx, toolCalls: [call])
        XCTAssertTrue(results[0].isError, "index.html must be rejected as file-shaped")
        let out = results[0].outputJSON
        XCTAssertTrue(out.contains("looks like a filename"), "Error must explain the rejection: \(out)")
        XCTAssertTrue(out.contains("Implementation Notes"),
                      "Error must surface the role's declared deliverable: \(out)")
    }

    func testCreateArtifact_fileShapedSwiftName_rejected() throws {
        let ctx = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role",
            expectedArtifacts: ["Code Review"]
        )
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Calculator.swift\",\"content\":\"struct C {}\"}"
        )
        let results = runtime.executeAll(context: ctx, toolCalls: [call])
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Code Review"))
    }

    /// Regression: tasks/10/subtasks/11 — Архитектор продукта (architect role)
    /// with `produces_artifacts: ["Спецификация калькулятора"]` repeatedly tried
    /// `create_artifact("index.html", …)` because its prompt buried the declared
    /// deliverable in placeholder text and the brief listed concrete filenames.
    /// The error message must surface the role's actual expected names so the
    /// model has a concrete fix-up list, not just a generic "use Implementation
    /// Notes" hint that doesn't apply to its team's chosen deliverable name.
    func testCreateArtifact_fileShapedName_messageIncludesExpectedArtifacts() throws {
        let contextWithExpected = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: 0, runID: 0, roleID: "architect_role",
            expectedArtifacts: ["Спецификация калькулятора"]
        )
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"index.html\",\"content\":\"<html></html>\"}"
        )
        let results = runtime.executeAll(context: contextWithExpected, toolCalls: [call])
        XCTAssertTrue(results[0].isError)
        let out = results[0].outputJSON
        XCTAssertTrue(out.contains("looks like a filename"),
                      "Error must keep the diagnosis prefix: \(out)")
        XCTAssertTrue(out.contains("Спецификация калькулятора"),
                      "Error must name the role's actual expected artifact: \(out)")
        XCTAssertTrue(out.contains("Use one of those names"),
                      "Error must steer the model toward the expected list: \(out)")
        // When expected artifacts are listed, the generic "use write_file" fallback
        // must NOT appear (would dilute the targeted hint with an alternative path
        // the role often can't take — e.g. architect roles don't have write_file).
        XCTAssertFalse(out.contains("write_file"),
                       "When expected artifacts are provided, write_file fallback must not be added: \(out)")
    }

    /// Empty-expectedArtifacts path: a manual toolset edit (or future code path)
    /// could authorize `create_artifact` for a role with no declared deliverables.
    /// Pre-fix the error message rendered as `Your role is expected to produce: []`,
    /// leaving the model nothing to recover with. Post-fix this returns a
    /// `tool_not_authorized` envelope that surfaces the config bug AND routes
    /// through the bespoke "don't retry" guidance instead of the misleading
    /// generic "retry with correct arguments" suffix (which doesn't help — the
    /// args aren't the cause; the tool itself shouldn't be in the schema).
    func testCreateArtifact_fileShapedNameWithEmptyExpected_surfacesConfigError() throws {
        let ctx = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "misconfigured_role",
            expectedArtifacts: []
        )
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"index.html\",\"content\":\"<html></html>\"}"
        )
        let results = runtime.executeAll(context: ctx, toolCalls: [call])
        XCTAssertTrue(results[0].isError)
        let out = results[0].outputJSON
        XCTAssertTrue(
            out.contains("not authorized") || out.contains("no declared deliverables"),
            "Empty-expected path must surface the config bug, not render '[]': \(out)"
        )
        // The "use one of those names" message is the failure-mode-specific text
        // we MUST NOT see when expectedArtifacts is empty (the message renders
        // a literal `[]` after the bullet list, leaving the model with no
        // recovery options). Note: `out` contains an envelope `"warnings":[]`
        // by construction — that's NOT the same `[]` we're guarding against.
        XCTAssertFalse(
            out.contains("Use one of those names"),
            "Empty-expected path must NOT render the no-name list message: \(out)"
        )
    }

    /// Pinned envelope shape: emit `tool_not_authorized` (top-level error
    /// literal) so `ToolErrorNotePolicy.direction` lands in the bespoke
    /// "don't retry" branch rather than the generic default. A `commandFailed`
    /// envelope here would route to "Retry the tool call with the correct
    /// arguments" — actively misleading because args aren't the cause.
    func testCreateArtifact_emptyExpected_emitsToolNotAuthorizedShape() throws {
        let ctx = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "misconfigured_role",
            expectedArtifacts: []
        )
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"index.html\",\"content\":\"<html></html>\"}"
        )
        let results = runtime.executeAll(context: ctx, toolCalls: [call])
        XCTAssertTrue(results[0].isError)
        let out = results[0].outputJSON
        XCTAssertTrue(
            out.contains(#""error":"tool_not_authorized""#),
            "Empty-expected path must emit the executor's tool_not_authorized shape so guidance routes to the don't-retry branch: \(out)"
        )
        XCTAssertFalse(
            out.contains(#""code":"COMMAND_FAILED""#),
            "Pre-fix shape (commandFailed) routed to the misleading 'retry with correct arguments' default branch: \(out)"
        )
    }

    func testCreateArtifact_conceptualName_accepted() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Implementation Notes\",\"content\":\"# notes\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError, "Conceptual name must be accepted: \(results[0].outputJSON)")
    }

    func testCreateArtifact_markdownExtensionInName_accepted() throws {
        // `report.md` is a valid artifact name (matches an allowed format extension).
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"report.md\",\"content\":\"# r\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError, "report.md must be accepted: \(results[0].outputJSON)")
    }

    // MARK: - Original format-validation tests below

    func testCreateArtifact_markdownFormat_accepted() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Plan\",\"content\":\"# plan\",\"format\":\"markdown\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
    }

    func testCreateArtifact_mdAlias_accepted() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Plan\",\"content\":\"# plan\",\"format\":\"md\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
    }

    func testCreateArtifact_pdfFormat_accepted() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Plan\",\"content\":\"# plan\",\"format\":\"pdf\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
    }

    /// Case-insensitive match per whitelist design.
    func testCreateArtifact_uppercaseFormat_accepted() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Plan\",\"content\":\"# plan\",\"format\":\"DOCX\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
    }

    func testCreateArtifact_noFormat_accepted() throws {
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Plan\",\"content\":\"# plan\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
    }

    // MARK: - Reentrant envelope through the runtime

    /// End-to-end: `{"name":"create_artifact","arguments":{"name":"CalculatorDemo",...}}`
    /// → unwrap kicks in → handler sees `name="CalculatorDemo"`. In Run 6 the
    /// artifact was literally named `create_artifact`. Strict assertions ensure
    /// that deleting `unwrapReentrantEnvelope` fails this test — a loose
    /// `contains("CalculatorDemo")` would still pass because CalculatorDemo
    /// survives in `argumentsJSON`.
    func testCreateArtifact_reentrantEnvelope_usesInnerName() throws {
        let argsJSON = "{\"name\":\"create_artifact\",\"arguments\":{\"name\":\"CalculatorDemo\",\"content\":\"# x\"}}"
        let call = StepToolCall(name: "create_artifact", argumentsJSON: argsJSON)
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)

        // The signal carries the canonical artifact name — the persistence path
        // in `LLMExecutionService` keys on this, not on `outputJSON` strings.
        guard case .artifact(let name, _, _) = results[0].signal else {
            XCTFail("Expected .artifact signal, got \(String(describing: results[0].signal))")
            return
        }
        XCTAssertEqual(name, "CalculatorDemo",
                       "Signal must carry the inner artifact name — Run 6 bug put 'create_artifact' here.")

        // Output envelope must also spell out the inner name so the LLM observes
        // the correct artifact in its tool-result view.
        XCTAssertTrue(results[0].outputJSON.contains("\"artifact\":\"CalculatorDemo\""),
                      "Output envelope must announce the inner name, not the outer tool name.")
        XCTAssertFalse(results[0].outputJSON.contains("\"artifact\":\"create_artifact\""),
                       "Outer tool name must not become the artifact name.")
    }

    /// Prefixed outer name (`functions.create_artifact`) must also unwrap.
    /// This is the C2 review fix: `unwrapReentrantEnvelope` now canonicalizes
    /// both sides of the name comparison.
    func testCreateArtifact_reentrantEnvelope_prefixedOuterName_unwraps() throws {
        let argsJSON = "{\"name\":\"functions.create_artifact\",\"arguments\":{\"name\":\"PlanDoc\",\"content\":\"...\"}}"
        let call = StepToolCall(name: "create_artifact", argumentsJSON: argsJSON)
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        guard case .artifact(let name, _, _) = results[0].signal else {
            XCTFail("Expected .artifact signal")
            return
        }
        XCTAssertEqual(name, "PlanDoc",
                       "Prefixed outer name must still canonicalize and unwrap to inner dict.")
    }

    // MARK: - Per-role schema (`buildSchema`)

    /// The role's expected deliverables must appear in the description so the
    /// model sees them at the point of decision (not buried in the system prompt).
    func testBuildSchema_perRole_inlinesExpectedArtifactsInDescription() throws {
        let role = makeRoleFixture(producesArtifacts: ["Implementation Plan", "Engineering Notes"])
        let schema = CreateArtifactTool.buildSchema(role: role)
        let description = schema.description
        XCTAssertTrue(description.contains("Implementation Plan"),
                      "Description must inline expected deliverables: \(description)")
        XCTAssertTrue(description.contains("Engineering Notes"),
                      "Description must inline expected deliverables: \(description)")
        XCTAssertTrue(description.contains("Expected deliverables for this role:"),
                      "Description must label the inlined list: \(description)")
    }

    /// `name` parameter must carry an `enum` constraint exactly equal to the
    /// role's `producesArtifacts`. Schema-enforcing providers reject unknown
    /// names client-side; LM Studio doesn't enforce, so the existing post-hoc
    /// `isValidArtifactName` rejection is the second line of defense.
    func testBuildSchema_perRole_nameParameterUsesEnumConstraint() throws {
        let producesArtifacts = ["Code Review", "Release Notes"]
        let role = makeRoleFixture(producesArtifacts: producesArtifacts)
        let schema = CreateArtifactTool.buildSchema(role: role)
        guard let nameProp = schema.parameters.properties?["name"] else {
            XCTFail("Schema must declare `name` parameter")
            return
        }
        XCTAssertEqual(nameProp.enumValues, producesArtifacts,
                       "`name` enum must exactly mirror role.producesArtifacts")
    }

    /// Empty-`producesArtifacts` path: `enumValues` must be `nil`, not `[]`.
    /// Most providers treat an empty enum as "no valid value", which would
    /// hard-block the tool. Auto-injection (step 5 in `toolSchemas(for:team:)`)
    /// gates on non-empty `producesArtifacts`, so this branch is reachable only
    /// via callers that bypass that gate; the runtime guard catches the result.
    func testBuildSchema_emptyProducesArtifacts_omitsEnumConstraint() throws {
        let role = makeRoleFixture(producesArtifacts: [])
        let schema = CreateArtifactTool.buildSchema(role: role)
        guard let nameProp = schema.parameters.properties?["name"] else {
            XCTFail("Schema must declare `name` parameter")
            return
        }
        XCTAssertNil(nameProp.enumValues,
                     "Empty `producesArtifacts` must produce nil enum, not [] (providers treat [] as no-valid-value)")
    }

    /// `LLMExecutionService.toolSchemas(for:team:)` step 5 must SUBSTITUTE the
    /// per-role `create_artifact` schema (with deliverables inlined in
    /// description AND enum-constrained `name` parameter) for the static
    /// fallback. The unit-level test above verifies the per-role schema in
    /// isolation; this test pins the wiring at `toolSchemas` so a regression
    /// that wires `allTools.first(where: { $0.name == createArtifact })` back
    /// in (silent revert to the static schema) fails here.
    @MainActor
    func testToolSchemas_pipelineSubstitutesPerRoleSchema() throws {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        let role = TeamRoleDefinition(
            id: UUID().uuidString,
            name: "Engineer",
            prompt: "Implement the plan.",
            toolIDs: [
                ToolNames.readFile, ToolNames.writeFile,
                ToolNames.updateScratchpad,
            ],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Implementation Plan"],
                producesArtifacts: ["Engineering Notes", "Test Plan"]
            )
        )
        let team = Team(
            name: "Eng", roles: [role], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )

        let schemas = service.toolSchemas(for: .custom(id: "Engineer"), team: team)
        guard let createArtifactSchema = schemas.first(where: { $0.name == ToolNames.createArtifact }) else {
            XCTFail("Pipeline must auto-inject create_artifact for a role with producesArtifacts")
            return
        }

        // Description-side: per-role schema inlines deliverables.
        XCTAssertTrue(
            createArtifactSchema.description.contains("Engineering Notes"),
            "Pipeline must use per-role schema (description carries the role's deliverables); regression: \(createArtifactSchema.description)"
        )
        XCTAssertTrue(
            createArtifactSchema.description.contains("Test Plan"),
            "Pipeline must include every declared deliverable in the description: \(createArtifactSchema.description)"
        )

        // Parameter-side: enum constraint mirrors role.producesArtifacts. The
        // static fallback (CreateArtifactTool.schema) has `enumValues: nil`
        // here — that's the regression marker.
        guard let nameProp = createArtifactSchema.parameters.properties?["name"] else {
            XCTFail("Schema must declare `name` parameter")
            return
        }
        XCTAssertEqual(
            nameProp.enumValues,
            ["Engineering Notes", "Test Plan"],
            "Pipeline must use the per-role enum constraint, not the static fallback (which is nil)."
        )
    }

    /// Locks in the "no sibling tool references" rule: a tool's description
    /// must stand on its own. Sibling tools may not be in the role's toolset
    /// (e.g. an advisory role with `create_artifact` may not have `write_file`),
    /// and pointing the model at unavailable tools causes hallucinated calls
    /// or stuck loops.
    func testBuildSchema_descriptionDoesNotReferenceOtherTools() throws {
        let role = makeRoleFixture(producesArtifacts: ["Implementation Plan"])
        let schema = CreateArtifactTool.buildSchema(role: role)
        let description = schema.description
        for sibling in ["write_file", "edit_file", "delete_file", "read_file", "ask_supervisor"] {
            XCTAssertFalse(description.contains(sibling),
                           "Description must not reference sibling tool '\(sibling)': \(description)")
        }
    }

    // MARK: - Empty content

    /// `content` is declared `required` in the schema. It was not enforced anywhere: the
    /// handler resolved it with `?? ""` and carried on, so `{"name": "Release Notes"}` alone
    /// returned `ok:true`, wrote a zero-byte artifact, and `checkArtifactCompleteness`
    /// counted that as the role's deliverable and auto-completed the step.
    ///
    /// The damage is downstream and silent: the next role's required artifact is injected
    /// into its prompt EMPTY, and nothing in the pipeline distinguishes "produced nothing"
    /// from "produced this". The role that receives it typically invents the missing content.
    ///
    /// RED: restore `let content = resolveContentString(...) ?? ""` without the guard →
    /// `isError` is false and the artifact is persisted.
    func testCreateArtifact_contentOmitted_isRejectedRatherThanSilentlyEmpty() throws {
        let ctx = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role",
            expectedArtifacts: ["Release Notes"]
        )
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Release Notes\"}"
        )

        let results = runtime.executeAll(context: ctx, toolCalls: [call])

        XCTAssertTrue(results[0].isError, "got: \(results[0].outputJSON)")
        let out = results[0].outputJSON
        XCTAssertTrue(out.contains("no content"), "the message must name the problem: \(out)")
        // NOT `out.contains("content")` — that is implied by the line above and pins
        // nothing. The parameter has to be named as a parameter the model can copy.
        XCTAssertTrue(out.contains("`content`"),
                      "the message must name the parameter to pass: \(out)")
        XCTAssertTrue(out.contains("Release Notes"),
                      "and the artifact it was asked for: \(out)")
    }

    /// The guard above is fed by `resolveContentString(args, excludeKeys:)`, whose step 3
    /// adopts "the single remaining String value" as the body. `format` was not excluded,
    /// so the most likely omission shape of all — the one the worked example in every
    /// producing role's system prompt suggests, `{"name": …, "content": "...", "format":
    /// "markdown"}` with the placeholder dropped — resolved the body to the word
    /// `markdown`, returned ok:true, wrote an eight-byte artifact and auto-completed the
    /// step. The guard never saw an empty string; the defect was upstream of it.
    ///
    /// RED: `excludeKeys: ["name", "format"]` → `["name"]` → every case here returns
    /// ok:true with the format string as the deliverable.
    func testCreateArtifact_formatWithoutContent_isStillRejected() throws {
        for format in ["markdown", "pdf", "docx"] {
            let ctx = ToolExecutionContext(
                workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role",
                expectedArtifacts: ["Release Notes"]
            )
            let call = StepToolCall(
                name: "create_artifact",
                argumentsJSON: "{\"name\":\"Release Notes\",\"format\":\"\(format)\"}"
            )

            let results = runtime.executeAll(context: ctx, toolCalls: [call])

            XCTAssertTrue(
                results[0].isError,
                "format=\(format) must not become the deliverable: \(results[0].outputJSON)")
            XCTAssertTrue(results[0].outputJSON.contains("no content"),
                          "format=\(format): \(results[0].outputJSON)")
        }
    }

    /// The same exclusion rescues a REAL body sent under an alias beside a format. Step 3
    /// used to see two surviving strings, call it ambiguous, and return nil — so a genuine
    /// deliverable was rejected as empty.
    ///
    /// RED: revert the `format` exclusion → two candidates survive, content resolves to
    /// nil, and this real body is rejected with "no content".
    func testCreateArtifact_aliasedBodyBesideAFormat_isAccepted() throws {
        let ctx = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role",
            expectedArtifacts: ["Release Notes"]
        )
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON:
            "{\"name\":\"Release Notes\",\"markdown\":\"# Real body\",\"format\":\"markdown\"}"
        )

        let results = runtime.executeAll(context: ctx, toolCalls: [call])

        XCTAssertFalse(results[0].isError, "got: \(results[0].outputJSON)")
    }

    /// A non-String `content` (null, or an array of lines) is skipped by step 3's
    /// `value is String` test, so `format` used to become the single survivor even when
    /// the model DID send the key. Same guard, same root.
    ///
    /// RED: revert the `format` exclusion → both return ok:true with the format as body.
    func testCreateArtifact_nonStringContentBesideAFormat_isRejected() throws {
        for body in ["null", "[\"a\",\"b\"]"] {
            let ctx = ToolExecutionContext(
                workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role",
                expectedArtifacts: ["Release Notes"]
            )
            let call = StepToolCall(
                name: "create_artifact",
                argumentsJSON:
                "{\"name\":\"Release Notes\",\"content\":\(body),\"format\":\"pdf\"}"
            )

            let results = runtime.executeAll(context: ctx, toolCalls: [call])

            XCTAssertTrue(results[0].isError,
                          "content=\(body): \(results[0].outputJSON)")
        }
    }

    /// Whitespace-only is the same hole behind a different byte. A model that answers the
    /// "you must pass content" nudge with `"\n"` would otherwise walk straight back through.
    ///
    /// RED: change the guard to `content.isEmpty` → this passes the empty check and succeeds.
    func testCreateArtifact_whitespaceOnlyContent_isRejectedToo() throws {
        let ctx = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role",
            expectedArtifacts: ["Release Notes"]
        )
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Release Notes\",\"content\":\"  \\n\\t \"}"
        )

        let results = runtime.executeAll(context: ctx, toolCalls: [call])

        XCTAssertTrue(results[0].isError, "got: \(results[0].outputJSON)")
    }

    /// Anti-vacuity for both cases above: the guard must not have made the tool reject
    /// ordinary submissions. A one-character body is a legitimate deliverable as far as this
    /// handler is concerned — judging SUFFICIENCY is the Supervisor's job, not the tool's.
    ///
    /// RED: same mutation as the two above, inverted — a guard that rejects non-empty content
    /// fails here.
    func testCreateArtifact_minimalNonEmptyContent_stillSucceeds() throws {
        let ctx = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role",
            expectedArtifacts: ["Release Notes"]
        )
        let call = StepToolCall(
            name: "create_artifact",
            argumentsJSON: "{\"name\":\"Release Notes\",\"content\":\"x\"}"
        )

        let results = runtime.executeAll(context: ctx, toolCalls: [call])

        XCTAssertFalse(results[0].isError, "got: \(results[0].outputJSON)")
    }

    private func makeRoleFixture(producesArtifacts: [String]) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "test_role_\(UUID().uuidString.prefix(8))",
            name: "Test Role",
            prompt: "test prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: producesArtifacts
            )
        )
    }
}
