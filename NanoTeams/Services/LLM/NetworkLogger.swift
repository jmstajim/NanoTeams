import Foundation

enum NetworkDirection: String, Codable {
    case request
    case response
    /// A tool call — NOT wire traffic. A discrete audit record for every tool
    /// call the run made: executed (success + handler error), and the
    /// pre-runtime non-dispatched cases (malformed / missing-name / unauthorized
    /// / duplicate-write) that never become an HTTP request. `.request`/`.response`
    /// consumers (e.g. `FirstPromptFromLogsExtractor`) skip these by direction.
    case toolCall
}

nonisolated struct NetworkLogRecord: Codable, Hashable {
    var id: UUID
    var createdAt: Date
    var direction: NetworkDirection
    var httpMethod: String
    var url: String
    var statusCode: Int?
    var body: String?
    var durationMs: Double?
    var errorMessage: String?
    var correlationID: UUID
    var stepID: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var roleName: String?
    /// Server-reported prompt PREFILL time in milliseconds, decode excluded. Distinct from
    /// `durationMs`, which is whole-request wall time and is dominated by generation. This is the
    /// number that tells a prompt-prefix (KV) cache hit from a silent re-prefill — the same
    /// measurement `benchmark_prompt_processing.sh` extracts, now recorded per request so the
    /// prefix audit that §6 of the stateless handoff did by hand can be done from the log.
    /// Ollama only; LM Studio reports a queue-contaminated TTFT instead, which is not comparable.
    var prefillMs: Double?
    /// Server-reported model LOAD time in milliseconds, VERBATIM — never thresholded here.
    ///
    /// A positive value is NOT by itself a reload: Ollama reports 20–30 ms of per-request
    /// bookkeeping on a resident model (26 of 27 baseline rows) while LM Studio reports exactly
    /// 0 when warm. Recording the raw number is what let `minimumLoadMsForReload` be re-derived
    /// from a real run instead of re-guessed — see `PrefixCachePolicy.minimumLoadMsForReload`,
    /// which owns the only threshold.
    var modelLoadMs: Double?
    /// Milliseconds THIS APP spent explicitly loading the model for this request, when it did.
    ///
    /// Kept separate from `modelLoadMs` rather than folded into it so the two provenances stay
    /// distinguishable in a real log: the server's figure is the calibration source for
    /// `minimumLoadMsForReload`, and mixing an app-measured duration into it would poison any
    /// attempt to re-derive that threshold. Nil whenever the model was already resident.
    var appModelLoadMs: Double?
}

nonisolated final class NetworkLogger: @unchecked Sendable {
    let logURL: URL
    private let encoder: JSONEncoder
    private let fileManager: FileManager

    init(logURL: URL, fileManager: FileManager = .default) {
        self.logURL = logURL
        self.fileManager = fileManager

        self.encoder = JSONCoderFactory.makeJSONLEncoder()
    }

    /// One line per record, O(1) in the log's size, serialized PER FILE by
    /// `JSONLFileLog` — not per instance, because instances do not map 1:1 onto
    /// files (a step's logger and team generation's logger share one run file,
    /// and parallel roles write concurrently, CLAUDE.md #45).
    ///
    /// This replaced a decode-whole + append + pretty-print re-encode + atomic
    /// rewrite per record: O(n) per call and O(n²) bytes across a run with no
    /// ceiling (`maxToolIterations = 0`), measured at 5.77 MB of I/O for a
    /// 327 KB / 33-record log — plus `try? decode ?? []`, which silently
    /// truncated the whole file on one corrupt byte, where a torn JSONL line
    /// now costs one row. The human-readable `conversation_log.md` is NOT
    /// produced here — it renders what the user actually SEES (the activity
    /// feed), owned by `NTMSOrchestrator+ConversationLog`, so it can be diffed
    /// against this wire log.
    func append(_ record: NetworkLogRecord) {
        JSONLFileLog.append(
            record, to: logURL, encoder: encoder, fileManager: fileManager,
            directoryAttributes: NTMSRepository.internalDirAttributes)
    }

    /// Creates a request record and returns it for later response pairing
    static func createRequestRecord(
        url: URL,
        method: String,
        body: Data?,
        stepID: String?,
        roleName: String? = nil
    ) -> NetworkLogRecord {
        let bodyString: String?
        if let body = body {
            bodyString = redactImageData(String(data: body, encoding: .utf8))
        } else {
            bodyString = nil
        }

        return NetworkLogRecord(
            id: UUID(),
            createdAt: MonotonicClock.shared.now(),
            direction: .request,
            httpMethod: method,
            url: url.absoluteString,
            statusCode: nil,
            body: bodyString,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: stepID,
            roleName: roleName
        )
    }

    /// Strips base64 image payloads (`data:image/...;base64,...`) from a logged body so a
    /// screenshot the model saw isn't written to `network_log.json`. Privacy guard for
    /// computer-use / vision. Regression-pinned by `ScreenshotRedactionTests`.
    static func redactImageData(_ body: String?) -> String? {
        guard let body, body.contains("base64,") else { return body }
        guard let re = try? NSRegularExpression(
            pattern: "data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+", options: []) else { return body }
        let range = NSRange(body.startIndex..., in: body)
        return re.stringByReplacingMatches(
            in: body, options: [], range: range,
            withTemplate: "data:image/redacted;base64,[redacted]")
    }

    /// Creates a `.toolCall` audit record for a single tool call. Used for both
    /// executed calls (from `ToolRuntime`) and pre-runtime non-dispatched ones
    /// (unauthorized / duplicate-write / malformed / missing-name). Not HTTP
    /// traffic: `httpMethod`/`url` are empty and `correlationID` is fresh
    /// (unpaired). `errorMessage` is nil for a clean success. `arguments` and
    /// `result` are embedded as escaped JSON *string* values so a malformed
    /// payload can't corrupt the surrounding `[NetworkLogRecord]` array, and
    /// `body` itself stays valid JSON for downstream parsing.
    static func createToolCallRecord(
        toolName: String,
        argumentsJSON: String,
        resultJSON: String?,
        errorMessage: String?,
        stepID: String?,
        roleName: String? = nil
    ) -> NetworkLogRecord {
        let body = JSONUtilities.jsonStringForToolArgs([
            "event": "tool_call",
            "tool": toolName,
            "arguments": argumentsJSON,
            "result": resultJSON ?? "",
        ])
        return NetworkLogRecord(
            id: UUID(),
            createdAt: MonotonicClock.shared.now(),
            direction: .toolCall,
            httpMethod: "",
            url: "",
            statusCode: nil,
            body: body,
            durationMs: nil,
            errorMessage: errorMessage,
            correlationID: UUID(),
            stepID: stepID,
            roleName: roleName
        )
    }

    /// Creates a response record paired with a request via correlationID
    static func createResponseRecord(
        for request: NetworkLogRecord,
        statusCode: Int,
        durationMs: Double,
        body: String? = nil,
        error: Error?,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        serverPrefill: ServerPrefillReport? = nil,
        clientResidency: ClientResidencyFacts? = nil
    ) -> NetworkLogRecord {
        NetworkLogRecord(
            id: UUID(),
            createdAt: MonotonicClock.shared.now(),
            direction: .response,
            httpMethod: request.httpMethod,
            url: request.url,
            statusCode: statusCode,
            body: body,
            durationMs: durationMs,
            errorMessage: error?.localizedDescription,
            correlationID: request.correlationID,
            stepID: request.stepID,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            roleName: request.roleName,
            prefillMs: serverPrefill?.prefillNs.map { $0 / 1_000_000 },
            modelLoadMs: serverPrefill?.modelLoadMs,
            appModelLoadMs: clientResidency?.appModelLoadMs
        )
    }
    nonisolated deinit {}
}
