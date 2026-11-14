import XCTest

@testable import NanoTeams

/// `ExternalFolderRefusal` — why an external call's `folder_id` was refused, and by case the
/// refusal's code, message and next call. Pure: the orchestrator gathers the facts and
/// `classify` decides, so every branch is reachable here without staging a folder transition.
///
/// Until 2026-11-08 the code was picked by `message.hasPrefix("Missing required")`, a missing
/// `folder_id` came back with no next call, and an id from another folder — or a call made while
/// no folder was open — answered with the wording of a race that had not happened.
final class ExternalFolderRefusalTests: XCTestCase {

    private let openID = "AAAAAAAA-1111-2222-3333-444444444444"

    private func classify(
        provided: String?,
        required: Bool = true,
        transition: Bool = false,
        lifecycleCurrent: Bool = true,
        inUseElsewhere: Bool = false,
        realFolder: Bool = true,
        openFolderID: String? = "AAAAAAAA-1111-2222-3333-444444444444"
    ) -> ExternalFolderRefusal? {
        ExternalFolderRefusal.classify(
            providedFolderID: provided,
            required: required,
            isFolderTransitionInProgress: transition,
            isLifecycleCurrent: lifecycleCurrent,
            isFolderInUseByAnotherProcess: inUseElsewhere,
            hasRealWorkFolder: realFolder,
            openFolderID: openFolderID)
    }

    // MARK: - classify

    func testTheOpenFolderPasses_caseInsensitiveAndTrimmed() {
        XCTAssertNil(classify(provided: openID))
        XCTAssertNil(classify(provided: openID.lowercased()))
        XCTAssertNil(classify(provided: "  \(openID)\n"))
    }

    func testAnOptionalFolderIDMayBeOmitted() {
        XCTAssertNil(classify(provided: nil, required: false))
        XCTAssertNil(classify(provided: "   ", required: false))
    }

    func testARequiredFolderIDThatIsAbsentOrBlankIsMissing() {
        XCTAssertEqual(classify(provided: nil), .missingFolderID)
        XCTAssertEqual(classify(provided: ""), .missingFolderID)
        XCTAssertEqual(classify(provided: " \t"), .missingFolderID)
    }

    /// An argument error is reported as one whatever state the folder is in.
    func testMissingIsReportedBeforeTheFolderState() {
        XCTAssertEqual(classify(provided: nil, transition: true), .missingFolderID)
        XCTAssertEqual(classify(provided: nil, realFolder: false, openFolderID: nil), .missingFolderID)
    }

    func testAnotherFolderIDIsNotTheOpenFolder() {
        XCTAssertEqual(classify(provided: "BBBBBBBB-1111-2222-3333-444444444444"), .notTheOpenFolder)
        XCTAssertEqual(classify(provided: "not-a-uuid", required: false), .notTheOpenFolder)
    }

    /// A transition in progress is the state the call arrived in, not a change during it — the
    /// lifecycle a call captures mid-transition is already over, so this must be asked first.
    func testATransitionInProgressIsReportedAsSuch() {
        XCTAssertEqual(classify(provided: openID, transition: true, lifecycleCurrent: false), .folderTransitionInProgress)
        XCTAssertEqual(classify(provided: nil, required: false, transition: true), .folderTransitionInProgress)
    }

    /// The race wording is kept for the one case it describes: the lifecycle the call began in
    /// ended while it ran, and the next folder has since committed.
    func testOnlyAnEndedLifecycleIsAChangeDuringTheCall() {
        XCTAssertEqual(classify(provided: openID, lifecycleCurrent: false), .changedDuringCall)
        XCTAssertEqual(classify(provided: nil, required: false, lifecycleCurrent: false), .changedDuringCall)
    }

    /// A folder another NanoTeams process holds: this one committed the URL with nothing loaded,
    /// so it is refused as that — never as "no folder", and never as "not the open folder" for the
    /// id the agent read before (F6 C1, 2026-11-12). An argument error and a transition still come first.
    func testAFolderHeldElsewhereIsInUse() {
        XCTAssertEqual(classify(provided: openID, inUseElsewhere: true, openFolderID: nil), .folderInUse)
        XCTAssertEqual(classify(provided: nil, required: false, inUseElsewhere: true, openFolderID: nil), .folderInUse)
        XCTAssertEqual(classify(provided: nil, inUseElsewhere: true), .missingFolderID)
        XCTAssertEqual(classify(provided: openID, transition: true, inUseElsewhere: true), .folderTransitionInProgress)
        XCTAssertEqual(ExternalFolderRefusal.folderInUse.code, .commandFailed)
        XCTAssertEqual(ExternalFolderRefusal.folderInUse.message, ExternalAutovisorReadiness.Refusal.folderInUse.message)
        XCTAssertEqual(ExternalFolderRefusal.folderInUse.next.suggested_cmd, ExternalAutovisorToolNames.folderStatus)
    }

    func testNoRealFolderIsNoWorkFolder_withOrWithoutAnID() {
        XCTAssertEqual(classify(provided: openID, realFolder: false), .noWorkFolder)
        XCTAssertEqual(classify(provided: nil, required: false, realFolder: false), .noWorkFolder)
        XCTAssertEqual(classify(provided: openID, openFolderID: nil), .noWorkFolder)
    }

    // MARK: - What each case answers

    func testCodes() {
        XCTAssertEqual(ExternalFolderRefusal.missingFolderID.code, .invalidArgs)
        XCTAssertEqual(ExternalFolderRefusal.notTheOpenFolder.code, .invalidArgs)
        XCTAssertEqual(ExternalFolderRefusal.folderTransitionInProgress.code, .commandFailed)
        XCTAssertEqual(ExternalFolderRefusal.noWorkFolder.code, .commandFailed)
        // One code for the folder changing under a call, on the whole external surface (N16).
        XCTAssertEqual(ExternalFolderRefusal.changedDuringCall.code, .folderChanged)
    }

    /// The two refusals the agent can fix itself say where a folder_id comes from and name the
    /// call that returns it, in the message and as the next hint.
    func testTheArgumentRefusalsNameTheSourceAndPointAtFolderStatus() {
        for refusal in [ExternalFolderRefusal.missingFolderID, .notTheOpenFolder] {
            XCTAssertTrue(refusal.message.contains("folder_status"), refusal.message)
            XCTAssertTrue(refusal.message.contains("check that its path is your project"), refusal.message)
            XCTAssertEqual(refusal.next.suggested_cmd, ExternalAutovisorToolNames.folderStatus)
            XCTAssertNil(refusal.next.suggested_args, "folder_status takes no arguments")
            XCTAssertEqual(refusal.next.reason, ExternalNextCall.folderID.reason)
            XCTAssertNotEqual(refusal.message, DeferredCallReplies.folderChanged)
        }
        XCTAssertTrue(ExternalFolderRefusal.missingFolderID.message.hasPrefix("Missing required parameter: folder_id"))
        XCTAssertTrue(
            ExternalFolderRefusal.notTheOpenFolder.message.contains("not the work folder open in NanoTeams now"),
            ExternalFolderRefusal.notTheOpenFolder.message)
    }

    /// The folder states answer with the same fact-and-fix a write is refused with in that state
    /// — read off `ExternalAutovisorReadiness.Refusal` as a `String`, not off a `String?` with an
    /// empty fallback (until 2026-11-08 the two arms spelled `?? ""` for a `nil` no state
    /// produced) — and no race.
    func testTheFolderStatesAnswerWithTheReadinessSentences() {
        XCTAssertEqual(
            ExternalFolderRefusal.folderTransitionInProgress.message,
            ExternalAutovisorReadiness.Refusal.folderTransition.message)
        XCTAssertEqual(
            ExternalFolderRefusal.noWorkFolder.message,
            ExternalAutovisorReadiness.Refusal.noWorkFolder.message)
        XCTAssertEqual(
            ExternalFolderRefusal.folderTransitionInProgress.message,
            ExternalAutovisorReadiness.forState(.folderTransition).refusalMessage,
            "the read refusal and the write refusal are one sentence")
        XCTAssertEqual(
            ExternalFolderRefusal.noWorkFolder.message,
            ExternalAutovisorReadiness.forState(.noWorkFolder).refusalMessage)
        // Since 2026-11-12 (F6 L1) the folder states name `folder_status` — the call that says
        // when they are over — like every other refusal.
        XCTAssertEqual(ExternalFolderRefusal.folderTransitionInProgress.next.reason, ExternalNextCall.folderNotReady.reason)
        XCTAssertEqual(ExternalFolderRefusal.noWorkFolder.next.reason, ExternalNextCall.folderNotReady.reason)
    }

    func testAChangeDuringTheCallKeepsTheRaceReply() {
        XCTAssertEqual(ExternalFolderRefusal.changedDuringCall.message, DeferredCallReplies.folderChanged)
        XCTAssertEqual(ExternalFolderRefusal.changedDuringCall.next.reason, ExternalNextCall.folderChanged.reason)
    }

    /// Every case `classify` can answer carries a sentence — none of them an empty string, or
    /// whitespace, which an agent would read as a refusal with no reason.
    func testEveryCaseSaysSomething() {
        for refusal in ExternalFolderRefusal.allCases {
            XCTAssertFalse(
                refusal.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(refusal) refuses with nothing to say")
        }
    }

    /// Every state but `.ready` is a `Refusal`, each refusal is some state's, and a refusal is the
    /// fact then the fix — both present, since a caller that names a refusing state reads them
    /// as `String`s. The static seams the fingerprint registry renders answer the same text.
    func testEveryRefusingStateHasItsRefusal_andReadyHasNone() throws {
        XCTAssertNil(ExternalAutovisorReadiness.State.ready.refusal)
        XCTAssertNil(ExternalAutovisorReadiness.reason(for: .ready))
        XCTAssertNil(ExternalAutovisorReadiness.whatThePersonMustDo(for: .ready))

        var refusals: [ExternalAutovisorReadiness.Refusal] = []
        for state in ExternalAutovisorReadiness.State.allCases where state != .ready {
            let refusal = try XCTUnwrap(state.refusal, "\(state) refuses, so it names a refusal")
            refusals.append(refusal)
            XCTAssertEqual(ExternalAutovisorReadiness.reason(for: state), refusal.reason, "\(state)")
            XCTAssertEqual(
                ExternalAutovisorReadiness.whatThePersonMustDo(for: state), refusal.whatThePersonMustDo, "\(state)")
            XCTAssertEqual(ExternalAutovisorReadiness.forState(state).refusalMessage, refusal.message, "\(state)")
        }
        XCTAssertEqual(Set(refusals), Set(ExternalAutovisorReadiness.Refusal.allCases), "no refusal belongs to no state")
        XCTAssertEqual(refusals.count, ExternalAutovisorReadiness.Refusal.allCases.count, "and no two states share one")

        for refusal in ExternalAutovisorReadiness.Refusal.allCases {
            XCTAssertFalse(refusal.reason.isEmpty, "\(refusal)")
            XCTAssertFalse(refusal.whatThePersonMustDo.isEmpty, "\(refusal)")
            XCTAssertEqual(refusal.message, refusal.reason + " " + refusal.whatThePersonMustDo, "\(refusal)")
        }
    }

    func testTheReadinessRefusalIsTheFactThenTheFix_andNothingWhenReady() {
        for state in ExternalAutovisorReadiness.State.allCases where state != .ready {
            let readiness = ExternalAutovisorReadiness.forState(state)
            XCTAssertEqual(
                readiness.refusalMessage,
                [readiness.reason, readiness.whatThePersonMustDo].compactMap { $0 }.joined(separator: " "))
        }
        XCTAssertNil(ExternalAutovisorReadiness.forState(.ready).refusalMessage)
    }

    /// `refusalMessage` is what the VALUE carries: a value made by hand with one sentence answers
    /// that sentence, one with none answers nothing — it does not reach past its own fields.
    func testRefusalMessageReadsTheValuesOwnSentences() {
        XCTAssertEqual(
            ExternalAutovisorReadiness(state: .builtInDriver, reason: "Built-in model is active.").refusalMessage,
            "Built-in model is active.")
        XCTAssertNil(ExternalAutovisorReadiness(state: .noWorkFolder).refusalMessage)
    }

    /// The envelope carries the case's code, message and next — not a string a caller re-reads.
    func testTheErrorResultCarriesAllThree() throws {
        let result = ExternalFolderRefusal.notTheOpenFolder.errorResult(
            toolName: ExternalAutovisorToolNames.controlTask, args: ["folder_id": "X"])
        XCTAssertTrue(result.isError)
        let data = try XCTUnwrap(result.outputJSON.data(using: .utf8))
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(error["message"] as? String, ExternalFolderRefusal.notTheOpenFolder.message)
        let next = try XCTUnwrap(envelope["next"] as? [String: Any])
        XCTAssertEqual(next["suggested_cmd"] as? String, ExternalAutovisorToolNames.folderStatus)
    }
}
