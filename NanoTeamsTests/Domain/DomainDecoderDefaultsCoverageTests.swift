import XCTest

@testable import NanoTeams

/// The `decodeIfPresent(...) ?? default` arms in `Domain/` — the path every legacy `.nanoteams`
/// file takes on the work-folder open that first reads it.
///
/// This is the same class `DomainValueTypeCoverageTests` opens with, and it is separated from the
/// derived-getter tier for one reason: a wrong `??` default is silent. Nothing throws, nothing
/// logs, the file loads, and the damage shows up later as a task that will not start, a counter
/// that re-issues a live ID, or a schedule that quietly stops firing. CLAUDE.md #48 documents the
/// adjacent trap (a legacy decode that forgets to bump `schemaVersion` re-fires forever); this
/// file covers the other half — the values that legacy branch produces.
///
/// Two rules hold throughout:
///
/// - Every test asserts the DEFAULT VALUE, never that decoding succeeded. "It decoded" passes
///   against any default at all, including one that quietly changes engine behaviour.
/// - Where an existing suite already decodes the type, the fixture here is the one it does NOT
///   supply. `TeamArtifactTests.testCodableWithDefaults` passes `createdAt`/`updatedAt`;
///   `TeamMeetingTests.testTeamMessage_codable_backwardsCompatibility_missingThinkingAndTools`
///   passes `messageType`. Those keys are exactly the holes closed below.
final class DomainDecoderDefaultsCoverageTests: XCTestCase {

    // MARK: - Legacy-file fixture helper

    /// Re-encodes `value` and deletes `keys` from the resulting JSON object — exactly the shape a
    /// file written before those fields existed has on disk.
    ///
    /// Used only where the type's REQUIRED fields have a non-obvious encoded shape: `RecurrenceRule`
    /// is an enum with associated values (synthesized nested-object form) and `Role` has a custom
    /// single-value string encoding. Hand-writing those fixtures would pin an encoding detail this
    /// file has no business pinning; round-tripping the real value pins only the absent key.
    ///
    /// A plain `JSONEncoder`/`JSONDecoder` pair is deliberate: both default to `.deferredToDate`,
    /// so dates survive the strip unchanged.
    ///
    /// The `XCTAssertNotNil` on the removal is an anti-vacuum guard. If a key is renamed, a silent
    /// no-op removal would leave the field PRESENT and the test would assert a default it never
    /// reached.
    private func legacyJSON<T: Encodable>(
        _ value: T,
        removing keys: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any],
            "encoded \(T.self) is not a JSON object", file: file, line: line
        )
        for key in keys {
            let removed = object.removeValue(forKey: key)
            XCTAssertNotNil(
                removed,
                "'\(key)' was already absent from encoded \(T.self) — the fixture proves nothing",
                file: file, line: line
            )
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - NTMSTask (task.json)

    /// `NTMSTask.init(from:)` requires only `id` and `title`; everything else has a default. A
    /// `task.json` written before the brief was a separate field decodes through all of them.
    ///
    /// `supervisorTask` defaulting to `""` rather than, say, the title is what keeps
    /// `hasInitialInput` honest: an empty brief means the task has nothing for the first role to
    /// act on, and the UI must not manufacture input the Supervisor never wrote.
    ///
    /// The lineage assertions cover the legacy branch below it — absent `lineage` AND absent flat
    /// keys resolve to `.root`, which is the invariant `(parent == nil) ↔ (depth == 0)` holding by
    /// construction rather than by clamping.
    ///
    /// RED: change `supervisorTask` to `?? title` in `NTMSTask.init(from:)` → the isEmpty
    /// assertion fails.
    func testNTMSTask_legacyTaskWithOnlyIDAndTitle_takesEveryDefault() throws {
        // Bracketed on the SAME clock production stamps with. `createdAt`/`updatedAt` default to
        // `?? MonotonicClock.shared.now()`, and without these bounds both could be mutated to
        // `Date(timeIntervalSince1970: 0)` with this file still green — a legacy task would then
        // sort to the top of every feed forever. Monotonic on both sides, never `Date()`: the two
        // clocks diverge by up to p99 37s under parallel load (CLAUDE.md 2026-07-18).
        let before = MonotonicClock.shared.now()
        let task = try JSONDecoder().decode(
            NTMSTask.self, from: Data(#"{"id":4,"title":"Legacy"}"#.utf8)
        )
        let after = MonotonicClock.shared.now()

        XCTAssertGreaterThan(task.createdAt, before,
                             "an absent createdAt is stamped now, not defaulted to the epoch")
        XCTAssertLessThan(task.updatedAt, after)

        XCTAssertEqual(task.id, 4)
        XCTAssertEqual(task.title, "Legacy")
        XCTAssertTrue(task.supervisorTask.isEmpty,
                      "an absent brief is empty, never synthesized from the title")
        XCTAssertFalse(task.hasInitialInput,
                       "the consequence: no brief, no clips, no attachments means no initial input")
        XCTAssertTrue(task.clippedTexts.isEmpty)
        XCTAssertTrue(task.attachmentPaths.isEmpty)
        XCTAssertTrue(task.runs.isEmpty)
        XCTAssertEqual(task.status, .running)
        XCTAssertNil(task.closedAt)
        XCTAssertNil(task.recurrence)
        XCTAssertNil(task.runTimeoutSeconds)
        XCTAssertFalse(task.isChatMode,
                       "no generated team and no stored flag means pipeline mode, not chat")
        XCTAssertNil(task.parentTaskID)
        XCTAssertNil(task.parentRoleID)
        XCTAssertEqual(task.delegationDepth, 0,
                       "absent lineage AND absent legacy keys resolve to .root")
    }

    // MARK: - TasksIndex (tasks_index.json)

    /// `TasksIndex` from an empty object. `nextTaskID`'s default is a two-step fallback — derive
    /// from the highest existing task, else 0 — and an empty `tasks` takes the `?? 0` tail.
    ///
    /// RED: change `schemaVersion`'s default to 0 → the schemaVersion assertion fails.
    func testTasksIndex_emptyObject_takesEveryDefault() throws {
        let index = try JSONDecoder().decode(TasksIndex.self, from: Data("{}".utf8))

        XCTAssertEqual(index.schemaVersion, 1)
        XCTAssertTrue(index.tasks.isEmpty)
        XCTAssertEqual(index.nextTaskID, 0,
                       "an empty index starts allocating at 0 — there is nothing to collide with")
    }

    /// The other arm of that fallback, and the one with teeth: an index written before the
    /// counter existed derives `nextTaskID` from the tasks it already lists.
    ///
    /// `?? 0` here — the tempting simplification — would hand the next `createTask` an ID whose
    /// `.nanoteams/tasks/<id>/` directory already exists, so the new task would silently adopt the
    /// old one's runs, artifacts and attachments.
    ///
    /// The fixture discriminates MAX from COUNT deliberately: ids {3, 7} number two tasks but must
    /// yield 8, not 2. Tasks are deleted from the middle of the range all the time, so a
    /// count-based derivation re-issues live IDs the moment anything is removed.
    ///
    /// RED: change the derivation to `?? 0`, or to `tasks.count` → the nextTaskID assertion fails.
    func testTasksIndex_legacyIndexWithoutCounter_derivesAboveTheHighestExistingID() throws {
        let json = #"{"tasks":[{"id":7,"title":"seven"},{"id":3,"title":"three"}]}"#
        let index = try JSONDecoder().decode(TasksIndex.self, from: Data(json.utf8))

        XCTAssertEqual(index.tasks.count, 2)
        XCTAssertEqual(index.nextTaskID, 8,
                       "max + 1, not count — a deleted middle task must not lower the counter")
    }

    /// Anti-vacuum counterpart: without it, a decoder that ignored `nextTaskID` entirely and always
    /// derived would pass both tests above.
    ///
    /// RED: drop the `decodeIfPresent` and always derive → this fails with 8.
    func testTasksIndex_storedCounterBeatsTheDerivedOne() throws {
        let json = #"{"tasks":[{"id":7,"title":"seven"}],"nextTaskID":100}"#
        let index = try JSONDecoder().decode(TasksIndex.self, from: Data(json.utf8))

        XCTAssertEqual(index.nextTaskID, 100)
    }

    /// `TaskSummary` is the sidebar's whole data source — it exists so the sidebar never loads a
    /// task blob — so its absent-status default decides what a legacy row RENDERS as.
    ///
    /// The assertion that matters is the cross-file one: `NTMSTask.status` and `TaskSummary.status`
    /// are the same concept persisted in two files (`toSummary()` mirrors one into the other), and
    /// their absent-key defaults must not drift. If they did, one legacy pair would show "Working"
    /// on the board and something else in the sidebar for the same task.
    ///
    /// RED: change either `?? .running` (NTMSTask.swift:215 or :492) → the agreement assertion
    /// fails naming both.
    func testTaskSummary_legacyRowWithoutStatus_agreesWithTheTaskBlobDefault() throws {
        let summary = try JSONDecoder().decode(
            TaskSummary.self, from: Data(#"{"id":1,"title":"row"}"#.utf8)
        )
        let task = try JSONDecoder().decode(
            NTMSTask.self, from: Data(#"{"id":1,"title":"row"}"#.utf8)
        )

        XCTAssertEqual(summary.status, .running)
        XCTAssertEqual(summary.status, task.status,
                       "index row and task blob must default to the same status or the sidebar "
                       + "and the board disagree about one task")
        XCTAssertFalse(summary.isChatMode)
        XCTAssertNil(summary.parentTaskID, "absent parent means top-level, so the row is listed")
        XCTAssertNil(summary.nextRecurrenceFireAt, "no schedule means no recurring badge")
        XCTAssertNil(summary.pinnedTeamID)
    }

    /// `TaskSummary.updatedAt` defaults to a fresh `MonotonicClock` stamp, not the epoch. The
    /// sidebar and `evictIfReclaimable` order by it, so `Date(timeIntervalSince1970: 0)` would sink
    /// every legacy row to the bottom of the list permanently.
    ///
    /// Bracketed with `MonotonicClock.shared.now()` on both sides, never `Date()` — the clock is
    /// `max(Date(), last + 1ms)` and drifts ahead of wall time under load, which is the documented
    /// flake in CLAUDE.md's 2026-07-18 entry. Strict monotonicity makes `before < stamp < after`
    /// deterministic.
    ///
    /// RED: change the default to `Date(timeIntervalSince1970: 0)` → the lower-bound assertion
    /// fails.
    func testTaskSummary_legacyRowWithoutTimestamp_isStampedNow() throws {
        let before = MonotonicClock.shared.now()
        let summary = try JSONDecoder().decode(
            TaskSummary.self, from: Data(#"{"id":1,"title":"row"}"#.utf8)
        )
        let after = MonotonicClock.shared.now()

        XCTAssertGreaterThan(summary.updatedAt, before)
        XCTAssertLessThan(summary.updatedAt, after)
    }

    // MARK: - RoleDependencies (teams.json)

    /// `RoleDependencies` from an empty object. Both defaults are load-bearing for the ENGINE, not
    /// for display: an empty `requiredArtifacts` means the role has no gate and
    /// `ArtifactDependencyResolver` reports it ready immediately, and an empty `producesArtifacts`
    /// is what flips `TeamRoleDefinition.completionType` off `.producing` — so the role stops being
    /// something the run can wait on.
    ///
    /// Throwing instead of defaulting would be worse than either: `RoleDependencies` is nested
    /// inside every role of every team, so one absent key would fail the whole `teams.json`, and
    /// `loadOrRecoverFiles` treats that as corruption and re-bootstraps all three files.
    ///
    /// RED: change either `?? []` in `RoleDependencies.init(from:)` → the matching isEmpty fails.
    func testRoleDependencies_emptyObject_takesBothDefaults() throws {
        let deps = try JSONDecoder().decode(RoleDependencies.self, from: Data("{}".utf8))

        XCTAssertTrue(deps.requiredArtifacts.isEmpty, "no gate — the role is ready at once")
        XCTAssertTrue(deps.producesArtifacts.isEmpty, "no output — the role is not `.producing`")
    }

    /// Anti-vacuum counterpart: proves the decoder reads its input rather than always defaulting.
    ///
    /// RED: replace both `decodeIfPresent` calls with `[]` → both assertions fail.
    func testRoleDependencies_presentArraysBeatTheDefaults() throws {
        let json = #"{"requiredArtifacts":["Supervisor Task"],"producesArtifacts":["Release Notes"]}"#
        let deps = try JSONDecoder().decode(RoleDependencies.self, from: Data(json.utf8))

        XCTAssertEqual(deps.requiredArtifacts, ["Supervisor Task"])
        XCTAssertEqual(deps.producesArtifacts, ["Release Notes"])
    }

    // MARK: - TeamsFile (teams.json)

    /// `TeamsFile` from an empty object. `teams` defaulting to `[]` rather than throwing is what
    /// lets `bootstrapIfNeeded` merge the bundled templates into a file it can still read — a throw
    /// here routes through `loadOrRecoverFiles`, which wipes workfolder.json, settings.json AND
    /// teams.json together because the three are one consistency unit.
    ///
    /// RED: change `schemaVersion`'s `?? 1` to `?? 0` → the schemaVersion assertion fails.
    func testTeamsFile_emptyObject_takesEveryDefault() throws {
        let file = try JSONDecoder().decode(TeamsFile.self, from: Data("{}".utf8))

        XCTAssertEqual(file.schemaVersion, 1)
        XCTAssertTrue(file.teams.isEmpty,
                      "a readable file with no teams is bootstrap's input, not a decode failure")
    }

    // MARK: - TaskRecurrence (task.json)

    /// A recurrence written before `isEnabled` existed reads as ENABLED.
    ///
    /// The presence of a `recurrence` object at all is the Supervisor's recorded intent to
    /// schedule, so `false` would silently stop a schedule the user set up — and silently is the
    /// operative word: a disabled recurrence is dropped from both the scheduler scan and the
    /// sidebar badge, which is exactly the dead-but-claiming-to-be-on state `reschedule(after:)`
    /// goes out of its way to avoid representing.
    ///
    /// The `isDue` assertion names that consequence rather than restating the flag.
    ///
    /// RED: change `?? true` to `?? false` in `TaskRecurrence.init(from:)` → both the isEnabled and
    /// the isDue assertions fail.
    func testTaskRecurrence_legacyScheduleWithoutEnabledFlag_readsAsEnabled() throws {
        let due = Date(timeIntervalSince1970: 1_000_000)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let original = TaskRecurrence(
            rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: due
        )

        let data = try legacyJSON(original, removing: ["isEnabled"])
        let decoded = try JSONDecoder().decode(TaskRecurrence.self, from: data)

        XCTAssertTrue(decoded.isEnabled,
                      "a stored schedule with no flag is the user's intent to schedule")
        XCTAssertEqual(decoded.rule, .interval(seconds: 3600), "the rule itself is required, not defaulted")
        XCTAssertEqual(decoded.nextFireAt, due)
        XCTAssertNil(decoded.lastFiredAt)
        XCTAssertTrue(decoded.isDue(now: now),
                      "the consequence: a past fire time on a legacy schedule still fires")
    }

    // MARK: - TeamMessage (run.meetings)

    /// A meeting turn persisted before `messageType` existed reads as `.discussion`.
    ///
    /// `.discussion` is the neutral case — the one `TeamMessageType.determine(from:)` itself falls
    /// through to when no marker matches — so an untyped legacy turn renders as a plain turn in the
    /// activity feed. Any other default would put a classification tag ("proposal", "conclusion")
    /// on content that was never classified.
    ///
    /// RED: change `?? .discussion` to any other case in `TeamMessage.init(from:)` → the
    /// messageType assertion fails.
    func testTeamMessage_legacyMeetingTurnWithoutType_readsAsDiscussion() throws {
        let original = TeamMessage(
            role: .techLead, content: "Legacy turn", messageType: .proposal
        )

        let data = try legacyJSON(original, removing: ["messageType"])
        let decoded = try JSONDecoder().decode(TeamMessage.self, from: data)

        XCTAssertEqual(decoded.messageType, .discussion,
                       "unclassified, not mis-classified")
        XCTAssertEqual(decoded.role, .techLead, "the rest of the turn survives the missing key")
        XCTAssertEqual(decoded.content, "Legacy turn")
        XCTAssertEqual(decoded.id, original.id)
    }

    // MARK: - TeamArtifact (teams.json)

    /// An artifact definition with no timestamps is stamped NOW, not at the epoch.
    ///
    /// `TeamArtifactTests.testCodableWithDefaults` supplies `createdAt`/`updatedAt` and so covers
    /// every other default in this initializer but not these two.
    ///
    /// The two `MonotonicClock.shared.now()` calls are independent, which the strict inequality
    /// between them pins: `createdAt < updatedAt` holds because the clock never returns the same
    /// instant twice. Bracketing uses the same clock production stamps with — comparing a monotonic
    /// stamp against a `Date()` bound is the documented flake (CLAUDE.md, 2026-07-18).
    ///
    /// RED: change either `?? MonotonicClock.shared.now()` to `?? Date(timeIntervalSince1970: 0)`
    /// → that field's lower-bound assertion fails.
    func testTeamArtifact_legacyArtifactWithoutTimestamps_isStampedNow() throws {
        let json = #"{"id":"release_notes","name":"Release Notes"}"#

        let before = MonotonicClock.shared.now()
        let artifact = try JSONDecoder().decode(TeamArtifact.self, from: Data(json.utf8))
        let after = MonotonicClock.shared.now()

        XCTAssertGreaterThan(artifact.createdAt, before)
        XCTAssertLessThan(artifact.createdAt, artifact.updatedAt,
                          "two independent monotonic stamps, in declaration order")
        XCTAssertLessThan(artifact.updatedAt, after)
    }

    // MARK: - LLMMessage (step.llmConversation)

    /// `role` is decoded as a raw String and mapped through `LLMRole(rawValue:) ?? .user` — an
    /// unknown raw degrades instead of throwing.
    ///
    /// The stakes are the reason: `LLMMessage` is nested inside `StepExecution` inside `Run` inside
    /// `NTMSTask`, so a throw here fails the WHOLE task blob to decode. One unrecognised role
    /// string — a case added by a newer build, read after a downgrade, or a truncated write — would
    /// take the entire conversation, every artifact and every run with it. This is the same
    /// tolerance the `sourceContext` decode three lines below documents explicitly.
    ///
    /// `.user` specifically, rather than `.assistant`: content of unknown provenance attributed to
    /// the assistant would read back to the model as its own prior commitment.
    ///
    /// RED: change `?? .user` to `?? .assistant` → the role assertion fails.
    func testLLMMessage_unknownRoleRaw_degradesToUserAndKeepsTheMessage() throws {
        let json = """
        {"id":"550e8400-e29b-41d4-a716-446655440000","role":"moderator","content":"kept"}
        """
        let message = try JSONDecoder().decode(LLMMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "kept",
                       "the point of degrading: the turn survives, the task still loads")
    }

    /// Anti-vacuum counterpart: a decoder that ignored the raw and always produced `.user` would
    /// pass the test above. Every known raw must still map to itself.
    ///
    /// RED: drop the `LLMRole(rawValue:)` lookup and always use `.user` → three of four fail.
    func testLLMMessage_knownRoleRaws_mapToThemselves() throws {
        let expected: [(String, LLMRole)] = [
            ("system", .system), ("user", .user), ("assistant", .assistant), ("tool", .tool),
        ]
        for (raw, role) in expected {
            let json = """
            {"id":"550e8400-e29b-41d4-a716-446655440000","role":"\(raw)","content":"c"}
            """
            let message = try JSONDecoder().decode(LLMMessage.self, from: Data(json.utf8))
            XCTAssertEqual(message.role, role, "raw '\(raw)' must not degrade")
        }
    }

    // MARK: - VocabVectorIndex.Meta (vocab_vectors.meta.json)

    /// A vector meta written before `failedTokens` existed reads as no known failures.
    ///
    /// `[]` is the only value that keeps such a meta VALID: the throwing init requires
    /// `failedTokens` to be disjoint from `tokenMap.keys`, and a corrupt meta is treated by
    /// `load()` as missing — i.e. a wrong default here silently discards the whole vector index and
    /// forces a full re-embed of every token.
    ///
    /// Semantically it is also the right answer: the next `rebuildIfNeeded` sees an absent token as
    /// `addedTokens` and retries it, whereas a token parked in `failedTokens` is skipped.
    ///
    /// Decoded with `JSONCoderFactory.makeDateDecoder()` — the decoder
    /// `VocabVectorIndexService.load()` actually uses — so the fixture's ISO-8601 dates are the
    /// on-disk ones rather than a test-only encoding.
    ///
    /// RED: change `?? []` to a non-empty default → the isEmpty assertion fails (or the init throws
    /// `failedTokenAlsoInMap` if it overlaps `tokenMap`).
    func testVocabVectorIndexMeta_legacyMetaWithoutFailedTokens_readsAsNoFailures() throws {
        let json = """
        {"version":1,"generatedAt":"2026-01-02T21:04:05.123Z","modelName":"nomic-embed",
         "dims":4,
         "indexSignature":{"fileCount":2,"maxMTime":"2026-01-02T21:04:05.123Z","totalSize":99},
         "tokenMap":{"alpha":0,"beta":1}}
        """
        let meta = try JSONCoderFactory.makeDateDecoder()
            .decode(VocabVectorIndex.Meta.self, from: Data(json.utf8))

        XCTAssertTrue(meta.failedTokens.isEmpty,
                      "absent means 'nothing known to have failed', so the next build retries")
        XCTAssertEqual(meta.tokenMap.count, 2,
                       "the validating init ran and accepted the bijection onto 0..<count")
        XCTAssertEqual(meta.dims, 4)
    }
}
