import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - create_team

nonisolated struct CreateTeamTool: ToolHandler {
    static let name = TN.createTeam
    // The JSONSchema model only nests 2 deep (object → property → leaf), so the
    // recursive shape (team → roles → produces_artifacts) cannot be expressed
    // structurally. We declare team_config as a string and document the schema in
    // the description; the handler accepts both string and parsed-object forms
    // for providers that loosen the schema.
    static let schema = ToolSchema(
        name: TN.createTeam,
        description: """
        Create a new team configuration for this task. The Supervisor role is added automatically; \
        give roles "Supervisor Task" in their requires_artifacts to start them first. Call exactly once — \
        the step auto-completes and the generated team begins execution.
        """,
        parameters: JS.object(
            properties: [
                "team_config": JS.string("Complete team configuration as a JSON object: name, description, supervisor_mode, acceptance_mode, roles[], artifacts[], supervisor_requires[]."),
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

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // team_config can arrive as a dict (parsed JSON) or as a string (raw JSON).
            // We surface re-serialization failures explicitly rather than masquerading as
            // "invalid JSON" downstream.
            let jsonData: Data
            if let configDict = args["team_config"] as? [String: Any] {
                // `isValidJSONObject` FIRST, and it is not belt-and-braces: for a value JSON
                // cannot express (NaN, a Date, a non-String key) `data(withJSONObject:)` raises
                // an ObjC `NSInvalidArgumentException` — it does NOT throw, so no Swift `catch`
                // can see it and the process dies. Measured against Foundation, 2026-08-08 and
                // re-measured 2026-08-09.
                // Not reachable from the runtime (arguments arrive JSON-parsed, so every value
                // is already JSON-native), but this arm exists precisely for the caller shape
                // that hands over a Swift dictionary, and it has to be true for one.
                //
                // This guard is therefore the ONLY defence, which is why the call below carries no
                // local `do`/`catch`: one used to sit there returning a "could not serialize"
                // envelope, and it read as a second line of defence — so a later edit could delete
                // this guard believing the catch covered the case, which is the one edit that
                // turns a bad argument into a crash.
                //
                // The catch was not merely redundant, it was unreachable — and the reason is worth
                // recording because it is NOT "a valid object cannot fail to serialize". Two input
                // families could in principle get past this guard and still fail the write, and
                // they are closed by DIFFERENT mechanisms:
                //
                //  - Nesting depth: closed by the guard itself. `isValidJSONObject` enforces the
                //    same limit the writer does (valid through 510, invalid from 511), so there is
                //    no band where Foundation calls an object valid and then refuses to write it.
                //  - An unencodable dictionary KEY: NOT closed by the guard. `isValidJSONObject`
                //    checks string VALUES for UTF-8 convertibility but not keys, so a Swift String
                //    backed by a lone surrogate passes it and the write then THROWS
                //    `NSCocoaErrorDomain` 3852 — an ordinary Swift error a catch would see. What
                //    closes it is the PARSER upstream, not the writer: `JSONSerialization` rejects
                //    `"\uDC00"` at parse time with error 3840, and `ToolRuntime` builds every
                //    handler's `args` from `jsonObject`, so no tool-call payload a model can emit
                //    reaches this arm carrying such a key. Only a caller handing over a hand-built
                //    Swift dictionary can, and there is none — `TeamGenerationService` references
                //    `CreateTeamTool.schema` and never invokes the handler.
                //
                // All three figures measured against Foundation on 2026-08-09.
                //
                // A theoretical throw is handled by the enclosing `ToolErrorHandler.execute`,
                // which is what that wrapper is for.
                guard JSONSerialization.isValidJSONObject(configDict) else {
                    return ToolExecutionResult(
                        toolName: Self.name,
                        argumentsJSON: encodeArgsToJSON(args),
                        outputJSON: makeErrorEnvelope(
                            code: .invalidArgs,
                            message: "team_config contains a value JSON cannot represent "
                                + "(NaN/infinity, a non-string key, or a non-JSON type)."
                        ),
                        isError: true
                    )
                }
                jsonData = try JSONSerialization.data(withJSONObject: configDict)
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
nonisolated private func decodingMessage(_ error: Error) -> String {
    guard let decoding = error as? DecodingError else { return error.localizedDescription }

    // `dataCorrupted` is OUR text: every `GeneratedTeamConfig` validation message
    // already names its own field ("Unknown supervisor_mode 'x'. Allowed: …"), and
    // the unknown-artifact one is merely ANCHORED to `.artifacts` while describing
    // a role's reference — a path suffix there would point at the wrong place. So
    // that arm stays byte-identical and only the Swift-synthesized ones get a path.
    //
    // That rationale is no longer universally true, and the reason it stays is
    // reachability, not correctness: the empty-`prompt` guard added to
    // `RoleConfig` is the first `dataCorrupted` thrown from inside an array
    // ELEMENT, where the field name alone cannot say WHICH role and the index
    // lives only in the coding path this arm drops. But `CreateTeamTool` is
    // `availableToRoles = false` — filtered from every role's schema via
    // `ToolHandlerRegistry.unavailableToRoles` — so no model reaches this renderer;
    // team generation goes through `TeamConfigParser.decodeTeamConfig`, whose
    // `describeDecodingError` DOES append the path, and that is the path pinned by
    // `TeamConfigParserTests`. Changing this arm would be insurance against a
    // reachability flip that has not happened.
    let ctx: DecodingError.Context
    switch decoding {
    case .dataCorrupted(let c):
        return c.debugDescription
    case .keyNotFound(_, let c),
         .typeMismatch(_, let c),
         .valueNotFound(_, let c):
        ctx = c
    @unknown default:
        return error.localizedDescription
    }

    // The coding path is the half that says WHERE. `debugDescription` carries the
    // key only for `keyNotFound`; `valueNotFound` and `typeMismatch` report what
    // went wrong and never where ("Cannot get value of type String -- found null
    // value instead"), which leaves the model re-emitting a whole team_config to
    // hunt one null.
    guard !ctx.codingPath.isEmpty else { return ctx.debugDescription }
    var path = ""
    for key in ctx.codingPath {
        if let index = key.intValue {
            path += "[\(index)]"
        } else if path.isEmpty {
            path += key.stringValue
        } else {
            path += ".\(key.stringValue)"
        }
    }
    return "\(ctx.debugDescription) (at `\(path)`)"
}
