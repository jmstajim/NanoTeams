import XCTest

@testable import NanoTeams

/// Structural pins for `StepExecution.supervisorAnswerPendingDelivery`.
///
/// The bug this flag closes was NOT a wrong line — it was a missing one. `supervisorAnswer`
/// has seven write sites across five files, and the re-entry seam inferred "there is an
/// answer to deliver" from it; nothing forced a new writer to state whether its answer still
/// owed the wire a delivery. A behavioural suite can only cover the writers that exist today,
/// so the invariant is held here instead: **every writer states the flag, and the consumer
/// stays atomic with the transcript it claims to be consistent with.**
///
/// Needles are assembled at runtime and line comments stripped, so this file's own prose can
/// neither satisfy nor trip the scans (house shape — `ConversationAppendInvariantTests`,
/// `PrefixCacheLedgerOwnershipPinTests`).
final class SupervisorAnswerDeliveryPinTests: XCTestCase {

    /// Observed max distance between a writer and its flag statement is 10 lines
    /// (`StepMessagingService`, which carries a comment block between them). 12 leaves
    /// headroom without letting an unrelated site elsewhere in the function count.
    private static let proximityWindow = 12

    /// Writers that legitimately say nothing about delivery, with the reason.
    private static let exemptWriters: [String: String] = [
        "NanoTeams/Views/TeamBoard/TeamBoardView+Previews.swift":
            "preview fixture — no re-entry seam ever reads these steps"
    ]

    // MARK: - Every writer states the flag

    func testEveryWriterOfSupervisorAnswer_statesTheDeliveryFlag() throws {
        let answerNeedle = "supervisorAnswer" + " ="
        let flagNeedle = "supervisorAnswerPendingDelivery" + " ="
        // `supervisorAnswerAttachmentPaths` / `…WasAuto` / `…PendingDelivery` all start with
        // the same prefix; the trailing " =" is what separates the field itself from them.
        let patternMatchNeedle = "case ." + "supervisorAnswer"

        var writerCount = 0
        var offenders: [String] = []

        for url in try Self.swiftSources() {
            let relative = Self.relativePath(url)
            let lines = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .map(Self.strippingLineComments)

            let flagLines = lines.indices.filter { lines[$0].contains(flagNeedle) }

            for (index, line) in lines.enumerated() {
                guard line.contains(answerNeedle), !line.contains(patternMatchNeedle) else {
                    continue
                }
                writerCount += 1
                guard Self.exemptWriters[relative] == nil else { continue }
                let near = flagLines.contains {
                    abs($0 - index) <= Self.proximityWindow
                }
                if !near { offenders.append("\(relative):\(index + 1)") }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "these write `supervisorAnswer` without stating whether the wire still owes a "
                + "delivery — the re-entry seam then guesses, and guessing from the answer is "
                + "the defect that shipped a deliverable twice: "
                + offenders.joined(separator: ", "))
        XCTAssertGreaterThanOrEqual(
            writerCount, 6,
            "anti-vacuity: the scan must actually be finding the write sites")
    }

    // MARK: - The consumer is atomic with the transcript

    /// The whole safety argument for consuming the flag inside `persistWireTranscript` is
    /// that the transcript being stored ALREADY carries the answer, so the clear and the
    /// store are one mutation. An `await` between them — or the clear drifting into a
    /// separate `mutateTask` — re-opens the window in which a crash spends the answer while
    /// the stored transcript still lacks it.
    func testTheDeliveryFlagIsClearedInTheSameMutationAsTheTranscript() throws {
        let file = "NanoTeams/Services/LLM/LLMExecutionService+ConversationManagement.swift"
        let lines = try String(
            contentsOf: Self.repoRoot().appendingPathComponent(file), encoding: .utf8)
            .components(separatedBy: "\n")
            .map(Self.strippingLineComments)

        let transcriptNeedle = "wireTranscript" + " = messages"
        let flagNeedle = "supervisorAnswerPendingDelivery" + " = false"

        guard let storeLine = lines.firstIndex(where: { $0.contains(transcriptNeedle) }) else {
            return XCTFail("\(file) no longer stores the transcript — pin is stale")
        }
        guard let clearLine = lines.firstIndex(where: { $0.contains(flagNeedle) }) else {
            return XCTFail(
                "\(file) no longer consumes the delivery flag; a re-entry will re-append the "
                    + "answer unless the clear moved somewhere equally atomic")
        }

        XCTAssertGreaterThan(
            clearLine, storeLine,
            "the clear must follow the store it is claiming consistency with")

        let between = lines[storeLine...clearLine]
        XCTAssertFalse(
            between.contains { $0.contains("await ") },
            "an await between the store and the clear means they are no longer one mutation")
        XCTAssertFalse(
            between.contains { $0.contains("mutateTask") },
            "a second mutateTask between them breaks the atomicity the consumer relies on")
    }

    // MARK: - Revision reset must not resurrect a delivered answer

    /// `resetStepForRevision` deliberately keeps the transcript ("the revision replays it and
    /// appends the feedback turn"). It must not touch the answer or its delivery flag: the
    /// step it acts on is `.done`/`.failed`, so a terminal arm already ran
    /// `persistWireTranscript` and disarmed the flag — re-arming it here would make the stale
    /// answer outrank the very revision being requested, which is the second half of the
    /// defect this flag closes.
    ///
    /// Source-level because the suite that exercises this function SIMULATES it inline
    /// (`RevisionContinuationTests.simulateResetStepForRevision`), so a behavioural pin there
    /// would stay green no matter what the real adapter did.
    func testRevisionResetDoesNotTouchTheAnswerOrItsFlag() throws {
        let file = "NanoTeams/Services/Team/TaskEngineStoreAdapter.swift"
        let lines = try String(
            contentsOf: Self.repoRoot().appendingPathComponent(file), encoding: .utf8)
            .components(separatedBy: "\n")
            .map(Self.strippingLineComments)

        guard let start = lines.firstIndex(where: {
            $0.contains("func " + "resetStepForRevision")
        }) else {
            return XCTFail("\(file) no longer declares resetStepForRevision — pin is stale")
        }
        // The next `func ` at the same nesting bounds the body.
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("    func ") } ?? lines.count
        let body = lines[start..<end]

        XCTAssertTrue(
            body.contains { $0.contains("revisionComment" + " = ") },
            "anti-vacuity: the extracted body must be the real one")
        XCTAssertFalse(
            body.contains { $0.contains("supervisorAnswer") },
            "a revision reset that writes the answer or its delivery flag would resurrect an "
                + "already-delivered answer and shadow the feedback it was asked to send")
    }

    // MARK: - The reader needs the flag, not the answer

    /// The one-line regression: `hasSupervisorAnswer` reverting to a bare
    /// `effectiveSupervisorAnswer != nil` test. It compiles, every behavioural suite that
    /// only ever enters a step ONCE stays green, and the duplicate delivery comes back.
    func testTheReEntrySeamReadsTheFlag() throws {
        let file = "NanoTeams/Services/LLM/LLMExecutionService+StepLifecycle.swift"
        let text = try String(
            contentsOf: Self.repoRoot().appendingPathComponent(file), encoding: .utf8)
            .components(separatedBy: "\n")
            .map(Self.strippingLineComments)
            .joined(separator: "\n")

        let declNeedle = "let hasSupervisorAnswer"
        guard let range = text.range(of: declNeedle) else {
            return XCTFail("\(file) no longer declares hasSupervisorAnswer — pin is stale")
        }
        // The declaration spans two lines; take enough to cover the whole expression.
        let tail = text[range.lowerBound...].prefix(220)
        XCTAssertTrue(
            tail.contains("supervisorAnswerPendingDelivery"),
            "the supervisor-continuation branch must gate on the delivery flag; keying it on "
                + "the answer alone makes it a standing condition on every re-entry")
    }

    // MARK: - Helpers

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot().path + "/", with: "")
    }

    private static func swiftSources() throws -> [URL] {
        let sources = repoRoot().appendingPathComponent("NanoTeams")
        guard let walker = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [URL] = []
        while let url = walker.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }

    /// Everything before an unquoted `//`. House shape, verbatim from
    /// `ConversationAppendInvariantTests`.
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
}
