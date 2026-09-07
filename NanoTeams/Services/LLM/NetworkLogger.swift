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
    /// What this step RAN ON — NOT wire traffic, and not a tool call either. A discrete
    /// audit record naming the model, the server and the app/prompt build behind the
    /// requests that follow it.
    ///
    /// The log's 17 fields carry nothing about version or server, and the sampler settings
    /// deliberately never reach the wire (LM Studio's per-model config is the single source
    /// of truth for them), so a request BODY cannot be traced back to what produced it even
    /// in principle. That is the root of every "re-test on a build change" gate that has
    /// never fired: nothing in a run says which build it was.
    ///
    /// `.request`/`.response` consumers skip these by direction, exactly as they already
    /// skip `.toolCall` — `train_first_prompt.sh` and `FirstPromptFromLogsExtractor` both
    /// filter on `.direction == "request"`.
    case provenance
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

    /// The one constructor the APP uses for a run's log. On the main actor because it
    /// primes `RuntimePromptFingerprint` — whose composers are main-actor code — before any
    /// client can write the first provenance record from its stream task. Tests may build
    /// a logger directly; `RuntimePromptFingerprintPinTests` pins that the app does not.
    @MainActor
    static func forRun(logURL: URL) -> NetworkLogger {
        RuntimePromptFingerprint.prime()
        return NetworkLogger(logURL: logURL)
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

    // MARK: - Provenance

    /// The `(log file, server, model)` triples a provenance record has been written for,
    /// process-wide. Keyed by the log's PATH, not the logger instance: a step builds a new
    /// logger on every entry (pause/resume, revision, a delivered supervisor answer), and a
    /// per-instance set would repeat the constant on each. Process-wide is also why one
    /// registry serves every caller — the step, a vision call, a judge, a meeting turn, the
    /// Supervisor auto-answer — so the record appears at the FIRST sight of a triple no
    /// matter who saw it. Until 2026-09-07 `startStepExecution` alone wrote it, keyed on
    /// the execution service: a judge override or the vision config in the same run log
    /// had no line naming its model, and the auto-answer's request had no log at all.
    nonisolated(unsafe) private static var notedProvenance: Set<String> = []
    private static let provenanceLock = NSLock()

    /// Writes one `.provenance` record per `(log file, server, model)`. Called by both
    /// provider clients right before their first request record — the one seam every wire
    /// request passes through, so a caller is covered without knowing about it.
    func noteProvenanceIfNeeded(config: LLMConfig, stepID: String?, roleName: String?) {
        let key = "\(logURL.path)|\(config.baseURLString)|\(config.modelName)"
        Self.provenanceLock.lock()
        let inserted = Self.notedProvenance.insert(key).inserted
        Self.provenanceLock.unlock()
        guard inserted else { return }
        append(NetworkLogger.createProvenanceRecord(
            provider: config.provider.rawValue,
            baseURL: config.baseURLString,
            model: config.modelName,
            appVersion: AppVersion.current,
            promptVersion: BundledContentFingerprint.current,
            runtimePromptVersion: RuntimePromptFingerprint.primed ?? RuntimePromptFingerprint.unprimedMarker,
            stepID: stepID,
            roleName: roleName))
    }

    #if DEBUG
    /// Test isolation: forget every triple, so a fresh log path behaves as at process start.
    static func _testResetProvenanceRegistry() {
        provenanceLock.lock()
        notedProvenance = []
        provenanceLock.unlock()
    }
    #endif

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

    /// One record per (server, model) a STEP runs on.
    ///
    /// Per step, not per run, and that is the whole reason it is useful: `llmOverride` is
    /// resolved per step (`+StepLifecycle`), and `LLMOverride` carries both a base URL and
    /// a model name — so one FAANG run with overrides goes through several models and
    /// possibly several servers. A single per-run record would name one of them and be
    /// wrong about the rest, which is precisely the failure provenance exists to prevent.
    /// `NetworkLogRecord` already carries `stepID` and `roleName`, so the attribution
    /// needs no new field. `promptVersion` is the bundled content, `runtimePromptVersion`
    /// the composed texts (`RuntimePromptFingerprint`, 2026-09-07) — the two halves of
    /// "which prompt bytes produced this request".
    ///
    /// Shape copied from `createToolCallRecord` above, which established the convention:
    /// empty `httpMethod`/`url` (nothing is invented), a fresh unpaired `correlationID`,
    /// and the whole payload as an escaped JSON *string* in `body`. That means ZERO new
    /// named properties on `NetworkLogRecord` — which is what keeps
    /// `LLMTokenLeakGuardTests` (reflection over property names) and
    /// `NetworkLoggerHeadersGuardTests` (JSON keys) green by construction rather than by
    /// promise, and leaves `NetworkLogTestReading.strictRecords` decoding unchanged.
    ///
    /// REST-only by design. `version` / `build` / `installedEngines` are answered by LM
    /// Studio over a WebSocket RPC, and `Services/Net/` is documented as "the app's only
    /// websocket, benchmark-only" — moving it into the run loop would change a recorded
    /// invariant and add latency to every step start, and Ollama has no such channel at
    /// all. Quantization is the same trade one step smaller: it needs a model-catalogue
    /// fetch, i.e. a network round-trip per step start, which is the cost class CLAUDE.md
    /// #49 exists about. Both are recorded in DEBTS rather than quietly not done.
    static func createProvenanceRecord(
        provider: String,
        baseURL: String,
        model: String,
        appVersion: String,
        promptVersion: String,
        runtimePromptVersion: String,
        stepID: String?,
        roleName: String? = nil
    ) -> NetworkLogRecord {
        let body = JSONUtilities.jsonStringForToolArgs([
            "event": "provenance",
            "provider": provider,
            "baseURL": baseURL,
            "model": model,
            "appVersion": appVersion,
            "promptVersion": promptVersion,
            "runtimePromptVersion": runtimePromptVersion,
        ])
        return NetworkLogRecord(
            id: UUID(),
            createdAt: MonotonicClock.shared.now(),
            direction: .provenance,
            httpMethod: "",
            url: "",
            statusCode: nil,
            body: body,
            durationMs: nil,
            errorMessage: nil,
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
