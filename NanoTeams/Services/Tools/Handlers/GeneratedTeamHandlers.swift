import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - create_team

struct CreateTeamTool: ToolHandler {
    static let name = TN.createTeam
    // The JSONSchema model only nests 2 deep (object → property → leaf), so the
    // recursive shape (team → roles → produces_artifacts) cannot be expressed
    // structurally. We declare team_config as a string and document the schema in
    // the description; the handler accepts both string and parsed-object forms
    // for providers that loosen the schema.
    static let schema = ToolSchema(
        name: TN.createTeam,
        description: """
            Create a new team configuration for this task. The team_config parameter is a JSON object with: \
            name (string), description (string), supervisor_mode ("manual"|"autonomous"), acceptance_mode ("finalOnly"|"afterEachRole"|"afterEachArtifact"), \
            roles (array of {name, prompt, produces_artifacts:[], requires_artifacts:[], tools:[], use_planning_phase?, icon?, icon_background?}), \
            artifacts (array of {name, description, icon?}), supervisor_requires (array of artifact names the Supervisor reviews). \
            Supervisor role is added automatically. Use "Supervisor Task" as requires_artifacts for roles that start first. \
            Call exactly once — your step auto-completes and the generated team begins execution.
            """,
        parameters: JS.object(
            properties: [
                "team_config": JS.string("Complete team configuration as a JSON object. See tool description for the schema."),
            ],
            required: ["team_config"]
        )
    )
    static let category: ToolCategory = .collaboration
    static let excludedInMeetings = true
    /// Never offered to team roles — invoked exclusively via `TeamGenerationService`
    /// during the Generated Team flow. Kept in the registry so tests can drive the
    /// handler directly through `ToolRuntime`.
    static let availableToRoles = false

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // team_config can arrive as a dict (parsed JSON) or as a string (raw JSON).
            // We surface re-serialization failures explicitly rather than masquerading as
            // "invalid JSON" downstream.
            let jsonData: Data
            if let configDict = args["team_config"] as? [String: Any] {
                do {
                    jsonData = try JSONSerialization.data(withJSONObject: configDict)
                } catch {
                    return ToolExecutionResult(
                        toolName: Self.name,
                        argumentsJSON: encodeArgsToJSON(args),
                        outputJSON: makeErrorEnvelope(
                            code: .invalidArgs,
                            message: "Could not serialize team_config object: \(error.localizedDescription)"
                        ),
                        isError: true
                    )
                }
            } else if let configString = args["team_config"] as? String,
                      let data = configString.data(using: .utf8) {
                jsonData = data
            } else {
                return ToolExecutionResult(
                    toolName: Self.name,
                    argumentsJSON: encodeArgsToJSON(args),
                    outputJSON: makeErrorEnvelope(code: .invalidArgs, message: "Missing required 'team_config' parameter"),
                    isError: true
                )
            }

            let config: GeneratedTeamConfig
            do {
                let decoder = JSONCoderFactory.makeWireDecoder()
                config = try decoder.decode(GeneratedTeamConfig.self, from: jsonData)
            } catch {
                return ToolExecutionResult(
                    toolName: Self.name,
                    argumentsJSON: encodeArgsToJSON(args),
                    outputJSON: makeErrorEnvelope(
                        code: .invalidArgs,
                        message: "Invalid team_config: \(decodingMessage(error)) Use snake_case keys (produces_artifacts, requires_artifacts, supervisor_requires)."
                    ),
                    isError: true
                )
            }

            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: [
                    "team": config.name,
                    "roles": "\(config.roles.count)",
                    "status": "created",
                ]),
                isError: false,
                signal: .teamCreation(config: config)
            )
        }
    }
}

/// Extract a human-readable message from a `DecodingError`. `localizedDescription`
/// alone returns a generic phrase ("data couldn't be read"); we want the
/// `debugDescription` so the LLM sees the actual validation failure ("Team must
/// have at least one role.").
private func decodingMessage(_ error: Error) -> String {
    if let decoding = error as? DecodingError {
        switch decoding {
        case .dataCorrupted(let ctx),
             .keyNotFound(_, let ctx),
             .typeMismatch(_, let ctx),
             .valueNotFound(_, let ctx):
            return ctx.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }
    return error.localizedDescription
}
