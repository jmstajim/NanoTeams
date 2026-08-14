import XCTest
@testable import NanoTeams

/// Structural pins for the two seams that arm the loop detector's INFORMATION BOUNDARY.
///
/// Both halves fail SILENTLY when their seam is dropped, and neither failure is visible to
/// a behavioural test of the pieces:
///
///  - **In-step.** `ToolCallTracker` records tool calls and nothing else, so the only way it
///    learns that information reached the model is the explicit
///    `noteExternalInformationArrived` at the injection site. Drop it and every unit test of
///    the tracker and the detector stays green while the false positive returns in full.
///  - **Committed.** `DelegationLoopWatcher` only ever sees flattened tuples, so the boundary
///    is computed by the caller. The argument itself is now required (no default — see
///    `testCommittedBoundary_hasNoDefault`), so the compiler catches an omitted one; what it
///    cannot catch is a WRONG value. A boundary read off the `.assistant`-filtered slice, or
///    off any narrowed one, is silently always nil and restores the false positive in full.
///
/// The in-step seam also has a catastrophic MIS-wiring: arming it unconditionally (rather
/// than on the delivery flag) marks the first call of every iteration, which makes the
/// trailing run 1 forever — `.repetitiveTool` would then never fire at all, for anyone.
///
/// Needles are assembled at runtime and line comments stripped, so this file's own prose can
/// neither satisfy nor trip the scans (house shape — `SupervisorAnswerDeliveryPinTests`,
/// `ConversationAppendInvariantTests`).
final class InformationBoundaryWiringPinTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
    }

    private static let iterationPath = "NanoTeams/Services/LLM/LLMExecutionService+ToolIteration.swift"
    private static let streamingPath = "NanoTeams/Services/Core/NTMSOrchestrator+Streaming.swift"
    /// The two declarations of the boundary parameter, scanned for a re-added default.
    private static let declarationPaths = [
        "NanoTeams/Services/LLM/LoopDetection/LoopScanner.swift",
        "NanoTeams/Services/LLM/DelegationLoopWatcher.swift",
    ]

    /// Strips line comments so a scan can only be satisfied by CODE. Without this a pin
    /// passes on a file where the mechanism was deleted and only its explanation remains —
    /// the exact way a structural guard rots into decoration.
    private func code(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    private func source(_ relativePath: String) throws -> String {
        try code(String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8))
    }

    /// Both scanned files are build sources, so they exist in every compiling checkout
    /// (including the public mirror, which ships no non-build files). A broken `#filePath`
    /// derivation would make every scan below pass vacuously.
    func testRepoRootResolves() {
        for path in [Self.iterationPath, Self.streamingPath] + Self.declarationPaths {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(path).path),
                "\(path) not found — the #filePath derivation is broken")
        }
    }

    // MARK: - In-step seam

    func testInStepBoundary_isArmedAtTheInjectionSite() throws {
        let src = try source(Self.iterationPath)
        guard let iterationStart = src.range(of: "func runOneLLMToolIteration") else {
            return XCTFail("runOneLLMToolIteration not found — did the file move?")
        }
        let injectNeedle = "injectQueuedSupervisorMessage" + "("
        guard let callSite = src.range(
            of: injectNeedle, range: iterationStart.upperBound..<src.endIndex)
        else {
            return XCTFail("The tool loop no longer injects queued Supervisor messages")
        }
        // Forward window: the arm sits just after the call's argument list.
        let windowEnd = src.index(callSite.upperBound, offsetBy: 500, limitedBy: src.endIndex)
            ?? src.endIndex
        let following = String(src[callSite.upperBound..<windowEnd])
        XCTAssertTrue(
            following.contains("noteExternalInformationArrived"),
            "A delivered Supervisor turn must open an information epoch on the tracker — "
            + "without it the detector counts a repeat that straddles brand-new information "
            + "as a loop. Window: \(following)")
    }

    /// The arm must be gated on the value the injection RETURNED, not merely on some
    /// conditional. The identifier is read out of the source rather than hard-coded, so a
    /// rename is not a false failure, and the window is character-based so a multi-line
    /// rewrite still passes — the earlier version asserted `"if "` on the same LINE, which
    /// is a property of line-wrapping and would have accepted `if true { … }`.
    ///
    /// RED: change the arm to an unconditional `tracker.noteExternalInformationArrived()`
    /// → this fails, and in production every iteration would mark its first call, pinning
    /// the trailing run at 1 so `.repetitiveTool` could never fire again.
    func testInStepBoundary_isGatedOnActualDelivery() throws {
        let src = try source(Self.iterationPath)
        // Literal search, not a regex: the needle ends in `(`, which a regex would read as
        // an unbalanced capture group.
        let injectNeedle = "injectQueuedSupervisorMessage" + "("
        guard let call = src.range(of: injectNeedle) else {
            return XCTFail("The tool loop no longer injects queued Supervisor messages")
        }
        let lineStart = src[src.startIndex..<call.lowerBound].lastIndex(of: "\n")
            .map { src.index(after: $0) } ?? src.startIndex
        let binding = String(src[lineStart..<call.lowerBound])
        guard binding.contains("let "), binding.contains("=") else {
            return XCTFail("The injection result is no longer bound to a name — the arm below "
                           + "cannot be gated on a delivery it never captured. Line: \(binding)")
        }
        let deliveredIdent = binding
            .replacingOccurrences(of: "let ", with: " ")
            .components(separatedBy: "=")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(deliveredIdent.isEmpty, "Could not read the bound identifier out of: \(binding)")

        // The identifier must appear as the CONDITION of the branch guarding the arm, not
        // merely somewhere nearby: `_ = deliveredExternalInformation` on the line above an
        // unconditional arm mentions it too, and a proximity check accepts that (measured —
        // that mutation produced zero reds against the first two versions of this pin).
        let conditions = ["if " + deliveredIdent, "guard " + deliveredIdent]
        let armNeedle = "noteExternalInformationArrived"
        var searchStart = src.startIndex
        var armCount = 0
        while let arm = src.range(of: armNeedle, range: searchStart..<src.endIndex) {
            armCount += 1
            let windowStart = src.index(arm.lowerBound, offsetBy: -120, limitedBy: src.startIndex)
                ?? src.startIndex
            let preceding = String(src[windowStart..<arm.lowerBound])
            XCTAssertTrue(
                conditions.contains(where: preceding.contains),
                "Arming the epoch must be branched on the injection reporting a delivery — "
                + "expected `if \(deliveredIdent)` (or `guard`) directly above it. An "
                + "unconditional arm marks every iteration's first call and silently disables "
                + "repetition detection. Window: \(preceding)")
            searchStart = arm.upperBound
        }
        XCTAssertEqual(armCount, 1, "Expected exactly one in-step boundary arm, found \(armCount)")
    }

    // MARK: - Committed seam

    func testCommittedBoundary_isWiredAtTheCommitStreamingCallSite() throws {
        let src = try source(Self.streamingPath)
        let watcherNeedle = "considerCommitted" + "("
        guard let callSite = src.range(of: watcherNeedle) else {
            return XCTFail("commitStreaming no longer runs the post-commit loop scan")
        }
        let windowEnd = src.index(callSite.upperBound, offsetBy: 400, limitedBy: src.endIndex)
            ?? src.endIndex
        let arguments = String(src[callSite.upperBound..<windowEnd])
        XCTAssertTrue(
            arguments.contains("informationBoundary:"),
            "The watcher sees only tuples, so the caller must hand it the boundary. "
            + "Belt-and-braces beside the compiler (the parameter is required), and the "
            + "anchor the value pin below searches from. Window: \(arguments)")
    }

    /// The parameter must stay REQUIRED at both declarations.
    ///
    /// A default here would not be inert: `nil` asserts "this conversation contains no
    /// unsolicited arrival", which is a fact only the caller can know, and a caller who
    /// omits the argument silently restores the pre-fix false positive rather than failing.
    /// `cutoffDate` beside it may default because `.distantPast` expresses a POLICY the
    /// caller owns ("don't filter"); this one would assert a FACT about the caller's data.
    /// The compiler is the enforcement — but only while there is no default, and re-adding
    /// one to spare a few test call sites is exactly the shortcut that would look harmless.
    ///
    /// RED: restore `informationBoundary: Date? = nil` on either declaration → this fails
    /// naming the file, and in production the next caller added anywhere can drop the
    /// boundary without a compile error.
    func testCommittedBoundary_hasNoDefault() throws {
        let declaration = "informationBoundary: " + "Date?"
        for path in Self.declarationPaths {
            let src = try source(path)
            guard let decl = src.range(of: declaration) else {
                return XCTFail("\(path) no longer declares the boundary parameter")
            }
            // Scope to THIS parameter's own segment — up to the `,` that starts the next
            // one or the `)` that closes the list — not to the rest of the line. A
            // legitimate default on a NEIGHBOURING parameter declared on the same line
            // would otherwise fail this pin for the wrong reason.
            let tail = src[decl.upperBound...]
            let segmentEnd = tail.firstIndex(where: { $0 == "," || $0 == ")" || $0 == "\n" })
                ?? src.endIndex
            let remainder = String(src[decl.upperBound..<segmentEnd])
            XCTAssertFalse(
                remainder.contains("="),
                "\(path) gave `informationBoundary` a default. `nil` is not a neutral "
                + "fallback — it claims the conversation held no arrival, which silently "
                + "reverts the fix for any caller that forgets it. Remainder: \(remainder)")
        }
    }

    /// The boundary is a `.user` turn, so it is invisible in the `.assistant`-filtered
    /// `recentAssistant` slice built two statements above. It must be read off the
    /// UNFILTERED conversation or it is always nil.
    ///
    /// RED: narrow the argument to `step.llmConversation.filter { $0.role == .assistant }`
    /// or `.suffix(5)` → this fails on the narrowing operator. Asserting only that the text
    /// MENTIONS `step.llmConversation` would pass on both, since both mention it.
    func testCommittedBoundary_readsTheUnfilteredConversation() throws {
        let src = try source(Self.streamingPath)
        guard let argument = src.range(of: "informationBoundary:") else {
            return XCTFail("The committed boundary is not wired at all")
        }
        let lineEnd = src[argument.upperBound...].firstIndex(of: "\n") ?? src.endIndex
        let value = String(src[argument.upperBound..<lineEnd])
        XCTAssertTrue(
            value.contains("step.llmConversation"),
            "The boundary must be derived from the full conversation. Argument: \(value)")
        XCTAssertFalse(
            value.contains("recentAssistant"),
            "recentAssistant is .assistant-filtered — a boundary read from it is always nil")
        // The boundary turn is a `.user` message near the tail; ANY narrowing can drop it,
        // and a dropped boundary is indistinguishable from "no news arrived".
        for narrowing in [".filter", ".suffix", ".prefix", ".dropFirst", ".dropLast"] {
            XCTAssertFalse(
                value.contains(narrowing),
                "`\(narrowing)` narrows the conversation before the boundary is read — the "
                + "arrival it must find is exactly what a narrowing can drop. Argument: \(value)")
        }
    }
}
