import XCTest

@testable import NanoTeams

/// **Every `streamChat` caller must be registered with the prompt-prefix ledger.**
///
/// Only 5 of 13 were. The consequences split two ways:
///
/// - Callers that accumulate a growing prefix — meeting turns, the delegated Supervisor answer —
///   could not detect their OWN misses at all. `LLMCallOwner`'s doc comment names both as
///   required `.chain` owners; neither was wired.
/// - One-shots that run on the same `(baseURL, model)` as a live step could not even be NAMED as
///   a suspect on a `serverDroppedCache` verdict. Vision is the worst of these: a blank vision
///   slot inherits the GLOBAL model, so on a default setup the single most common real interleaver
///   was structurally invisible.
///
/// The registration cannot be made a compile error without a required parameter on
/// `LLMClient.streamChat`, which would touch ~44 test doubles and either drag the ledger toward a
/// process-global or leave the parameter decorative. So the guarantee is this scan — which makes
/// it the ONLY structural guarantee, and therefore worth RED-verifying by hand whenever it
/// changes (plant a bare `streamChat` in a service, confirm the failure names the file and line,
/// revert).
///
/// House source-pin shape: line comments are stripped before matching and every needle is
/// assembled at runtime, so this file's own prose can neither satisfy nor trip the scan.
final class PrefixCacheOwnerCoverageTests: XCTestCase {

    // MARK: - Scaffolding

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
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

    private static var callNeedle: String { "stream" + "Chat(" }
    private static var justification: String { "prefix-cache" + "-owner:" }
    private static var registrationNeedles: [String] {
        [
            "prefixLedger" + ".record(",
            "noteInterleaving" + "Call(",
            "recordPrefixChain" + "ForTasklessCall(",
            "recordPrefix" + "Chain?(",
            "recordPrefix" + "Chain: {",
        ]
    }

    /// The window a registration (or a justification marker) may sit in, relative to the call.
    /// Generous in both directions: a registration usually precedes the call by a few lines, and
    /// a multi-line justification comment needs room (CLAUDE.md Грабли 2026-07-25 — a 3-line
    /// window rejected a legitimate 4-line exemption).
    private static let windowBefore = 14
    private static let windowAfter = 2

    private struct Site {
        let path: String
        let line: Int
    }

    private func codeLines(of relativePath: String) throws -> [String] {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { Self.strippingLineComments($0) }
    }

    /// Every production `streamChat` CALL site, excluding declarations and the router's pure
    /// forward.
    private func callSites() throws -> (sites: [Site], filesWalked: Int, lines: [String: [String]]) {
        var sites: [Site] = []
        var filesWalked = 0
        var lineCache: [String: [String]] = [:]

        let sources = repoRoot.appendingPathComponent("NanoTeams")
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            filesWalked += 1
            let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            let raw = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            let stripped = raw.map { Self.strippingLineComments($0) }
            lineCache[relative] = raw

            for (offset, text) in stripped.enumerated() {
                guard text.contains(Self.callNeedle) else { continue }
                // `func streamChat(` is a declaration, not a call.
                if text.contains("func " + Self.callNeedle) { continue }
                sites.append(Site(path: relative, line: offset + 1))
            }
        }
        return (sites, filesWalked, lineCache)
    }

    private func isCovered(_ site: Site, lines: [String: [String]]) -> Bool {
        guard let raw = lines[site.path] else { return false }
        let index = site.line - 1
        let lower = max(0, index - Self.windowBefore)
        let upper = min(raw.count - 1, index + Self.windowAfter)
        let window = raw[lower...upper].joined(separator: "\n")
        if window.contains(Self.justification) { return true }
        // Registrations are code, so strip comments before looking for them — otherwise a
        // comment merely MENTIONING the ledger would count as wiring it.
        let code = raw[lower...upper].map { Self.strippingLineComments($0) }.joined(separator: "\n")
        return Self.registrationNeedles.contains { code.contains($0) }
    }

    // MARK: - The scan

    func testEveryStreamChatCallSiteNamesAnOwner() throws {
        let (sites, _, lines) = try callSites()
        // Pure forwards, not callers: the router dispatches to the provider client, and the
        // protocol's convenience overload forwards to the full one. Whoever called THEM is what
        // must register.
        let exemptFiles = Set([
            "NanoTeams/Services/LLM/LLMClientRouter.swift",
            "NanoTeams/Services/LLM/LLMClient.swift",
        ])

        let offenders = sites
            .filter { !exemptFiles.contains($0.path) }
            .filter { !isCovered($0, lines: lines) }
            .map { "\($0.path):\($0.line)" }

        XCTAssertTrue(
            offenders.isEmpty,
            "these issue an LLM request that the prompt-prefix ledger never sees, so they can "
                + "neither detect their own cache miss nor be named as the suspect behind someone "
                + "else's. Register the owner (`.chain` if the caller resends a GROWING prefix, "
                + "`.oneShot` otherwise) or add a `// prefix-cache-owner: <why not>` note: "
                + offenders.joined(separator: ", "))
    }

    /// The three callers that genuinely accumulate a prefix must be `.chain`, not `.oneShot`: a
    /// one-shot is recorded for suspect naming only and can never be a victim
    /// (`LLMCallOwner.accumulatesPrefix`), so filing them that way would silently keep them blind
    /// to their own misses.
    func testTheAccumulatingCallersAreRegisteredAsChains() throws {
        let chainNeedle = ".chain" + "("
        for path in [
            "NanoTeams/Services/LLM/LLMExecutionService+TeamMeeting.swift",
            "NanoTeams/Services/LLM/DelegatedSupervisorAnswerService.swift",
            "NanoTeams/Services/LLM/LLMExecutionService+TeammateConsultation.swift",
        ] {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(
                source.contains(chainNeedle),
                "\(path) resends a growing prefix — it must own a chain, not a one-shot")
        }
    }

    /// A marker that names its registering frame is a promise; this checks the promise. Every
    /// leaf service above delegates registration one frame up, and a marker pointing at a frame
    /// that does not actually record would be worse than no marker at all — it reads as coverage.
    func testEveryNamedRegisteringFrameActuallyRecords() throws {
        let expected: [String: String] = [
            "NanoTeams/Services/LLM/LLMExecutionService+Vision.swift": "vision",
            "NanoTeams/Services/LLM/LLMExecutionService+ComputerUse.swift": "vision",
            "NanoTeams/Services/LLM/LLMExecutionService+BashGate.swift": "bash judge",
            "NanoTeams/Services/LLM/LLMExecutionService+ComputerUseGate.swift":
                "computer-use judge",
            "NanoTeams/Services/LLM/LLMExecutionService+TaskStateMutations.swift":
                "supervisor auto-answer",
            "NanoTeams/Services/LLM/LLMExecutionService+DelegateToTeam.swift": "team generation",
            "NanoTeams/Services/Core/NTMSOrchestrator+TeamGeneration.swift": "team generation",
            "NanoTeams/Services/Core/NTMSOrchestrator+WorkFolderManagement.swift":
                "work folder context",
            "NanoTeams/Services/Core/NTMSOrchestrator+BashAdvice.swift": "bash advice",
            "NanoTeams/Views/Settings/TeamEditor/TeamEditorView+Actions.swift":
                "team generation",
        ]
        for (path, label) in expected {
            let source = try codeLines(of: path).joined(separator: "\n")
            XCTAssertTrue(
                source.contains("\"\(label)\""),
                "\(path) is named as the registering frame for '\(label)' but does not name it")
            XCTAssertTrue(
                Self.registrationNeedles.contains { source.contains($0) },
                "\(path) is named as a registering frame but performs no registration")
        }
    }

    /// A meeting's tool follow-ups continue the SAME array the initial stream was grounded on, so
    /// they must land on the same chain. The id is therefore built once and handed down; deriving
    /// it independently in the follow-up frame is how two halves of one conversation come to
    /// disagree about their own identity.
    func testTheMeetingChainIdIsBuiltOnceAndPassedDown() throws {
        let executor = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "NanoTeams/Services/LLM/MeetingToolExecutor.swift"),
            encoding: .utf8)
        XCTAssertFalse(
            executor.contains("meeting:"),
            "the follow-up loop must not compose its own chain id — it receives a bound recorder")
        XCTAssertTrue(
            executor.contains("recordPrefixChain"),
            "…and it must actually record each follow-up request")
    }

    // MARK: - Anti-vacuity

    func testThePinIsNotVacuous() throws {
        let (sites, filesWalked, _) = try callSites()

        XCTAssertGreaterThan(
            filesWalked, 400, "the source walk found almost nothing — every scan above is vacuous")
        XCTAssertGreaterThanOrEqual(
            sites.count, 12,
            "expected the known ~13 streamChat call sites; found \(sites.count)")

        // A commented-out call must not be seen at all…
        let probe = "// " + Self.callNeedle
        XCTAssertFalse(
            Self.strippingLineComments("        \(probe)").contains(Self.callNeedle),
            "comment stripping is broken, so commented code would be flagged")

        // …and a registration that exists only inside a COMMENT must not count as coverage.
        let commentOnly = ["    // we call prefixLedger.record( somewhere else", "    x()"]
        let fakeSite = Site(path: "fake", line: 2)
        XCTAssertFalse(
            isCovered(fakeSite, lines: ["fake": commentOnly]),
            "a mention of the ledger in prose must not satisfy the scan")

        // …while a real one does.
        let realOnly = ["    _ = await prefixLedger.record(x)", "    y()"]
        XCTAssertTrue(isCovered(fakeSite, lines: ["fake": realOnly]))
    }
}
