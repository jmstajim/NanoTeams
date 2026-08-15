import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - create_artifact

nonisolated struct CreateArtifactTool: ToolHandler {
    static let name = TN.createArtifact
    static let schema = ToolSchema(
        name: TN.createArtifact,
        description: baseDescription
            + "\n\nAt runtime the role's expected deliverable names are appended here and constrained on the `name` parameter.",
        parameters: parameterSchema(nameEnum: nil)
    )
    static let category: ToolCategory = .artifact
    static let excludedInMeetings = true

    /// LLM-facing prose. Stays in `Self.schema` as the user-curated tool surface
    /// shown in the role-editor UI; `buildSchema` reuses this string and appends
    /// the per-role expected-deliverables list before handing the schema to the LLM.
    private static let baseDescription =
        "Submit a deliverable artifact. The step ends when all expected deliverables have been submitted."

    private static func parameterSchema(nameEnum: [String]?) -> JSONSchema {
        JS.object(
            properties: [
                "name": JS.string(
                    "Deliverable name.",
                    enumValues: nameEnum
                ),
                "content": JS.string(
                    "Full markdown body of the deliverable."
                ),
                "format": JS.string(
                    "Output format. Non-markdown formats also emit a binary side-car.",
                    enumValues: ["markdown", "pdf", "rtf", "docx"]
                ),
            ],
            required: ["name", "content"]
        )
    }

    /// Builds a per-role `create_artifact` schema with the role's expected
    /// deliverables embedded inline in the description and constrained on the
    /// `name` parameter as a JSON-schema `enum`. Mirrors
    /// `DelegateToTeamTool.buildSchema(role:allTeams:)` — same
    /// inline-context-at-the-decision-point pattern.
    ///
    /// Called from `LLMExecutionService.toolSchemas(for:team:)` step 5 when
    /// `create_artifact` is auto-injected for a role with non-empty
    /// `producesArtifacts`. The static `Self.schema` is the fallback for any
    /// caller without role context (role-editor preview, tests).
    ///
    /// `enumValues` is set to `nil` (not `[]`) when `producesArtifacts` is empty
    /// — most providers treat an empty enum as "no valid value", which would
    /// hard-block the tool. Auto-injection (step 5) gates on
    /// `!producesArtifacts.isEmpty`, so this branch only fires for callers that
    /// explicitly bypass that gate (manual toolset edits, future code paths);
    /// the `isValidArtifactName` runtime guard inside `handle(...)` still
    /// catches the resulting bad calls and routes to a `tool_not_authorized`
    /// envelope so the LLM gets the "don't retry" guidance.
    static func buildSchema(role: TeamRoleDefinition) -> ToolSchema {
        let names = role.dependencies.producesArtifacts
        let nameEnum: [String]? = names.isEmpty ? nil : names
        let listSection: String
        if names.isEmpty {
            listSection = "Expected deliverables for this role: (none configured)"
        } else {
            listSection = "Expected deliverables for this role:\n- "
                + names.joined(separator: "\n- ")
        }
        return ToolSchema(
            name: TN.createArtifact,
            description: baseDescription + "\n\n" + listSection,
            parameters: parameterSchema(nameEnum: nameEnum)
        )
    }

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    /// Accepted `format` values. `markdown`/`md` are no-op pass-throughs
    /// (markdown is the primary artifact body); the other three map to
    /// `DocumentTextExtractor.ExportFormat` for optional binary side-cars.
    private static let allowedFormats: Set<String> = [
        "markdown", "md", "pdf", "rtf", "docx",
    ]

    func handle(context: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // NOT the shared `requiredNonEmptyString` helper, deliberately — see the
            // rejection branch below, which is where an empty name is handled.
            let name = try requiredString(args, "name")
            // BOTH structural keys are excluded, or step 3 of `resolveContentString`
            // ("if exactly one non-excluded string value remains, use it") adopts
            // `format` as the body: `{"name": X, "format": "markdown"}` produced an
            // artifact whose entire content was the word `markdown`, `ok: true`, and an
            // auto-completed step — the empty-content guard below never saw an empty
            // string. `format` is not in `nonContentKeys`, and it is the companion key
            // the worked example in every producing role's system prompt suggests
            // (`NativeLMStudioClient+RequestBuilder`), beside a `content` that is a
            // literal `"..."` placeholder — so "copied the example, dropped the
            // placeholder" lands exactly here. The same exclusion also rescues a REAL
            // body sent under an alias (`{"name": X, "markdown": "# body", "format": …}`),
            // which step 3 previously discarded as ambiguous.
            let content = resolveContentString(args, excludeKeys: ["name", "format"]) ?? ""

            // Defense-in-depth on top of `GeneratedTeamBuilder.stripFileShapedArtifactNames`.
            // The team-level cleanup catches file-shaped names in `produces_artifacts`
            // at install time, but a role can still emit `create_artifact("foo.html", …)`
            // at runtime — typically when the brief lists specific filenames and the
            // model jumps straight to "produce them" instead of producing its declared
            // artifact. The steering message names the role's actual `expectedArtifacts`
            // so the model has a concrete fix-up list (the role's own prompt buries
            // this field in placeholder text and the model frequently misses it).
            //
            // `create_artifact` is auto-injected for roles iff `producesArtifacts` is
            // non-empty (see `LLMExecutionService+ToolResolution.swift` step 5), and
            // `expectedArtifacts` is sourced from the same field. So in the auto-injected
            // path it's always non-empty. But a manual toolset edit (or a future code
            // path that explicitly authorizes the tool without seeding expected artifacts)
            // can reach this branch with an empty list — the prior message rendered
            // `[]` literally, leaving the model nothing to recover with. Surface a
            // distinct error there so the operator sees the config bug instead.
            if !ArtifactConstants.isValidArtifactName(name) {
                if context.expectedArtifacts.isEmpty {
                    // Emit the executor's `tool_not_authorized` envelope shape so
                    // `ToolErrorNotePolicy.direction` routes through the bespoke
                    // "don't retry" branch — the args aren't the cause; the
                    // tool itself shouldn't be in the role's schema. The
                    // generic `commandFailed` envelope falls through to "retry
                    // with correct arguments", which loops the model on a
                    // call that can't succeed.
                    return makeToolNotAuthorizedConfigResult(
                        toolName: Self.name,
                        args: args,
                        message: "create_artifact is not authorized for this role (no declared deliverables). Remove the call, or add producesArtifacts to the role definition."
                    )
                }
                // `isValidArtifactName` rejects two different things, and for a long
                // time both got the filename message — so an EMPTY name was told it
                // "looks like a filename", sending the model to strip an extension it
                // never wrote. The diagnosis splits here; the recovery data does not.
                // That second half is the part a naive fix loses: the old message was
                // wrong about the cause and RIGHT about the cure, because it
                // enumerated the role's declared deliverables — which is exactly what
                // the model that submitted no name at all is least able to supply.
                let list = context.expectedArtifacts.map { "'\($0)'" }.joined(separator: ", ")
                let diagnosis = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Argument 'name' must not be empty."
                    : "Artifact name '\(name)' looks like a filename."
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "\(diagnosis) Your role is expected to produce: [\(list)]. Use one of those names."
                )
            }

            // `content` is `required` in the schema, and the model still omits it. Until now
            // that resolved to `""` and returned `ok:true`: a zero-byte artifact was written
            // to disk, `checkArtifactCompleteness` counted it as the role's deliverable, and
            // the step AUTO-COMPLETED on it. So the pipeline advanced, and the next role
            // received an empty required artifact with no signal that anything had gone
            // wrong — the failure surfaces, if at all, as a downstream role inventing the
            // content it was supposed to be handed. Advertising a parameter as required and
            // then accepting its absence is the mirror of the advertise-then-reject rule.
            //
            // Whitespace-only is the same hole behind a different byte: a body of "\n" is not
            // a deliverable, and a role that has genuinely produced nothing must say so
            // through `ask_supervisor`, not through a blank artifact.
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "Artifact '\(name)' has no content. Pass the full deliverable body in the `content` parameter — it is what the next role receives."
                )
            }

            if let format = optionalString(args, "format"),
               !Self.allowedFormats.contains(format.lowercased()) {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "Unsupported format '\(format)'. Supported: markdown, pdf, rtf, docx. Omit for markdown."
                )
            }

            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["artifact": name, "status": "created"]),
                isError: false,
                signal: .artifact(name: name, content: content, format: optionalString(args, "format"))
            )
        }
    }
}
