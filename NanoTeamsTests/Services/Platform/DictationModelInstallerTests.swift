import XCTest

@testable import NanoTeams

/// Scripted install request. `downloadAndInstall` blocks on a continuation the test
/// releases, so a cancellation can be delivered while the download is genuinely in flight
/// rather than merely before or after it.
private final class ScriptedInstallRequest: DictationInstallRequest, @unchecked Sendable {
    enum Behaviour {
        /// Return normally, immediately.
        case succeedImmediately
        /// Throw `error`, immediately.
        case fail(any Error)
        /// Suspend until `release()` is called, then throw `error`. Models Apple's
        /// installer noticing the cancelled `Progress`.
        case suspendThenFail(any Error)
        /// Suspend until `release()` is called, then return normally. Models the download
        /// finishing despite the cancel signal — the case the post-hoc rollback exists for.
        case suspendThenSucceed
    }

    private let lock = NSLock()
    private var behaviour: Behaviour
    private var continuation: CheckedContinuation<Void, any Error>?
    private var _cancelCount = 0
    private var _downloadCount = 0

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    var cancelCount: Int { lock.withLock { _cancelCount } }
    var downloadCount: Int { lock.withLock { _downloadCount } }

    func downloadAndInstall() async throws {
        lock.withLock { _downloadCount += 1 }
        switch lock.withLock({ behaviour }) {
        case .succeedImmediately:
            return
        case .fail(let error):
            throw error
        case .suspendThenFail(let error):
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
            throw error
        case .suspendThenSucceed:
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        }
    }

    nonisolated func cancelProgress() {
        lock.withLock { _cancelCount += 1 }
    }

    /// Lets the suspended download proceed to its scripted ending.
    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }

    /// True once `downloadAndInstall` has suspended, so a test can cancel at the right
    /// moment instead of racing it.
    var isSuspended: Bool { lock.withLock { continuation != nil } }
}

/// Scripted inventory. Records every `release` so the rollback assertions can distinguish
/// "rolled back once" from "never" and from "twice".
private final class ScriptedAssetInventory: DictationAssetInventory, @unchecked Sendable {
    private let lock = NSLock()
    private var _released: [Locale] = []
    private var _isInstalled: Bool
    private var _request: (any DictationInstallRequest)?
    private var _requestError: (any Error)?

    init(request: (any DictationInstallRequest)? = nil,
         requestError: (any Error)? = nil,
         isInstalled: Bool = false) {
        self._request = request
        self._requestError = requestError
        self._isInstalled = isInstalled
    }

    var released: [Locale] { lock.withLock { _released } }

    nonisolated func installationRequest(
        for locale: Locale
    ) async throws -> (any DictationInstallRequest)? {
        if let error = lock.withLock({ _requestError }) { throw error }
        return lock.withLock { _request }
    }

    nonisolated func isInstalled(locale: Locale) async -> Bool {
        lock.withLock { _isInstalled }
    }

    @discardableResult
    nonisolated func release(reservedLocale: Locale) async -> Bool {
        lock.withLock { _released.append(reservedLocale) }
        return true
    }
}

private struct ProbeError: Error, Equatable { var id = 1 }

/// Covers `DictationModelInstaller` — the install state machine lifted out of
/// `DictationModelCatalog.install`.
///
/// All 34 of its lines were uncovered and unreachable: the real path downloads a
/// multi-gigabyte model, so every branch below could previously be exercised only by hand,
/// on a fast connection, with a stopwatch. Three of them are rollback paths, and the
/// existing suite could only pin the cancellation *pattern* in the abstract — its own
/// comment says "This isn't a direct test of the production function (which would require
/// a live download)".
///
/// Seaming it also moved the logic out from under `@available(macOS 26, *)`: the state
/// machine now carries no Speech types, so it is testable on the machine that measures
/// coverage rather than on one OS version.
final class DictationModelInstallerTests: XCTestCase, @unchecked Sendable {

    private let locale = Locale(identifier: "en-US")

    // MARK: - The undocumented nil

    /// Apple documents a nil installation request as "already installed". This is the
    /// case where that is TRUE.
    ///
    /// RED: throw unconditionally on a nil request → this fails, and re-tapping a
    /// downloaded language reports an error.
    func testNilRequest_whenActuallyInstalled_succeedsQuietly() async throws {
        let inventory = ScriptedAssetInventory(request: nil, isInstalled: true)
        try await DictationModelInstaller.install(locale: locale, inventory: inventory)
        XCTAssertTrue(inventory.released.isEmpty, "nothing to roll back")
    }

    /// …and this is the case where it is FALSE — observed for locales with no model
    /// available in the device's region. Trusting the documentation here reports success
    /// and leaves the user with dictation that silently does nothing.
    ///
    /// RED: drop the `isInstalled` verification and `return` on nil → no error is thrown
    /// and this fails.
    func testNilRequest_whenNotInstalled_throwsNothingInstallable() async {
        let inventory = ScriptedAssetInventory(request: nil, isInstalled: false)
        do {
            try await DictationModelInstaller.install(locale: locale, inventory: inventory)
            XCTFail("a refused request must not report success")
        } catch {
            XCTAssertEqual(error as? DictationModelInstaller.InstallError, .nothingInstallable,
                           "the user needs to know no model exists for this language")
        }
    }

    /// An error building the request (unsupported locale) must propagate as itself.
    /// Reporting it as `CancellationError` would tell the user they cancelled something
    /// they never started.
    ///
    /// RED: wrap the throw in the cancellation path → this fails.
    func testRequestConstructionFailure_propagatesUnchanged() async {
        let probe = ProbeError()
        let inventory = ScriptedAssetInventory(requestError: probe)
        do {
            try await DictationModelInstaller.install(locale: locale, inventory: inventory)
            XCTFail("expected the construction error")
        } catch let error as ProbeError {
            XCTAssertEqual(error, probe)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(inventory.released.isEmpty,
                      "nothing was ever reserved, so nothing may be released")
    }

    // MARK: - The happy path

    /// RED: call `release` on the success path → the no-rollback assertion fails, and
    /// every successful download is immediately uninstalled.
    func testSuccessfulInstall_doesNotRollBack() async throws {
        let request = ScriptedInstallRequest(.succeedImmediately)
        let inventory = ScriptedAssetInventory(request: request)

        try await DictationModelInstaller.install(locale: locale, inventory: inventory)

        XCTAssertEqual(request.downloadCount, 1)
        XCTAssertEqual(request.cancelCount, 0, "nothing cancelled it")
        XCTAssertTrue(inventory.released.isEmpty,
                      "a completed install must survive — releasing here uninstalls the "
                          + "model the user just waited for")
    }

    /// A genuine download failure (no disk space, network drop) must reach the caller as
    /// itself, and must NOT roll back: the locale reservation is Apple's to manage and
    /// releasing it here would uninstall a model an earlier successful install had put
    /// there.
    ///
    /// RED: release before rethrowing → the no-rollback assertion fails.
    func testDownloadFailure_propagatesAndDoesNotRollBack() async {
        let probe = ProbeError(id: 7)
        let request = ScriptedInstallRequest(.fail(probe))
        let inventory = ScriptedAssetInventory(request: request)

        do {
            try await DictationModelInstaller.install(locale: locale, inventory: inventory)
            XCTFail("expected the download error")
        } catch let error as ProbeError {
            XCTAssertEqual(error, probe)
        } catch {
            XCTFail("a real failure must not be reported as \(type(of: error))")
        }
        XCTAssertTrue(inventory.released.isEmpty)
    }

    // MARK: - Cancellation mid-download

    /// The documented race, now driven directly: the task is cancelled while
    /// `downloadAndInstall` is suspended, Apple's installer notices and throws, and the
    /// installer must roll back AND report `CancellationError`.
    ///
    /// RED: remove the `if Task.isCancelled` branch from the `catch` → the installer
    /// rethrows Apple's error, no release happens, and both assertions fail: the model
    /// stays installed while the settings row still offers to download it.
    func testCancelledMidDownload_rollsBackAndReportsCancellation() async throws {
        let request = ScriptedInstallRequest(.suspendThenFail(ProbeError(id: 2)))
        let inventory = ScriptedAssetInventory(request: request)

        let locale = locale
        let task = Task {
            try await DictationModelInstaller.install(locale: locale, inventory: inventory)
        }

        // Wait for the download to actually suspend, so the cancel lands mid-flight.
        let deadline = Date().addingTimeInterval(3)
        while !request.isSuspended, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(request.isSuspended, "the download never suspended")

        task.cancel()
        request.release()

        do {
            try await task.value
            XCTFail("a cancelled install must throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertEqual(request.cancelCount, 1,
                       "onCancel must signal the underlying Progress")
        XCTAssertEqual(inventory.released, [locale],
                       "the reservation must be dropped exactly once — Progress.cancel() "
                           + "is a request, not a guarantee")
    }

    /// The narrow race the post-hoc check exists for: the download FINISHES despite the
    /// cancel signal. Easiest branch to omit, because the install succeeded.
    ///
    /// RED: delete the trailing `if Task.isCancelled` block → install returns normally,
    /// the model stays on disk, and the UI shows the locale as still downloadable. Both
    /// assertions fail.
    func testCancelledAfterDownloadFinished_stillRollsBack() async throws {
        let request = ScriptedInstallRequest(.suspendThenSucceed)
        let inventory = ScriptedAssetInventory(request: request)

        let locale = locale
        let task = Task {
            try await DictationModelInstaller.install(locale: locale, inventory: inventory)
        }

        let deadline = Date().addingTimeInterval(3)
        while !request.isSuspended, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(request.isSuspended)

        task.cancel()
        request.release()   // download completes successfully anyway

        do {
            try await task.value
            XCTFail("a cancel that raced a successful download must still be honoured")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertEqual(inventory.released, [locale],
                       "a model installed after the user cancelled must be uninstalled, "
                           + "or the settings row offers to download what is already there")
    }

    /// Anti-vacuity: the rollback must be driven by CANCELLATION, not by suspension. A
    /// suspended-then-succeeded download that nobody cancels must keep its model.
    func testSuspendedThenSucceededWithoutCancel_keepsTheModel() async throws {
        let request = ScriptedInstallRequest(.suspendThenSucceed)
        let inventory = ScriptedAssetInventory(request: request)

        let locale = locale
        let task = Task {
            try await DictationModelInstaller.install(locale: locale, inventory: inventory)
        }
        let deadline = Date().addingTimeInterval(3)
        while !request.isSuspended, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        request.release()

        try await task.value
        XCTAssertTrue(inventory.released.isEmpty, "no cancel, no rollback")
        XCTAssertEqual(request.cancelCount, 0)
    }

    // MARK: - Error copy

    /// The alias must keep resolving, or the settings UI and its existing pins break.
    func testCatalogInstallErrorAliasStillResolves() throws {
        guard #available(macOS 26, iOS 26, visionOS 26, *) else {
            throw XCTSkip("DictationModelCatalog requires macOS 26")
        }
        XCTAssertEqual(DictationModelCatalog.InstallError.nothingInstallable,
                       DictationModelInstaller.InstallError.nothingInstallable)
        XCTAssertEqual(
            DictationModelInstaller.InstallError.nothingInstallable.errorDescription,
            "No dictation model is available for download for this language.")
    }
}
