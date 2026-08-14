import Foundation

// MARK: - JSON Parsing Helpers

nonisolated extension MemoryTagStore {

    /// Extract "path" from arguments JSON: {"path": "..."}, canonicalized via
    /// `canonicalizePath`. The canonical spelling is what gets RENDERED into the
    /// tagged envelope's `path` field, so the model sees one stable spelling
    /// regardless of how it spelled the argument (`src/x` vs `Foo/src/x` vs
    /// `./src/x` vs an absolute path) — that display stability is the sole
    /// remaining purpose since the 2026-08-11 simplification removed all
    /// path-keyed bookkeeping. Paths that don't resolve cleanly (relative `..`,
    /// absolute-outside-root) hit `relativizePathspec`'s raw fallback and stay
    /// un-canonicalized — harmless, because such tool calls error upstream and
    /// every file processor discards the result via `.passthrough` (the
    /// `!result.isError` guard).
    func extractPath(from argsJSON: String) -> String? {
        guard let raw = extractString(from: argsJSON, key: "path") else { return nil }
        return canonicalizePath(raw)
    }

    /// One repo-relative spelling for a model-supplied path when a
    /// `workFolderRoot` is set; raw passthrough otherwise (no work-folder
    /// context).
    func canonicalizePath(_ raw: String) -> String {
        guard let root = workFolderRoot else { return raw }
        return SandboxPathResolver(workFolderRoot: root).relativizePathspec(raw)
    }

    /// One parse of a tool-result envelope, returning its `data` object — read
    /// multiple keys off the returned dictionary instead of re-parsing the
    /// envelope once per key.
    func dataObject(from outputJSON: String) -> [String: Any]? {
        parseJSON(outputJSON)?["data"] as? [String: Any]
    }

    /// Extract a string value from the "data" object of an envelope JSON:
    /// {"ok": true, "data": {"content": "...", ...}, ...}
    func extractDataString(from outputJSON: String, key: String) -> String? {
        dataObject(from: outputJSON)?[key] as? String
    }

    /// Extract an int value from the "data" object of an envelope JSON.
    func extractDataInt(from outputJSON: String, key: String) -> Int? {
        dataObject(from: outputJSON)?[key] as? Int
    }

    /// Wraps a tool-result envelope under a fresh tag. The body is spliced RAW
    /// when it is itself a JSON object (the normal case — every handler envelope
    /// comes from `encodeToJSON`), so the model reads plain nested JSON instead
    /// of a double-escaped string whose every quote costs an escape-pair token;
    /// anything else (non-JSON test fixtures, corrupt output) is escaped as a
    /// string value so the wrapper stays valid JSON.
    func taggedEnvelope(tag: String, wrapping body: String) -> String {
        let content = parseJSON(body) != nil ? body : jsonEscape(body)
        return "{\"tag\":\"\(tag)\",\"content\":\(content)}"
    }

    /// Extract a string value from a flat JSON object.
    func extractString(from json: String, key: String) -> String? {
        guard let parsed = parseJSON(json),
              let value = parsed[key] as? String else {
            return nil
        }
        return value
    }

    func parseJSON(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// JSON-escape a string for embedding in JSON output.
    ///
    /// Routes through the wire encoder so forward slashes stay literal (`/`, not
    /// `\/`). `JSONSerialization` always escapes slashes with no opt-out — and the
    /// `\/` sequences in file paths/content confuse small models into emitting
    /// literal backslashes in `edit_file` anchors (see `makeWireEncoder`). The
    /// encoder still escapes literal backslashes correctly (`\` → `\\`), so a path
    /// that genuinely contains a backslash round-trips intact — which a naive
    /// `\/`→`/` post-process would corrupt.
    func jsonEscape(_ string: String) -> String {
        if let data = try? JSONCoderFactory.makeWireEncoder().encode(string),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\(string)\""
    }
}
