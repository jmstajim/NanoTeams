import Carbon
import XCTest
@testable import NanoTeams

// MARK: - Registration outcome

/// `GlobalHotkeyManager` is a `private init` singleton whose every path calls Carbon, and calling
/// `unregisterAll()` on `.shared` would tear down hotkeys any sibling test in the same worker had
/// registered — so the manager itself stays untouched here (the same reasoning
/// `ScreenInputHotkeyRegistrationTests` records). What IS decidable is the outcome enum the
/// manager now routes its Carbon status through.
final class HotkeyRegistrationOutcomeTests: XCTestCase {

    func testNoErrWithARef_isTheOnlyRegisteredOutcome() {
        XCTAssertEqual(
            HotkeyRegistrationOutcome.evaluate(carbonStatus: noErr, gotRef: true), .registered)
        XCTAssertTrue(HotkeyRegistrationOutcome.evaluate(carbonStatus: noErr, gotRef: true).didRegister)
    }

    /// A refusal is what happens when another process already owns the combo — Alfred, Raycast,
    /// Keyboard Maestro and the system itself all claim triple-modifier combos.
    func testNonZeroStatus_isRefusedAndCarriesTheStatusForDiagnosis() {
        let outcome = HotkeyRegistrationOutcome.evaluate(carbonStatus: OSStatus(eventHotKeyExistsErr), gotRef: true)
        XCTAssertEqual(outcome, .refusedByCarbon(OSStatus(eventHotKeyExistsErr)))
        XCTAssertFalse(outcome.didRegister)
    }

    /// The subtle half: a `noErr` status that produced NO ref is still a failure. Treating it as
    /// success would leave the manager claiming an id it holds no ref for — an id `unregister`
    /// could then never release, and which blocks any later re-registration of that shortcut.
    func testNoErrWithoutARef_isStillAFailure() {
        let outcome = HotkeyRegistrationOutcome.evaluate(carbonStatus: noErr, gotRef: false)
        XCTAssertFalse(outcome.didRegister)
        XCTAssertEqual(outcome, .refusedByCarbon(noErr))
    }

    /// **Regression.** `InstallEventHandler`'s `OSStatus` was discarded, so a failed install left
    /// `register` going on to call `RegisterEventHotKey` and return `true`: the combo was claimed
    /// process-wide — denying it to whatever app the user actually wants it in — for a hotkey
    /// that could never fire, and the caller was told it worked. This is now its own outcome, and
    /// the manager bails on it BEFORE touching Carbon's registration.
    func testEventHandlerUnavailable_neverCountsAsRegistered() {
        XCTAssertFalse(HotkeyRegistrationOutcome.eventHandlerUnavailable.didRegister)
    }

    /// The two failures must stay distinguishable — they call for different remedies (rebind the
    /// shortcut vs. an app-level fault), and collapsing them would make the second unreportable.
    func testTheTwoFailures_areDistinctValues() {
        XCTAssertNotEqual(
            HotkeyRegistrationOutcome.eventHandlerUnavailable,
            HotkeyRegistrationOutcome.refusedByCarbon(noErr))
    }

    /// Different Carbon statuses stay distinguishable from one another too.
    func testRefusalsCarryingDifferentStatuses_areNotEqual() {
        XCTAssertNotEqual(
            HotkeyRegistrationOutcome.refusedByCarbon(noErr),
            HotkeyRegistrationOutcome.refusedByCarbon(-9878))
    }
}

// MARK: - Registry bookkeeping

/// The id → (ref, handler) bookkeeping behind every `register` / `unregister` / `unregisterAll`
/// call, exercised over a fake `Ref` token because `EventHotKeyRef` is an opaque pointer no test
/// can fabricate.
final class HotkeyRegistryTests: XCTestCase {

    private typealias Registry = HotkeyRegistry<Int>

    private let openID: UInt32 = 1
    private let clipID: UInt32 = 2

    // MARK: Empty state

    func testFreshRegistry_ownsNothing() {
        let registry = Registry()
        XCTAssertTrue(registry.isEmpty)
        XCTAssertFalse(registry.claims(openID))
        XCTAssertTrue(registry.registeredIDs.isEmpty)
        XCTAssertNil(registry.handler(for: openID))
    }

    // MARK: Stage → commit (the success path)

    /// A handler must be stored BEFORE the Carbon call, because the callback can fire the moment
    /// registration succeeds. So a staged id already `claims` the slot — but it is not yet
    /// `registered`, because no ref exists to release.
    func testStagedButUncommitted_claimsTheIDWithoutBeingRegistered() {
        var registry = Registry()
        registry.stageHandler(id: openID) {}
        XCTAssertTrue(registry.claims(openID))
        XCTAssertFalse(registry.isEmpty)
        XCTAssertTrue(registry.registeredIDs.isEmpty, "no Carbon ref yet")
    }

    func testCommit_marksTheIDRegistered() {
        var registry = Registry()
        registry.stageHandler(id: openID) {}
        registry.commit(id: openID, ref: 7)
        XCTAssertEqual(registry.registeredIDs, [openID])
        XCTAssertTrue(registry.claims(openID))
    }

    func testCommittedHandler_isTheOneThatWasStaged_andIsInvocable() {
        var registry = Registry()
        var fired = 0
        registry.stageHandler(id: openID) { fired += 1 }
        registry.commit(id: openID, ref: 7)
        registry.handler(for: openID)?()
        XCTAssertEqual(fired, 1)
    }

    /// The dispatch side of `handleHotKey`: a press on an id nobody registered must be a silent
    /// no-op, not a crash.
    func testHandlerLookupForAnUnknownID_isNil() {
        var registry = Registry()
        registry.stageHandler(id: openID) {}
        registry.commit(id: openID, ref: 7)
        XCTAssertNil(registry.handler(for: clipID))
    }

    /// Re-staging replaces the handler rather than accumulating — `register` on an existing id
    /// must end with exactly one closure bound to it.
    func testRestagingAnID_replacesItsHandler() {
        var registry = Registry()
        var first = 0
        var second = 0
        registry.stageHandler(id: openID) { first += 1 }
        registry.stageHandler(id: openID) { second += 1 }
        registry.handler(for: openID)?()
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    // MARK: Rollback (the failure path — the regression this shape exists for)

    /// **Regression.** A failed registration used to leave the staged handler behind. That made
    /// the manager claim an id it does not own, so the NEXT `register(id:)` took the
    /// "already registered" branch and called `unregister` on a ref that was never there — and a
    /// stale closure stayed reachable from `handleHotKey` for a combo the user never got.
    func testRollbackAfterAFailedRegistration_leavesTheIDUnclaimed() {
        var registry = Registry()
        registry.stageHandler(id: openID) {}
        registry.rollback(id: openID)
        XCTAssertFalse(registry.claims(openID), "a refused registration must not claim the id")
        XCTAssertTrue(registry.isEmpty)
        XCTAssertNil(registry.handler(for: openID))
    }

    /// …and the rolled-back id is genuinely re-registerable afterwards, which is the whole point.
    func testAnIDCanBeRegisteredAfterAFailedAttempt() {
        var registry = Registry()
        registry.stageHandler(id: openID) {}
        registry.rollback(id: openID)

        var fired = 0
        registry.stageHandler(id: openID) { fired += 1 }
        registry.commit(id: openID, ref: 7)
        registry.handler(for: openID)?()
        XCTAssertEqual(registry.registeredIDs, [openID])
        XCTAssertEqual(fired, 1)
    }

    /// A rollback is scoped to its own id: one shortcut failing to register must not disarm the
    /// other one. (Both of the app's hotkeys register through the same manager.)
    func testRollback_doesNotDisturbAnotherRegisteredID() {
        var registry = Registry()
        registry.stageHandler(id: clipID) {}
        registry.commit(id: clipID, ref: 9)
        registry.stageHandler(id: openID) {}
        registry.rollback(id: openID)

        XCTAssertEqual(registry.registeredIDs, [clipID])
        XCTAssertTrue(registry.claims(clipID))
        XCTAssertFalse(registry.claims(openID))
    }

    /// Rolling back an id that was never staged is a no-op, not a corruption of a committed one.
    func testRollbackOfAnUnknownID_isANoOp() {
        var registry = Registry()
        registry.stageHandler(id: clipID) {}
        registry.commit(id: clipID, ref: 9)
        registry.rollback(id: openID)
        XCTAssertEqual(registry.registeredIDs, [clipID])
    }

    // MARK: remove (unregister)

    func testRemove_handsBackTheRefToRelease_andForgetsEverything() {
        var registry = Registry()
        registry.stageHandler(id: openID) {}
        registry.commit(id: openID, ref: 7)

        XCTAssertEqual(registry.remove(id: openID), 7)
        XCTAssertTrue(registry.isEmpty)
        XCTAssertNil(registry.handler(for: openID))
        XCTAssertFalse(registry.claims(openID))
    }

    /// Removing a STAGED-but-uncommitted id returns no ref (there is none to release) yet still
    /// drops the handler — leaving it would recreate the exact state `rollback` exists to prevent.
    func testRemoveOfAStagedOnlyID_returnsNoRefButStillDropsTheHandler() {
        var registry = Registry()
        registry.stageHandler(id: openID) {}
        XCTAssertNil(registry.remove(id: openID))
        XCTAssertFalse(registry.claims(openID))
        XCTAssertTrue(registry.isEmpty)
    }

    func testRemoveOfAnUnknownID_returnsNil_andLeavesTheRestAlone() {
        var registry = Registry()
        registry.stageHandler(id: clipID) {}
        registry.commit(id: clipID, ref: 9)
        XCTAssertNil(registry.remove(id: openID))
        XCTAssertEqual(registry.registeredIDs, [clipID])
    }

    func testRemove_isScopedToOneID() {
        var registry = Registry()
        registry.stageHandler(id: openID) {}
        registry.commit(id: openID, ref: 7)
        registry.stageHandler(id: clipID) {}
        registry.commit(id: clipID, ref: 9)

        XCTAssertEqual(registry.remove(id: openID), 7)
        XCTAssertEqual(registry.registeredIDs, [clipID])
        XCTAssertNotNil(registry.handler(for: clipID))
    }

    // MARK: removeAll (unregisterAll)

    /// Every ref must come back — one left behind is a hotkey Carbon still routes to a dead
    /// handler after the app has torn its own bookkeeping down.
    func testRemoveAll_handsBackEveryRef_andEmptiesTheRegistry() {
        var registry = Registry()
        registry.stageHandler(id: openID) {}
        registry.commit(id: openID, ref: 7)
        registry.stageHandler(id: clipID) {}
        registry.commit(id: clipID, ref: 9)

        XCTAssertEqual(Set(registry.removeAll()), [7, 9])
        XCTAssertTrue(registry.isEmpty)
        XCTAssertTrue(registry.registeredIDs.isEmpty)
        XCTAssertNil(registry.handler(for: openID))
        XCTAssertNil(registry.handler(for: clipID))
    }

    func testRemoveAll_onAnEmptyRegistry_returnsNothing() {
        var registry = Registry()
        XCTAssertTrue(registry.removeAll().isEmpty)
        XCTAssertTrue(registry.isEmpty)
    }

    /// A staged-but-uncommitted handler has no ref to hand back, but must still be dropped.
    func testRemoveAll_dropsStagedHandlersThatNeverCommitted() {
        var registry = Registry()
        registry.stageHandler(id: openID) {}
        registry.stageHandler(id: clipID) {}
        registry.commit(id: clipID, ref: 9)

        XCTAssertEqual(registry.removeAll(), [9])
        XCTAssertTrue(registry.isEmpty)
        XCTAssertNil(registry.handler(for: openID))
    }

    func testRemoveAll_isIdempotent() {
        var registry = Registry()
        registry.stageHandler(id: openID) {}
        registry.commit(id: openID, ref: 7)
        _ = registry.removeAll()
        XCTAssertTrue(registry.removeAll().isEmpty)
        XCTAssertTrue(registry.isEmpty)
    }

    // MARK: The full register-over-an-existing-id sequence

    /// What `register` does when the id is already taken: tear the old one down, then stage and
    /// commit the new one. The old ref must surface exactly once (so Carbon releases it exactly
    /// once) and the new handler must be the one left bound.
    func testReRegisteringAnExistingID_releasesTheOldRefAndBindsTheNewHandler() {
        var registry = Registry()
        var old = 0
        var new = 0
        registry.stageHandler(id: openID) { old += 1 }
        registry.commit(id: openID, ref: 7)

        XCTAssertTrue(registry.claims(openID))
        XCTAssertEqual(registry.remove(id: openID), 7, "the old ref is released exactly once")
        registry.stageHandler(id: openID) { new += 1 }
        registry.commit(id: openID, ref: 8)

        registry.handler(for: openID)?()
        XCTAssertEqual(old, 0)
        XCTAssertEqual(new, 1)
        XCTAssertEqual(registry.registeredIDs, [openID])
    }

    /// The app registers two shortcuts under two distinct ids. They must stay fully independent —
    /// a shared or colliding id would silently disarm one of them.
    func testTwoIndependentIDs_keepSeparateRefsAndHandlers() {
        var registry = Registry()
        var openFired = 0
        var clipFired = 0
        registry.stageHandler(id: openID) { openFired += 1 }
        registry.commit(id: openID, ref: 7)
        registry.stageHandler(id: clipID) { clipFired += 1 }
        registry.commit(id: clipID, ref: 9)

        registry.handler(for: clipID)?()
        XCTAssertEqual(openFired, 0)
        XCTAssertEqual(clipFired, 1)
        XCTAssertEqual(registry.registeredIDs, [openID, clipID])
    }

    /// Handlers are RETAINED by the registry for the life of the registration — that retention is
    /// what makes the `willTerminate` teardown meaningful, and what makes a leaked handler after a
    /// failed registration a real leak rather than a bookkeeping nit.
    func testRegistry_retainsItsHandlers_andReleasesThemOnRemoveAll() {
        final class Token {}
        weak var weakToken: Token?
        var registry = Registry()

        autoreleasepool {
            let token = Token()
            weakToken = token
            registry.stageHandler(id: openID) { _ = token }
            registry.commit(id: openID, ref: 7)
        }
        XCTAssertNotNil(weakToken, "the registry retains the handler while registered")

        _ = registry.removeAll()
        XCTAssertNil(weakToken, "and releases it on teardown")
    }
}
