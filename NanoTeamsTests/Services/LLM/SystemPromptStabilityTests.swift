import XCTest

@testable import NanoTeams

/// Segment 0 — the system prompt, which carries the tool catalog — is the most expensive thing
/// that can move: losing it re-prefills the whole conversation. Several inputs to it can change
/// while a run is in flight (`set_work_folder_context`, the 5-second agent-instructions rescan, a
/// `globalContext` edit, the Autovisor rewriting its own memory, a `git init` flipping the tool
/// filter), so the property that keeps them harmless is structural rather than incidental:
/// **the prompt and the tool set are each resolved exactly once per step entry.**
///
/// That is a claim about call sites, not about values, so most of it is pinned by scanning source.
/// A behavioural test would pass just as well against a builder that happened to be called twice
/// with unchanged inputs, which is precisely the bug it would need to catch.
final class SystemPromptStabilityTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func strippingLineComments(_ line: String) -> String {
        var out = ""
        var inString = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"", previous != "\\" { inString.toggle() }
            if !inString, character == "/", previous == "/" { return String(out.dropLast()) }
            out.append(character)
            previous = character
            index = line.index(after: index)
        }
        return out
    }

    private func productionCallSites(of needle: String) throws -> [String] {
        var hits: [String] = []
        let sources = repoRoot.appendingPathComponent("NanoTeams")
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (offset, raw) in lines.enumerated() {
                let text = Self.strippingLineComments(raw)
                guard text.contains(needle), !text.contains("func " + needle) else { continue }
                hits.append("\(relative):\(offset + 1)")
            }
        }
        return hits
    }

    // MARK: - One resolution per step entry

    /// The files that run once per ITERATION. Nothing here may rebuild the prompt or re-resolve
    /// the tool set: both read live state (sibling step statuses, artifacts produced after t0, the
    /// work-folder context, the agent-instructions snapshot, the Autovisor's own memory, whether
    /// `.git` exists) that legitimately moves mid-run, and both feed segment 0.
    private static let perIterationFiles = [
        "LLMExecutionService+ToolIteration.swift",
        "LLMExecutionService+ToolLoopState.swift",
        "LLMExecutionService+ToolExecution.swift",
        "LLMExecutionService+ToolResultProcessing.swift",
        "LLMExecutionService+ToolResultDispatching.swift",
        "LLMExecutionService+ToolResultSideEffects.swift",
        "LLMExecutionService+StepFlowControl.swift",
        "LLMExecutionService+PlanningPhase.swift",
        "LLMExecutionService+Streaming.swift",
    ]

    /// The freeze, stated as the thing that would break it: a rebuild from inside the loop.
    ///
    /// Behaviourally untestable in a useful way — a test driving two iterations with unchanged
    /// inputs passes against a builder called twice, which is exactly the defect. So the pin is
    /// on the call graph.
    func testNoPerIterationFileRebuildsThePromptOrTheToolSet() throws {
        for needle in ["buildChat" + "Messages(", "resolveTool" + "Schemas("] {
            let offenders = try productionCallSites(of: needle)
                .filter { site in
                    Self.perIterationFiles.contains { site.contains($0) }
                }
            XCTAssertTrue(
                offenders.isEmpty,
                "\(needle) is resolved ONCE per step entry. Calling it from the tool loop re-reads "
                    + "state that has moved and diverges segment 0 — the most expensive prefix "
                    + "loss there is: \(offenders.joined(separator: ", "))")
        }
    }

    /// …and step entry really is where it happens, so the pin above is not vacuous through the
    /// prompt simply never being built.
    func testStepEntryIsWhereThePromptAndToolSetAreResolved() throws {
        let entry = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "NanoTeams/Services/LLM/LLMExecutionService+StepLifecycle.swift"),
            encoding: .utf8)
        XCTAssertTrue(entry.contains("buildChat" + "Messages("))
        XCTAssertTrue(entry.contains("toolSchemas(" ) || entry.contains("resolveTool" + "Schemas("))
    }

    // MARK: - Catalog order

    /// `allowedTools` order derives from the `ToolHandlerRegistry.allTypes` ARRAY. That is
    /// deterministic today, but nothing says so — a future `Set`-driven build would still satisfy
    /// "same input, same output" while changing every system prompt in the app exactly once.
    /// Comparing against an independent expectation is what catches that.
    func testToolCatalogOrder_isASubsequenceOfTheRegistryArray() {
        let registryOrder = ToolHandlerRegistry.allSchemas.map(\.name)
        let rendered = NativeLMStudioClient.buildToolSchemaBody(
            tools: ToolHandlerRegistry.allSchemas)

        var searchFrom = rendered.startIndex
        var previous: String?
        for name in registryOrder {
            guard let found = rendered.range(of: name, range: searchFrom..<rendered.endIndex)
            else {
                return XCTFail("\(name) missing from the rendered catalog")
            }
            searchFrom = found.lowerBound
            previous = name
        }
        XCTAssertNotNil(previous, "anti-vacuity: the registry must not be empty")
    }

    private static func property(_ description: String) -> JSONSchemaProperty {
        JSONSchemaProperty(
            type: "string", description: description, properties: nil,
            required: nil, items: nil, enumValues: nil)
    }

    /// Parameter keys are sorted, which is what makes the largest block in the prompt stable
    /// across processes (a dictionary iteration would not be).
    func testRenderedParameterKeys_areSorted() {
        let schema = ToolSchema(
            name: "t", description: "d",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "zebra": Self.property("z"),
                    "apple": Self.property("a"),
                    "middle": Self.property("m"),
                ]))
        let rendered = NativeLMStudioClient.buildToolSchemaBody(tools: [schema])

        guard let apple = rendered.range(of: "apple"),
              let middle = rendered.range(of: "middle"),
              let zebra = rendered.range(of: "zebra")
        else { return XCTFail("expected all three keys in the rendered args") }

        XCTAssertLessThan(apple.lowerBound, middle.lowerBound)
        XCTAssertLessThan(middle.lowerBound, zebra.lowerBound)
    }

    // MARK: - A moved target reads as a fresh conversation, not a rewrite

    /// `preflightCheck` can silently replace a role's override server with the global one, and a
    /// provider flip rewrites both URL and model. Those land on a DIFFERENT owner key because the
    /// base URL and model are part of it — so they read as `.firstRequestForOwner`, which is the
    /// honest answer: a different machine has nothing cached. No exemption needed, and this pins
    /// that a future "simplify the key to just the owner" change cannot turn a cold machine into
    /// a reported rewrite.
    func testMovingTheTargetServerReadsAsAFirstRequest() async {
        let ledger = PromptPrefixLedger()
        let owner = LLMCallOwner.step(taskID: 1, stepID: "engineer")
        let messages = [
            ChatMessage(role: .system, content: "s"),
            ChatMessage(role: .user, content: String(repeating: "word ", count: 2000)),
        ]

        _ = await ledger.record(
            baseURL: "http://override-host:1234", model: "m",
            owner: owner, messages: messages, toolSchemaText: "")
        let afterFallback = await ledger.record(
            baseURL: "http://127.0.0.1:1234", model: "m",
            owner: owner, messages: messages, toolSchemaText: "")

        XCTAssertEqual(afterFallback.structural, .firstRequestForOwner)

        let afterModelFlip = await ledger.record(
            baseURL: "http://override-host:1234", model: "other-model",
            owner: owner, messages: messages, toolSchemaText: "")
        XCTAssertEqual(afterModelFlip.structural, .firstRequestForOwner)
    }
}
