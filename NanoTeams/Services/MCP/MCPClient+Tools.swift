import Foundation

/// Catalogue paging (`tools/list`, `resources/list`, `resources/templates/list`, `prompts/list`)
/// and invocation (`tools/call`, `resources/read`, `prompts/get`).
///
/// Every item listed here goes through `MCPPinHasher` + `MCPTrustStore` before it can reach a
/// prompt or a user picker, and every returned payload passes through `scrubbingOwnSecrets` so
/// credentials this client sent the server cannot be echoed back into a prompt.
extension MCPClient {

    /// Every page of `tools/list`, in the server's order.
    ///
    /// The page cap is not politeness. A server that keeps handing back a fresh `nextCursor`
    /// would hold the connect path open forever, and the connect path is what a role's first
    /// step waits on.
    func listAllTools() async throws -> [JSONValue] {
        let (tools, pages) = try await listAllPages(
            method: MCPWire.toolsListMethod,
            extract: { result in
                let page = MCPWire.toolsPage(from: result)
                return (page.tools, page.nextCursor)
            })
        let resources = advertisesResources ? (try await listAllResources()) : []
        let templates = advertisesResources ? (try await listAllResourceTemplates()) : []
        let prompts = advertisesPrompts ? (try await listAllPrompts()) : []
        listedExtras.store(resources: resources, resourceTemplates: templates, prompts: prompts)
        noteListed(toolCount: tools.count, pages: pages)
        return tools
    }

    /// Every page of `resources/list`, in the server's order.
    func listAllResources() async throws -> [JSONValue] {
        let (resources, _) = try await listAllPages(
            method: MCPWire.resourcesListMethod,
            extract: { result in
                let page = MCPWire.resourcesPage(from: result)
                return (page.resources, page.nextCursor)
            })
        return resources
    }

    /// Every page of `resources/templates/list`, in the server's order. Returns `[]` when a
    /// server that advertises `resources` does not implement `resources/templates/list`
    /// (`-32601` `methodNotFound`).
    func listAllResourceTemplates() async throws -> [JSONValue] {
        do {
            let (templates, _) = try await listAllPages(
                method: MCPWire.resourceTemplatesListMethod,
                extract: { result in
                    let page = MCPWire.resourceTemplatesPage(from: result)
                    return (page.resourceTemplates, page.nextCursor)
                })
            return templates
        } catch MCPClientError.rpc(let code, _, _) where code == MCPErrorCode.methodNotFound {
            return []
        }
    }

    /// Every page of `prompts/list`, in the server's order.
    func listAllPrompts() async throws -> [JSONValue] {
        let (prompts, _) = try await listAllPages(
            method: MCPWire.promptsListMethod,
            extract: { result in
                let page = MCPWire.promptsPage(from: result)
                return (page.prompts, page.nextCursor)
            })
        return prompts
    }

    private func listAllPages(
        method: String,
        extract: (JSONValue) -> (items: [JSONValue], nextCursor: String?)
    ) async throws -> (items: [JSONValue], pages: Int) {
        var items: [JSONValue] = []
        var cursor: String?
        var pages = 0

        repeat {
            pages += 1
            guard pages <= MCPConstants.maxToolsListPages else {
                throw MCPClientError.pageLimitExceeded(MCPConstants.maxToolsListPages)
            }
            let result = try await call(
                method: method,
                params: MCPWire.toolsListParams(cursor: cursor),
                hints: .none,
                timeout: timeouts.connect)
            let page = extract(result)
            items.append(contentsOf: page.items)
            // A cursor that repeats itself is the same loop wearing a different hat, and the
            // page cap alone would spend a hundred round trips discovering it.
            if let next = page.nextCursor, next == cursor {
                throw MCPClientError.malformedResult("the server repeated its page cursor")
            }
            cursor = page.nextCursor
        } while cursor != nil

        return (items, pages)
    }

    /// Runs one tool.
    ///
    /// `originalName` — never the folded model-facing one. The fold is lossy by construction
    /// (`MCPToolNaming`), so sending it would be sending a name the server may not have, or
    /// worse, a DIFFERENT tool whose name folds to the same thing.
    ///
    /// The result comes back without this server's own secrets in it (`scrubbingOwnSecrets`).
    ///
    /// The call names itself as its progress token: a spec-conforming server reports progress
    /// only under a token the request supplied — the Python and TS SDKs make `report_progress`
    /// a no-op without one — so without it a long tool that was working and reporting was
    /// timed out at the inactivity budget as a silent one. No request carried a token until
    /// 2026-09-23 (F9).
    func callTool(
        originalName: String,
        arguments: JSONValue,
        headerParameters: [String: String] = [:]
    ) async throws -> MCPCallToolResult {
        let result = try await call(
            method: MCPWire.toolsCallMethod,
            params: MCPWire.toolsCallParams(name: originalName, arguments: arguments),
            hints: MCPSendHints(name: originalName, headerParameters: headerParameters),
            reportsProgress: true)
        return Self.scrubbingOwnSecrets(
            from: MCPWire.callResult(from: result), literals: credentials().literals)
    }

    /// Reads one resource by URI (`resources/read`).
    ///
    /// Sends `Mcp-Name: <uri>` in the modern era via `MCPSendHints(name: uri)`, converts the
    /// returned `contents` list into `resource` content blocks, and scrubs any echoed server
    /// secrets from text while leaving binary `blob` payloads untouched.
    func readResource(uri: String) async throws -> MCPCallToolResult {
        let result = try await call(
            method: MCPWire.resourcesReadMethod,
            params: MCPWire.resourcesReadParams(uri: uri),
            hints: MCPSendHints(name: uri),
            reportsProgress: true)
        return Self.scrubbingOwnSecrets(
            from: MCPWire.resourceReadResult(from: result), literals: credentials().literals)
    }

    /// Fetches one prompt template (`prompts/get`) and scrubs echoed server secrets from its
    /// description and messages before returning.
    func getPrompt(name: String, arguments: [String: String] = [:]) async throws -> MCPPromptGetResult {
        let result = try await call(
            method: MCPWire.promptsGetMethod,
            params: MCPWire.promptsGetParams(name: name, arguments: arguments),
            hints: MCPSendHints(name: name),
            reportsProgress: true)
        let scrubbed = Self.scrubbingOwnSecrets(fromPromptResult: result, literals: credentials().literals)
        return MCPWire.promptGetResult(from: scrubbed)
    }

    static func scrubbingOwnSecrets(
        fromPromptResult result: JSONValue,
        literals: MCPRedaction.Credentials.Literals
    ) -> JSONValue {
        guard !literals.isEmpty, case .object(var top) = result else { return result }
        if case .string(let desc)? = top["description"] {
            top["description"] = .string(literals.scrub(MCPTextSanitizer.sanitizeData(literals.scrub(desc))))
        }
        if case .array(let messages)? = top["messages"] {
            top["messages"] = .array(messages.map { entry in
                guard case .object(var msgObj) = entry else { return entry }
                if let content = msgObj["content"] {
                    msgObj["content"] = scrubbedBlock(content, literals)
                }
                return .object(msgObj)
            })
        }
        return .object(top)
    }

    /// A result with every LITERAL value this app sent the server — the bearer, each secret
    /// header — replaced by `MCPRedaction.placeholder`, in its JSON spelling too, on success
    /// and on the server's own failure alike.
    ///
    /// A server that echoes the token it was called with (a debug field, a "you are" line, a
    /// map keyed by the caller's key) hands it to the model, and the model can carry it to
    /// another server or into an artifact. The error paths were scrubbed first (F11); this is
    /// the same fact for DATA, until 2026-09-23 the one channel still open.
    ///
    /// **Literal values only** (`MCPRedaction.Credentials.Literals`): a tool may legitimately
    /// return text SHAPED like a credential, and that text is its answer.
    ///
    /// **At the client**, because this is the one place that knows both what came back and
    /// what was sent — below it the transport has bytes, above it the runtime has no
    /// credentials — and the result leaves here for every consumer at once. The credentials
    /// are read once per result: each read is a Keychain lookup per secret.
    ///
    /// Every string and key of every block and of `structuredContent`, except the base64
    /// payloads — `data` on an image or audio block, `blob` on a resource. Those are not text:
    /// a short value turns up in a megabyte of base64 by chance, and replacing it there
    /// would corrupt the file without hiding anything.
    ///
    /// **Scrubbed on both sides of the cleaning the model's copy gets.** After it: the mapper
    /// drops bidi, tag and control characters — and, from a link's address or name, zero-width
    /// ones too — so a secret split by one (`wk_live\u{202E}_8f3a…`) is whole again by the time
    /// the model reads it, and only a scrub of the CLEANED form sees it. Each field is cleaned
    /// as the mapper reads it (`MCPResultFieldReading`, one table for both); until 2026-09-23
    /// the raw text alone was scrubbed, and then every field was cleaned as data while the
    /// mapper laid a link's fields out as lines. Before it: an unterminated `ESC [` takes the
    /// next letter as its final byte, so the cleaned form holds the secret less its first
    /// character, and only the RAW form still matches. The mapper's own pass stays and changes
    /// nothing: each cleaning is idempotent.
    static func scrubbingOwnSecrets(
        from result: MCPCallToolResult,
        literals: MCPRedaction.Credentials.Literals
    ) -> MCPCallToolResult {
        guard !literals.isEmpty else { return result }
        return MCPCallToolResult(
            contentBlocks: result.contentBlocks.map { scrubbedBlock($0, literals) },
            structuredContent: result.structuredContent.map { cleanedAndScrubbed($0, literals) },
            isError: result.isError)
    }

    /// The block's values, at every depth, less its base64 — and the same rule one level
    /// down, for an embedded resource's `blob`. A string field is cleaned as the mapper reads
    /// it; block keys are the protocol's own names and are left as they are.
    private static func scrubbedBlock(
        _ block: JSONValue, _ literals: MCPRedaction.Credentials.Literals
    ) -> JSONValue {
        guard case .object(let members) = block else { return cleanedAndScrubbed(block, literals) }
        var out: [String: JSONValue] = [:]
        for (key, value) in members {
            let reading = MCPResultFieldReading(field: key)
            if reading == .binary {
                out[key] = value
            } else if key == "resource" {
                out[key] = scrubbedBlock(value, literals)
            } else if case .string(let text) = value {
                out[key] = .string(literals.scrub(reading.cleaned(literals.scrub(text))))
            } else {
                out[key] = cleanedAndScrubbed(value, literals)
            }
        }
        return .object(out)
    }

    /// Every string and key of a document the model reads as data, without this server's
    /// secrets in its raw or its cleaned form. Keys that fold together keep every value through
    /// every pass — each has its own collision rule (`sanitizeData`, `Literals.scrub`).
    private static func cleanedAndScrubbed(
        _ value: JSONValue, _ literals: MCPRedaction.Credentials.Literals
    ) -> JSONValue {
        literals.scrub(MCPTextSanitizer.sanitizeData(literals.scrub(value)))
    }
}
