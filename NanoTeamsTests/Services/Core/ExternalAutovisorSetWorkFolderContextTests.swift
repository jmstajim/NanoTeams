import XCTest
@testable import NanoTeams

/// `set_work_folder_context` on the hosted surface (decision A3, revised 2026-11-13): an external
/// agent replaces the Work Folder Context when — and only when — the person allowed it on the
/// agent's row. Every refusal writes nothing; the write itself is the built-in manager's action.
@MainActor
final class ExternalAutovisorSetWorkFolderContextTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var agent: AgentIdentity!
    private var folderID: String!

    override func tearDown() async throws {
        agent = nil
        folderID = nil
        try await super.tearDown()
    }

    // MARK: - Harness

    /// A real folder under the external driver, the Autovisor on, and an agent from the store —
    /// allowed to replace the context unless `allowed` says otherwise.
    private func openExternalFolder(allowed: Bool = true) async throws {
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
        agent = try sut.hostedMCPAgentStore.createAgent(label: "Claude Code").record.identity
        if allowed {
            try sut.setHostedMCPAgentMayReplaceWorkFolderContext(true, agentID: agent.id)
        }
    }

    /// `set_work_folder_context` with `args`: the folder's id filled in unless the test sends one,
    /// and `expected_revision` the stored text's — the agent read it just now — unless the test
    /// sends one or asks for none.
    private func call(
        _ args: [String: Any],
        as caller: AgentIdentity? = nil,
        withoutRevision: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> ToolExecutionResult {
        var args = args
        let key = NTMSOrchestrator.expectedRevisionKey
        if !withoutRevision, args[key] == nil, let storedRevision { args[key] = storedRevision }
        return await call(ExternalAutovisorToolNames.setWorkFolderContext, args, as: caller, isCancelled: isCancelled)
    }

    private func call(
        _ tool: String,
        _ args: [String: Any],
        as caller: AgentIdentity? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> ToolExecutionResult {
        var args = args
        if args["folder_id"] == nil, tool != ExternalAutovisorToolNames.folderStatus { args["folder_id"] = folderID }
        return await sut.executeExternalAutovisorTool(
            name: tool, args: args, agent: caller ?? agent, isCancelled: isCancelled)
    }

    /// Writes `args` and fails the test unless the call succeeded.
    @discardableResult
    private func expectWritten(
        _ args: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) async -> ToolExecutionResult {
        let result = await call(args)
        XCTAssertFalse(result.isError, result.outputJSON, file: file, line: line)
        return result
    }

    private func envelope(_ result: ToolExecutionResult) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
    }

    private func error(_ result: ToolExecutionResult, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        XCTAssertTrue(result.isError, result.outputJSON, file: file, line: line)
        return try XCTUnwrap(try envelope(result)["error"] as? [String: Any], file: file, line: line)
    }

    private var storedContext: String? { sut.snapshot?.workFolder.settings.context }
    private var storedStamp: String? { sut.snapshot?.workFolder.settings.contextUpdatedAtStamp }
    private var storedRevision: String? { sut.snapshot?.workFolder.settings.contextRevision }

    private func folderContext(_ args: [String: Any] = [:]) async throws -> [String: Any] {
        let status = await call(ExternalAutovisorToolNames.folderStatus, args)
        let data = try XCTUnwrap(try envelope(status)["data"] as? [String: Any])
        return try XCTUnwrap(data["work_folder_context"] as? [String: Any])
    }

    private func installIndex() -> SearchIndexCoordinator {
        let coordinator = SearchIndexCoordinator(
            workFolderRoot: tempDir,
            internalDir: tempDir.appendingPathComponent(".nanoteams/internal"),
            fileManager: FileManager.default,
            makeWatcher: FakeWatcherFactory.inert)
        sut.searchIndexCoordinator = coordinator
        return coordinator
    }

    // MARK: - The write

    func testAllowedAgent_replacesTheContext_trimmed_andIsAnsweredWithTheFolder() async throws {
        try await openExternalFolder()

        let result = await call(["content": "  A Swift 6 macOS app. Build with xcodebuild.\n"])

        XCTAssertFalse(result.isError, result.outputJSON)
        let data = try XCTUnwrap(try envelope(result)["data"] as? [String: Any])
        XCTAssertEqual(data["folder_id"] as? String, folderID)
        XCTAssertEqual(data["status"] as? String, "ok")
        XCTAssertEqual(data["message"] as? String, AutovisorReply.workFolderContextUpdated.text)
        XCTAssertEqual(storedContext, "A Swift 6 macOS app. Build with xcodebuild.")
        XCTAssertNotNil(storedStamp)
    }

    /// The same text sent again is a write, as it is from Settings and from the built-in manager:
    /// the stamp moves, which is how an agent that checked the text marks it current.
    func testTheSameTextAgain_isWrittenAgain_andMovesTheStamp() async throws {
        try await openExternalFolder()
        await sut.mutateWorkFolder {
            $0.settings.context = "Ledger: a CLI."
            $0.settings.contextUpdatedAt = Date(timeIntervalSinceNow: -3600)
        }
        let before = try XCTUnwrap(storedStamp)

        let result = await call(["content": "Ledger: a CLI."])

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertNotEqual(storedStamp, before)
    }

    /// No cut since 2026-11-13: a text of any length is stored, and the prompt seam hands a role
    /// all of it — until then it kept the first 2000 characters and dropped the rest unsaid.
    func testALongText_isStoredWhole_andReachesARoleWhole() async throws {
        try await openExternalFolder()
        let long = String(repeating: "Facts about the project. ", count: 400)
        let stored = long.trimmingCharacters(in: .whitespacesAndNewlines)

        let result = await call(["content": long])

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(storedContext, stored)
        let prompt = try XCTUnwrap(PromptBuilder.buildWorkFolderContextMessage(
            workFolder: sut.workFolder, toolNames: []))
        XCTAssertTrue(prompt.contains(stored), "the whole \(stored.count)-character text reaches the role")
    }

    // MARK: - The person's switch

    func testAgentNotAllowed_isRefusedNotAllowed_withTheRemedy_andNothingChanges() async throws {
        try await openExternalFolder(allowed: false)
        await sut.mutateWorkFolder { $0.settings.context = "The person's own text." }

        let result = await call(["content": "The agent's text."])

        let error = try error(result)
        XCTAssertEqual(error["code"] as? String, ToolErrorCode.notAllowed.rawValue)
        XCTAssertEqual(error["message"] as? String, NTMSOrchestrator.contextReplacementNotAllowedMessage)
        let details = try XCTUnwrap(error["details"] as? [String: Any])
        XCTAssertEqual(details["what_the_person_must_do"] as? String, NTMSOrchestrator.contextReplacementNotAllowedRemedy)
        let next = try XCTUnwrap(try envelope(result)["next"] as? [String: Any])
        XCTAssertEqual(next["suggested_cmd"] as? String, ExternalAutovisorToolNames.setWorkFolderContext,
                       "the refused tool again, after the asking")
        XCTAssertEqual((next["suggested_args"] as? [String: Any]).map { Set($0.keys) }, ["folder_id"],
                       "nothing else the call sent was read, so the hint carries only where it was refused")
        XCTAssertEqual(next["reason"] as? String, ExternalNextCall.personMustAllow.reason)
        XCTAssertFalse((next["reason"] as? String ?? "").contains("goes through"),
                       "the call's own arguments were never checked: no outcome is promised")
        XCTAssertEqual(storedContext, "The person's own text.")
    }

    /// Asked before anything the agent sent is read: an empty text from an agent nobody allowed
    /// is told it may not write, not that the text is empty.
    func testAgentNotAllowed_isRefusedBeforeItsArgumentsAreRead() async throws {
        try await openExternalFolder(allowed: false)

        let error = try error(await call(["content": "   "]))

        XCTAssertEqual(error["code"] as? String, ToolErrorCode.notAllowed.rawValue)
    }

    /// An agent revoked between the call's arrival and its turn on the main actor, or one the
    /// store never held, is allowed nothing.
    func testAnAgentTheStoreDoesNotHold_isAllowedNothing() async throws {
        try await openExternalFolder()
        let stranger = AgentIdentity(label: "Unknown")

        let error = try error(await call(["content": "x"], as: stranger))

        XCTAssertEqual(error["code"] as? String, ToolErrorCode.notAllowed.rawValue)
    }

    func testTurningTheSwitchOff_refusesTheNextCall() async throws {
        try await openExternalFolder()
        await expectWritten(["content": "First."])

        try sut.setHostedMCPAgentMayReplaceWorkFolderContext(false, agentID: agent.id)

        let error = try error(await call(["content": "Second."]))
        XCTAssertEqual(error["code"] as? String, ToolErrorCode.notAllowed.rawValue)
        XCTAssertEqual(storedContext, "First.")
    }

    // MARK: - Readiness and folder, before the switch

    func testAutovisorOff_isAutovisorOff_evenForAnAgentNobodyAllowed() async throws {
        try await openExternalFolder(allowed: false)
        await sut.setAutovisorEnabled(false)

        let error = try error(await call(["content": "x"]))

        XCTAssertEqual(error["code"] as? String, ToolErrorCode.autovisorOff.rawValue)
    }

    func testBuiltInDriver_isAutovisorOff() async throws {
        try await openExternalFolder()
        await sut.setAutovisorDriver(.builtInModel)

        let error = try error(await call(["content": "x"]))

        XCTAssertEqual(error["code"] as? String, ToolErrorCode.autovisorOff.rawValue)
        XCTAssertEqual(storedContext, "")
    }

    func testAMissingOrForeignFolderID_isRefused_andNothingIsWritten() async throws {
        try await openExternalFolder()

        let missing = try error(await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.setWorkFolderContext, args: ["content": "x"], agent: agent))
        let foreign = try error(await call(["content": "x", "folder_id": UUID().uuidString]))

        XCTAssertEqual(missing["code"] as? String, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(foreign["code"] as? String, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(storedContext, "")
    }

    // MARK: - Arguments

    func testAnUndeclaredArgument_isRefusedByName() async throws {
        try await openExternalFolder()

        let error = try error(await call(["content": "x", "text": "x"]))

        XCTAssertEqual(error["code"] as? String, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertTrue((error["message"] as? String ?? "").contains("text"), "\(error)")
        XCTAssertEqual(storedContext, "")
    }

    /// The dispatcher refuses an undeclared key for every tool before this one's handler runs, so
    /// it comes ahead of readiness and of the switch: the order the docs state.
    func testAnUndeclaredArgument_isRefusedFirst_evenForAnAgentNobodyAllowed_withTheAutovisorOff() async throws {
        try await openExternalFolder(allowed: false)
        await sut.setAutovisorEnabled(false)

        let error = try error(await call(["content": "x", "text": "x"]))

        XCTAssertEqual(error["code"] as? String, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertTrue((error["message"] as? String ?? "").contains("text"), "\(error)")
    }

    func testAMissingNonStringOrEmptyText_isRefused_andNothingIsWritten() async throws {
        try await openExternalFolder()
        await sut.mutateWorkFolder { $0.settings.context = "Kept." }

        for args: [String: Any] in [[:], ["content": 42], ["content": ""], ["content": " \n\t "]] {
            let error = try error(await call(args))
            XCTAssertEqual(error["code"] as? String, ToolErrorCode.invalidArgs.rawValue, "\(args)")
        }
        let empty = try error(await call(["content": "  "]))
        XCTAssertTrue((empty["message"] as? String ?? "").contains(AutovisorToolDecoding.emptyContextDetail), "\(empty)")
        XCTAssertEqual(storedContext, "Kept.")
    }

    // MARK: - Characters that change how text displays

    func testRenderingControls_areRefusedByCodePointAndPosition_andNothingIsWritten() async throws {
        try await openExternalFolder()

        let cases: [(text: String, codePoint: String, position: Int)] = [
            ("Swift app \u{202E}detcelfer", "U+202E", 11),
            ("tag\u{E0041}\u{E0042}", "U+E0041", 4),
            ("\u{1B}[2Jclears the screen", "U+001B", 1),
            // A directional mark moves no character and hides none, but around each word it
            // makes a left-to-right line right-to-left: "production not staging" lays out as
            // "staging not production" in the person's editor while the role reads it as sent.
            ("\u{200F}production\u{200F} \u{200F}not\u{200F} \u{200F}staging\u{200F}", "U+200F", 1),
            ("deploy \u{200E}x", "U+200E", 8),
            ("ab\u{061C}c", "U+061C", 3),
        ]
        for c in cases {
            let error = try error(await call(["content": c.text]))
            XCTAssertEqual(error["code"] as? String, ToolErrorCode.invalidArgs.rawValue, c.text)
            let message = error["message"] as? String ?? ""
            XCTAssertTrue(message.contains(c.codePoint), message)
            XCTAssertTrue(message.contains("position \(c.position)"), message)
        }
        XCTAssertEqual(storedContext, "")
    }

    /// What the sanitizer keeps is no hiding place: the Persian ZWNJ, the joiner inside an emoji,
    /// right-to-left letters themselves, a tab, a CRLF.
    func testWhatTheSanitizerKeeps_isAccepted() async throws {
        try await openExternalFolder()
        let text = "نام\u{200C}خانوادگی שלום 👨\u{200D}💻\ttab\r\nnext line"

        let result = await call(["content": text])

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(storedContext, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testHiddenScalars_countsEveryRemovedScalarAndFindsTheFirst() {
        XCTAssertNil(NTMSOrchestrator.hiddenScalars(in: "plain text"))
        let found = NTMSOrchestrator.hiddenScalars(in: "ab\u{202E}c\u{202C}d")
        XCTAssertEqual(found?.count, 2)
        XCTAssertEqual(found?.first, "\u{202E}")
        XCTAssertEqual(found?.position, 3)
        let marks = NTMSOrchestrator.hiddenScalars(in: "a\u{200F}b\u{200E}c\u{061C}")
        XCTAssertEqual(marks?.count, 3)
        XCTAssertEqual(marks?.first, "\u{200F}")
        XCTAssertEqual(marks?.position, 2)
    }

    // MARK: - updated_at and the revision

    /// When the text was written, as folder_status spells it: ISO 8601 in UTC, whole seconds, and
    /// none for a context never written. It says when; the write is checked against the revision.
    func testTheStamp_isWholeSecondISO8601InUTC_andAbsentForAContextNeverWritten() {
        XCTAssertNil(ProjectSettings().contextUpdatedAtStamp)
        let written = ProjectSettings(contextUpdatedAt: Date(timeIntervalSince1970: 1_794_594_635.789))
        XCTAssertEqual(written.contextUpdatedAtStamp, "2026-11-13T18:30:35Z")
    }

    /// The revision names the text: equal texts, equal revisions, whenever and however often they
    /// were written; one character apart, two. Every text has one, the empty one included.
    func testTheRevision_namesTheText_notAMoment() {
        var settings = ProjectSettings()
        XCTAssertEqual(settings.contextRevision, "cbf29ce484222325", "FNV-1a 64 of no bytes is its offset basis")
        settings.context = "A Swift app."
        let first = settings.contextRevision
        settings.contextUpdatedAt = Date(timeIntervalSinceNow: 3600)
        XCTAssertEqual(settings.contextRevision, first, "a new stamp is not a new text")
        settings.context = "A Swift app!"
        XCTAssertNotEqual(settings.contextRevision, first)
        settings.context = "A Swift app."
        XCTAssertEqual(settings.contextRevision, first, "changed back is the text that was read")
        XCTAssertEqual(first.count, 16)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit && !$0.isUppercase }, first)
    }

    func testFolderStatus_publishesTheRevisionBesideTheText_andNeverWithoutIt() async throws {
        try await openExternalFolder()
        await expectWritten(["content": "First."])

        let context = try await folderContext()
        let hidden = try await folderContext(["include_context": false])

        XCTAssertEqual(context["text"] as? String, "First.")
        XCTAssertEqual(context["revision"] as? String, storedRevision)
        XCTAssertNil(hidden["text"])
        XCTAssertNil(hidden["revision"], "a revision with no text would let a write replace what nobody read")
    }

    /// A folder whose context nobody wrote still publishes one, so the first write has a revision
    /// to send back — before 2026-11-13 the object was absent and the write went unchecked.
    func testAnEmptyContext_isPublishedWithItsRevision() async throws {
        try await openExternalFolder()
        XCTAssertEqual(storedContext, "", "premise: nothing written yet")

        let context = try await folderContext()

        XCTAssertEqual(context["text"] as? String, "")
        XCTAssertEqual(context["revision"] as? String, ProjectSettings().contextRevision)
    }

    func testTheRevisionRead_writes() async throws {
        try await openExternalFolder()
        await expectWritten(["content": "First."])
        let readContext = try await folderContext()
        let read = try XCTUnwrap(readContext["revision"] as? String)

        let result = await call(["content": "Second.", NTMSOrchestrator.expectedRevisionKey: read])

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(storedContext, "Second.")
    }

    /// The person typed after the agent read: the write is refused and names no revision to copy
    /// — a revision taken from a refusal would replace a text nobody read.
    func testATextReplacedAfterTheRead_isConflict_namingNoRevision_andNothingIsWritten() async throws {
        try await openExternalFolder()
        await expectWritten(["content": "First."])
        let readContext = try await folderContext()
        let read = try XCTUnwrap(readContext["revision"] as? String)
        _ = await sut.updateWorkFolderContext("The person's edit.")

        let result = await call(["content": "The agent's text.", NTMSOrchestrator.expectedRevisionKey: read])

        let error = try error(result)
        XCTAssertEqual(error["code"] as? String, ToolErrorCode.conflict.rawValue)
        XCTAssertEqual(error["message"] as? String, AutovisorReply.workFolderContextChangedSinceRead.text)
        XCTAssertFalse((error["message"] as? String ?? "").contains(try XCTUnwrap(storedRevision)))
        let next = try XCTUnwrap(try envelope(result)["next"] as? [String: Any])
        XCTAssertEqual(next["suggested_cmd"] as? String, ExternalAutovisorToolNames.folderStatus)
        XCTAssertEqual(storedContext, "The person's edit.")
    }

    /// The review's first case (2026-11-13): a context last written before the stamp existed has
    /// no `updated_at`, so the stamp could not say it was read — and the person's later edit was
    /// replaced unchecked. The revision is there for it as for any text.
    func testAContextThatWasNeverStamped_isProtectedToo() async throws {
        try await openExternalFolder()
        await sut.mutateWorkFolder {
            $0.settings.context = "Written by an older build."
            $0.settings.contextUpdatedAt = nil
        }
        XCTAssertNil(storedStamp, "premise: no stamp")
        let readContext = try await folderContext()
        let read = try XCTUnwrap(readContext["revision"] as? String)
        _ = await sut.updateWorkFolderContext("The person's edit.")

        let error = try error(await call(["content": "x", NTMSOrchestrator.expectedRevisionKey: read]))

        XCTAssertEqual(error["code"] as? String, ToolErrorCode.conflict.rawValue)
        XCTAssertEqual(storedContext, "The person's edit.")
    }

    /// Two saves within one second shared a stamp, so a read between them matched the second
    /// (review, 2026-11-13). They are two texts and two revisions.
    func testTwoSavesInOneSecond_areTwoRevisions() async throws {
        try await openExternalFolder()
        let second = Date(timeIntervalSince1970: 1_794_594_635)
        await sut.mutateWorkFolder {
            $0.settings.context = "The person's first save."
            $0.settings.contextUpdatedAt = second
        }
        let readContext = try await folderContext()
        let read = try XCTUnwrap(readContext["revision"] as? String)
        await sut.mutateWorkFolder {
            $0.settings.context = "The person's second save."
            $0.settings.contextUpdatedAt = second.addingTimeInterval(0.6)
        }
        XCTAssertEqual(storedStamp, "2026-11-13T18:30:35Z", "premise: one stamp for both saves")

        let error = try error(await call(["content": "x", NTMSOrchestrator.expectedRevisionKey: read]))

        XCTAssertEqual(error["code"] as? String, ToolErrorCode.conflict.rawValue)
        XCTAssertEqual(storedContext, "The person's second save.")
    }

    /// Missing, null or blank: one fault, one remedy — read the context, which carries the
    /// revision. Until 2026-11-13 an omitted precondition wrote unchecked.
    func testAMissingNullOrBlankRevision_isRefused_pointingAtTheRead_andNothingIsWritten() async throws {
        try await openExternalFolder()
        await sut.mutateWorkFolder { $0.settings.context = "Kept." }
        let key = NTMSOrchestrator.expectedRevisionKey

        for args: [String: Any] in [["content": "x"], ["content": "x", key: NSNull()], ["content": "x", key: ""], ["content": "x", key: "  "]] {
            let result = await call(args, withoutRevision: true)
            let error = try error(result)
            XCTAssertEqual(error["code"] as? String, ToolErrorCode.invalidArgs.rawValue, "\(args)")
            XCTAssertTrue((error["message"] as? String ?? "").contains(key), "\(error)")
            let next = try XCTUnwrap(try envelope(result)["next"] as? [String: Any])
            XCTAssertEqual(next["suggested_cmd"] as? String, ExternalAutovisorToolNames.folderStatus, "\(args)")
        }
        XCTAssertEqual(storedContext, "Kept.")
    }

    func testANonStringRevision_isRefused_andNothingIsWritten() async throws {
        try await openExternalFolder()

        for bad: Any in [42, true, ["cbf29ce484222325"], ["revision": "cbf29ce484222325"]] {
            let error = try error(await call(["content": "x", NTMSOrchestrator.expectedRevisionKey: bad]))
            XCTAssertEqual(error["code"] as? String, ToolErrorCode.invalidArgs.rawValue, "\(bad)")
            XCTAssertTrue((error["message"] as? String ?? "").contains(NTMSOrchestrator.contextRevisionNotARevisionDetail),
                          "\(error)")
        }
        XCTAssertEqual(storedContext, "")
    }

    /// The schema says so, so a client that lists required arguments asks its model for it.
    func testTheSchema_requiresTheRevision() throws {
        let tool = try XCTUnwrap(HostedMCPCatalog.allTools.first { $0.name == ExternalAutovisorToolNames.setWorkFolderContext })
        XCTAssertEqual(Set(tool.inputSchema.required ?? []), ["folder_id", "content", NTMSOrchestrator.expectedRevisionKey])
    }

    // MARK: - Withdrawn, and the action itself

    func testACallWithdrawnBeforeTheWrite_isCancelled_andNothingIsWritten() async throws {
        try await openExternalFolder()

        let error = try error(await call(["content": "x"], isCancelled: { true }))

        XCTAssertEqual(error["code"] as? String, ToolErrorCode.cancelled.rawValue)
        XCTAssertEqual(storedContext, "")
    }

    func testTheAction_withARevisionThatMoved_failsAsContextChanged() async throws {
        try await openExternalFolder()
        await sut.mutateWorkFolder { $0.settings.context = "Now." }

        let result = await sut.performAutovisorAction(
            .setWorkFolderContext(content: "Later.", expectedRevision: ProjectSettings().contextRevision),
            as: .externalAgent(agent, session: nil),
            within: sut.currentFolderLifecycle)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.failure, .contextChanged)
        XCTAssertEqual(storedContext, "Now.")
    }

    func testTheWriter_reportsWhatItDid() async throws {
        try await openExternalFolder()

        let written = await sut.updateWorkFolderContext("One.", expectedRevision: ProjectSettings().contextRevision)
        let refused = await sut.updateWorkFolderContext("Two.", expectedRevision: ProjectSettings().contextRevision)

        XCTAssertEqual(written, .written, "the empty text's revision, read before the first write")
        XCTAssertEqual(refused, .changedSinceRead)
        XCTAssertEqual(storedContext, "One.")
    }

    // MARK: - The activity log

    /// The summary line keeps the length of the text, trimmed as it is stored, and never the
    /// text: what an agent writes there rides every reading role's prompt, and the log is read in the pane.
    func testTheWrite_isLoggedWithItsLength_neverItsText() async throws {
        try await openExternalFolder()
        let marker = "CONTEXT_BODY_MARKER_DO_NOT_LOG_5521"
        let content = "  Facts: \(marker).\n"

        await expectWritten(["content": content])
        sut.externalActivityLog.flush()

        let record = try XCTUnwrap(sut.externalActivityLog.records.last)
        XCTAssertEqual(record.tool, ExternalAutovisorToolNames.setWorkFolderContext)
        XCTAssertTrue(record.ok)
        XCTAssertEqual(record.argumentsSummary, "characters=\(content.trimmingCharacters(in: .whitespacesAndNewlines).count)")
        XCTAssertEqual(record.headline, "Claude Code replaced the Work Folder Context")
        XCTAssertTrue(record.reachesEveryTask)
        XCTAssertNil(record.taskID)
        let logURL = try XCTUnwrap(sut.externalActivityLog.logURL)
        let onDisk = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(onDisk.contains(marker), "the summary log holds no text of the context")
    }

    func testARefusal_isLoggedAsAFailure_thatReachesNoTask() async throws {
        try await openExternalFolder(allowed: false)

        _ = await call(["content": "x"])
        sut.externalActivityLog.flush()

        let record = try XCTUnwrap(sut.externalActivityLog.records.last)
        XCTAssertFalse(record.ok)
        XCTAssertEqual(record.errorCode, ToolErrorCode.notAllowed.rawValue)
        XCTAssertFalse(record.reachesEveryTask)
    }

    // MARK: - Freshness, as folder_status reads it after

    func testAfterTheWrite_theContextIsNotStale() async throws {
        try await openExternalFolder()
        let coordinator = installIndex()
        let file = tempDir.appendingPathComponent("Main.swift")
        try "let x = 1".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: file.path)
        await coordinator.rebuild()

        await expectWritten(["content": "A Swift app."])

        let context = try await folderContext()
        XCTAssertEqual(context["stale"] as? Bool, false)
    }

    /// What a team writes under `.nanoteams/` after the context is no project fact the context
    /// missed: an artifact newer than the write leaves it fresh (`maxProjectFileMTime`). The test
    /// above has no such file, so it stayed green with the old all-files maximum (review, 2026-11-13).
    func testAnArtifactWrittenAfterTheContext_leavesItFresh_andAProjectFileMakesItStale() async throws {
        try await openExternalFolder()
        let coordinator = installIndex()
        let file = tempDir.appendingPathComponent("Main.swift")
        try "let x = 1".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: file.path)
        await coordinator.rebuild()
        let filesBefore = try XCTUnwrap(coordinator.fileCount)
        await expectWritten(["content": "A Swift app."])
        let artifact = tempDir.appendingPathComponent(".nanoteams/tasks/1/runs/0/roles/engineer/artifact_notes.md")
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "notes".write(to: artifact, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: artifact.path)
        await coordinator.rebuild()
        XCTAssertEqual(coordinator.fileCount, filesBefore + 1,
                       "premise: the index holds the artifact, so only the exclusion keeps it out")

        let fresh = try await folderContext()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: file.path)
        await coordinator.rebuild()
        let stale = try await folderContext()

        XCTAssertEqual(fresh["stale"] as? Bool, false)
        XCTAssertEqual(stale["stale"] as? Bool, true)
    }

    // MARK: - list_teams

    /// Only a template carrying the chip renders the context — there is no fallback insertion
    /// for it — so the bundled Personal Assistant and Quest Party, and any team whose author took
    /// the chip out, never show it to a role.
    func testReadsWorkFolderContext_followsTheTemplatesChip() async {
        XCTAssertTrue(TeamTemplateFactory.codingAssistant().readsWorkFolderContext)
        XCTAssertTrue(TeamTemplateFactory.faang().readsWorkFolderContext)
        XCTAssertFalse(TeamTemplateFactory.assistant().readsWorkFolderContext)
        XCTAssertFalse(TeamTemplateFactory.questParty().readsWorkFolderContext)
        var edited = TeamTemplateFactory.codingAssistant()
        edited.systemPromptTemplate = edited.systemPromptTemplate
            .replacingOccurrences(of: "{workFolderContext}", with: "")
        XCTAssertFalse(edited.readsWorkFolderContext)
    }

    func testListTeams_saysWhichTeamsRolesReadTheContext() async throws {
        try await openExternalFolder()

        let result = await call(ExternalAutovisorToolNames.listTeams, [:])
        let data = try XCTUnwrap(try envelope(result)["data"] as? [String: Any])
        let teams = try XCTUnwrap(data["teams"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: teams.compactMap { team -> (String, Bool)? in
            guard let name = team["name"] as? String, let reads = team["reads_work_folder_context"] as? Bool
            else { return nil }
            return (name, reads)
        })

        XCTAssertFalse(byName.isEmpty, "every team row carries the field: \(teams)")
        for team in sut.snapshot?.workFolder.teams ?? [] where byName[team.name] != nil {
            XCTAssertEqual(byName[team.name], team.readsWorkFolderContext, team.name)
        }
    }
}
