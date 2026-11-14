import XCTest
@testable import NanoTeams

/// `Run.pauseCause` is the durable answer to "why did this run's latest pause happen", written
/// by whoever paused it. Three readers ask whether the pause a run stands in is the one its
/// timeout caused — the Autovisor event feed's `paused(reason)`, the delegation awaiter's
/// `.paused(.runTimedOut)` fast path and Watchtower's "timed out" notification — and until
/// 2026-11-07 each answered `timedOutAt != nil`, which stays true after the person resumes the
/// run and pauses it again.
final class RunPauseCauseTests: XCTestCase {

    private func decodeRun(_ json: String) throws -> Run {
        try JSONCoderFactory.makeDateDecoder().decode(Run.self, from: Data(json.utf8))
    }

    private func encodedKeys(of run: Run) throws -> [String: Any] {
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(run)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Codable

    func testARunWrittenBeforeTheFieldExisted_decodesWithNoCause() throws {
        let run = try decodeRun(#"{"id":0}"#)
        XCTAssertNil(run.pauseCause)
    }

    func testEveryCause_roundTrips() throws {
        for cause in Run.PauseCause.allCases {
            var run = Run(id: 0)
            run.pauseCause = cause
            let data = try JSONCoderFactory.makePersistenceEncoder().encode(run)
            let decoded = try JSONCoderFactory.makeDateDecoder().decode(Run.self, from: data)
            XCTAssertEqual(decoded.pauseCause, cause)
        }
    }

    /// A cause a later build adds must not make an older build drop the whole task.
    func testAnUnknownCause_decodesAsNoCause_andTheRunStillDecodes() throws {
        let run = try decodeRun(#"{"id":3,"pauseCause":"pausedByAFutureBuild"}"#)
        XCTAssertEqual(run.id, 3)
        XCTAssertNil(run.pauseCause)
    }

    func testARunThatWasNeverPaused_writesNoKey() throws {
        XCTAssertNil(try encodedKeys(of: Run(id: 0))["pauseCause"], "no key for an unset cause: old bytes stay as they were")
        var paused = Run(id: 0)
        paused.pauseCause = .runTimedOut
        XCTAssertEqual(try encodedKeys(of: paused)["pauseCause"] as? String, "runTimedOut")
    }

    // MARK: - latestPauseIsItsTimeout

    func testLatestPauseIsItsTimeout_followsTheRecordedCause() {
        var run = Run(id: 0)
        XCTAssertFalse(run.latestPauseIsItsTimeout, "a run that never timed out")

        run.pauseCause = .runTimedOut
        XCTAssertFalse(run.latestPauseIsItsTimeout, "a cause with no timeout stamp is not a timeout")

        run.timedOutAt = Date(timeIntervalSince1970: 1_799_971_200)
        XCTAssertTrue(run.latestPauseIsItsTimeout)

        for cause in Run.PauseCause.allCases where cause != .runTimedOut {
            run.pauseCause = cause
            XCTAssertFalse(run.latestPauseIsItsTimeout, "the run was paused again, by \(cause), after its timeout")
        }
    }

    /// A run persisted before `pauseCause` existed carries only the timeout stamp; it keeps the
    /// reading it always had.
    func testARunWithATimeoutStampAndNoCause_readsAsPausedByItsTimeout() {
        var run = Run(id: 0)
        run.timedOutAt = Date(timeIntervalSince1970: 1_799_971_200)
        XCTAssertNil(run.pauseCause)
        XCTAssertTrue(run.latestPauseIsItsTimeout)
    }

    // MARK: - Wave Final Coverage Hardening (M6.1)

    func testRunInit_nilRoundStartedAt_defaultsToCreatedAt() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let run = Run(id: 99, createdAt: now, round: 1, roundStartedAt: nil)
        XCTAssertEqual(run.roundStartedAt, now)
    }

    func testChangeRequestStatus_displayName_coversAllCases() {
        let cases: [ChangeRequestStatus] = [
            .pending, .approved, .rejected, .escalated,
            .supervisorApproved, .supervisorRejected, .failed
        ]
        for status in cases {
            XCTAssertFalse(status.displayName.isEmpty)
        }
    }

    func testRunInit_defaultArguments_initializesExpectedDefaults() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let run = Run(
            id: 101,
            createdAt: now,
            updatedAt: now,
            steps: [],
            meetings: [],
            changeRequests: [],
            consultationChats: [:],
            roleStatuses: [:],
            teamID: "team1",
            timedOutAt: nil,
            round: 1
        )
        XCTAssertEqual(run.round, 1)
        XCTAssertEqual(run.roundStartedAt, now)
        XCTAssertTrue(run.supervisorEvents.isEmpty)
        XCTAssertTrue(run.snapshotFailures.isEmpty)
    }

    func testNTMSTask_decodingLegacyStringArrayClips_mintsClips() throws {
        let json = """
        {
            "id": 42,
            "title": "Legacy clips task",
            "clippedTexts": ["first snippet", "second snippet"]
        }
        """
        let task = try JSONCoderFactory.makeDateDecoder().decode(NTMSTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.clippedTexts.count, 2)
        XCTAssertEqual(task.clippedTexts[0].text, "first snippet")
        XCTAssertEqual(task.clippedTexts[1].text, "second snippet")
    }

    func testRoleExecutionStatus_metadataAccessors_coverAllCases() {
        for status in RoleExecutionStatus.allCases {
            XCTAssertFalse(status.displayName.isEmpty)
            XCTAssertFalse(status.icon.isEmpty)
            _ = status.isActive
            _ = status.isComplete
            _ = status.requiresSupervisorAttention
            _ = status.canStart
            _ = status.canRestart
        }
    }

    func testBashPolicy_displayNamesAndDescriptions_coverAllCases() {
        for mode in BashExecutionMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.settingDescription.isEmpty)
        }
        for level in BashRestrictionLevel.allCases {
            XCTAssertFalse(level.displayName.isEmpty)
            XCTAssertFalse(level.settingDescription.isEmpty)
            XCTAssertFalse(level.judgeGuidance.isEmpty)
        }
    }

    func testComputerUsePolicy_displayNamesAndDescriptions_coverAllCases() {
        for mode in ComputerUseMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.settingDescription.isEmpty)
        }
        for level in ComputerUseRestrictionLevel.allCases {
            XCTAssertFalse(level.displayName.isEmpty)
            XCTAssertFalse(level.settingDescription.isEmpty)
            XCTAssertFalse(level.judgeGuidance.isEmpty)
        }
    }

    func testTeamSettings_acceptanceAndSupervisorModes_displayNamesAndDescriptions() {
        for mode in AcceptanceMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.description.isEmpty)
        }
        for mode in SupervisorMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.description.isEmpty)
        }
    }

    func testTaskStatus_displayLabelAndExternalName_coverAllCases() {
        for status in TaskStatus.allCases {
            XCTAssertFalse(status.displayLabel.isEmpty)
            XCTAssertFalse(status.externalName.isEmpty)
        }
    }

    func testRole_builtInID_andDisplayName() {
        XCTAssertEqual(Role.builtInID(.softwareEngineer), "softwareEngineer")
        XCTAssertEqual(Role.softwareEngineer.displayName, "Software Engineer")
    }
}
