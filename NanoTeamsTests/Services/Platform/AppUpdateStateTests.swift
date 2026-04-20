import XCTest
@testable import NanoTeams

/// Covers the state-machine aspects of `AppUpdateState`: throttling, skip
/// filtering, version-newer gate. Network transport is exercised via a mock
/// session because `AppUpdateState` composes `AppUpdateChecker`.
@MainActor
final class AppUpdateStateTests: XCTestCase {

    // MARK: - Mocks

    private final class MockNetworkSession: NetworkSession, @unchecked Sendable {
        var responseBody: Data = Data()
        var statusCode: Int = 200
        var callCount: Int = 0

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            callCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (responseBody, response)
        }
        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    /// In-memory `ConfigurationStorage` isolates these tests from `UserDefaults`.
    private final class InMemoryStorage: ConfigurationStorage, @unchecked Sendable {
        private var store: [String: Any] = [:]
        func string(forKey key: String) -> String? { store[key] as? String }
        func bool(forKey key: String) -> Bool { (store[key] as? Bool) ?? false }
        func data(forKey key: String) -> Data? { store[key] as? Data }
        func object(forKey key: String) -> Any? { store[key] }
        func set(_ value: Any?, forKey key: String) {
            if let value { store[key] = value } else { store.removeValue(forKey: key) }
        }
        func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    }

    private var mock: MockNetworkSession!
    private var config: StoreConfiguration!
    private var sut: AppUpdateState!

    override func setUp() {
        super.setUp()
        mock = MockNetworkSession()
        config = StoreConfiguration(storage: InMemoryStorage())
        // Payload with tag much higher than any CFBundleShortVersionString,
        // so `isNewer` is always true in these tests unless explicitly flipped.
        mock.responseBody = #"""
        {"tag_name":"v999.0.0","html_url":"https://example.com/r","body":"ok"}
        """#.data(using: .utf8)!
        sut = AppUpdateState(checker: AppUpdateChecker(session: mock), config: config)
    }

    override func tearDown() {
        sut = nil
        config = nil
        mock = nil
        super.tearDown()
    }

    // MARK: - Throttle

    func testRefresh_recordsTimestamp_andSetsAvailable() async {
        await sut.refresh()
        XCTAssertNotNil(config.lastAppUpdateCheckAt)
        XCTAssertEqual(sut.availableRelease?.tag, "v999.0.0")
        XCTAssertEqual(mock.callCount, 1)
    }

    func testRefresh_withinThrottleWindow_skipsNetwork() async {
        config.lastAppUpdateCheckAt = Date() // "just checked"
        await sut.refresh()
        XCTAssertEqual(mock.callCount, 0, "throttle should prevent a second fetch inside weekly window")
    }

    func testRefresh_force_bypassesThrottle() async {
        config.lastAppUpdateCheckAt = Date()
        await sut.refresh(force: true)
        XCTAssertEqual(mock.callCount, 1, "force=true must bypass throttle")
    }

    // MARK: - Skip

    func testSkip_hidesCurrentAvailableRelease() async {
        await sut.refresh()
        XCTAssertNotNil(sut.availableRelease)

        sut.skip("v999.0.0")

        XCTAssertNil(sut.availableRelease)
        XCTAssertTrue(config.skippedAppUpdateTags.contains("v999.0.0"))
    }

    func testRefresh_afterSkip_keepsCardHiddenForSameTag() async {
        config.skippedAppUpdateTags.insert("v999.0.0")
        await sut.refresh(force: true)
        XCTAssertNil(sut.availableRelease, "skipped tag must not re-show on next refresh")
    }

    func testRefresh_newTagAfterSkip_showsCardAgain() async {
        config.skippedAppUpdateTags.insert("v999.0.0")
        // Server advances to a different, higher tag — user gets a fresh card.
        mock.responseBody = #"""
        {"tag_name":"v999.1.0","html_url":"https://example.com/r","body":""}
        """#.data(using: .utf8)!

        await sut.refresh(force: true)

        XCTAssertEqual(sut.availableRelease?.tag, "v999.1.0")
    }

    // MARK: - Version gate

    func testRefresh_sameVersion_hidesCard() async {
        mock.responseBody = #"""
        {"tag_name":"\#(AppVersion.current)","html_url":"https://example.com/r","body":""}
        """#.data(using: .utf8)!

        await sut.refresh(force: true)

        XCTAssertNil(sut.availableRelease, "current==latest must not produce an update card")
    }

    // MARK: - Failure

    func testRefresh_onHTTPError_swallowsAndKeepsAvailableNil() async {
        mock.statusCode = 500

        await sut.refresh(force: true)

        XCTAssertNil(sut.availableRelease)
        // Timestamp must NOT advance on failure — otherwise the weekly window throttle
        // would lock us out of retries when the server is transiently down.
        XCTAssertNil(config.lastAppUpdateCheckAt)
    }

    func testRefresh_forcedFailure_surfacesLastCheckFailure() async {
        mock.statusCode = 403

        await sut.refresh(force: true)

        XCTAssertNotNil(sut.lastCheckFailure,
                        "forced check must surface a diagnostic for the user")
        XCTAssertTrue(sut.lastCheckFailure?.contains("rate limit") ?? false,
                      "403 should map to the rate-limit copy; got: \(sut.lastCheckFailure ?? "nil")")
    }

    func testRefresh_backgroundFailure_doesNotSurface() async {
        mock.statusCode = 500

        await sut.refresh() // force = false

        XCTAssertNil(sut.lastCheckFailure,
                     "background probe must stay silent — an offline user shouldn't see a banner")
    }

    /// Regression (I12): a prior successful fetch's `availableRelease` must
    /// survive a subsequent 500 — a transient server error must not wipe
    /// the previously-displayed update card.
    func testRefresh_availableRelease_preservedAcrossLaterFailure() async {
        // First refresh succeeds and populates the release.
        await sut.refresh(force: true)
        XCTAssertEqual(sut.availableRelease?.tag, "v999.0.0")
        XCTAssertNotNil(config.cachedAppUpdateRelease)

        // Second refresh errors out — the card must not disappear.
        mock.statusCode = 500
        await sut.refresh(force: true)

        XCTAssertEqual(sut.availableRelease?.tag, "v999.0.0",
                       "a transient failed refresh must not wipe a previously-visible update card")
        XCTAssertEqual(config.cachedAppUpdateRelease?.tag, "v999.0.0",
                       "persisted cache must also survive the failure")
    }

    // MARK: - Cache hydration (relaunch)

    func testRefresh_cachesReleaseOnSuccess() async {
        await sut.refresh()
        XCTAssertEqual(config.cachedAppUpdateRelease?.tag, "v999.0.0",
                       "successful fetch must write the cache so relaunch can hydrate")
    }

    func testInit_hydratesAvailableReleaseFromCache() async {
        // Simulate: first launch found a release → second launch before the
        // weekly window throttle expires. Without hydration, `availableRelease` would
        // stay nil because `refresh()` short-circuits on the throttle.
        config.cachedAppUpdateRelease = AppUpdateChecker.Release(
            tag: "v999.0.0",
            htmlURL: URL(string: "https://example.com/r")!,
            body: "Cached release"
        )

        // `async` here is load-bearing: on Xcode 26.3 / Swift 6, sync methods
        // on a `@MainActor` XCTestCase enter through a path that doesn't
        // re-establish main-actor isolation — constructing a `@MainActor`
        // class in the body aborts. `async` forces a main-actor hop first.
        // See CLAUDE.md "Common API pitfalls when writing tests".
        sut = AppUpdateState(
            checker: AppUpdateChecker(session: mock),
            config: config
        )

        XCTAssertEqual(sut.availableRelease?.tag, "v999.0.0",
                       "init must hydrate from cache so the card survives a relaunch")
    }

    /// Skipped tag must hide the Watchtower view (`availableRelease`) but the
    /// raw payload (`latestRelease`) and persisted cache must remain intact so
    /// the Updates settings tab can still surface it.
    func testInit_skippedTag_hidesAvailableButKeepsLatest() async {
        config.skippedAppUpdateTags.insert("v999.0.0")
        config.cachedAppUpdateRelease = AppUpdateChecker.Release(
            tag: "v999.0.0",
            htmlURL: URL(string: "https://example.com/r")!,
            body: ""
        )

        sut = AppUpdateState(
            checker: AppUpdateChecker(session: mock),
            config: config
        )

        XCTAssertNil(sut.availableRelease,
                     "skipped tag must not surface in Watchtower view")
        XCTAssertEqual(sut.latestRelease?.tag, "v999.0.0",
                       "raw payload must remain available to the Updates tab")
        XCTAssertNotNil(config.cachedAppUpdateRelease,
                        "cache survives so the Updates tab can show the release after a relaunch")
        XCTAssertTrue(sut.isLatestSkipped)
    }

    /// A cached release whose tag equals `AppVersion.current` is hydrated as
    /// `latestRelease` but `hasNewerRelease` correctly reports `false` — no
    /// "Update Now" button shows in the Updates tab.
    func testInit_cachedSameVersion_hasNewerReleaseFalse() async {
        config.cachedAppUpdateRelease = AppUpdateChecker.Release(
            tag: AppVersion.current,
            htmlURL: URL(string: "https://example.com/r")!,
            body: ""
        )

        sut = AppUpdateState(
            checker: AppUpdateChecker(session: mock),
            config: config
        )

        XCTAssertNil(sut.availableRelease,
                     "current==latest must not produce an update banner")
        XCTAssertFalse(sut.hasNewerRelease,
                       "current==latest must not flag as newer")
    }

    /// `skip(_:)` only adds to the skip list — cache and raw payload must
    /// remain so the Updates tab still has a release to render.
    func testSkip_keepsCacheAndLatest_hidesOnlyAvailable() async {
        await sut.refresh()
        XCTAssertNotNil(config.cachedAppUpdateRelease)
        XCTAssertEqual(sut.latestRelease?.tag, "v999.0.0")

        sut.skip("v999.0.0")

        XCTAssertNotNil(config.cachedAppUpdateRelease,
                        "skip must NOT wipe the cache — Updates tab still needs it")
        XCTAssertEqual(sut.latestRelease?.tag, "v999.0.0",
                       "skip must NOT wipe the raw payload")
        XCTAssertNil(sut.availableRelease,
                     "skipped tag must vanish from the Watchtower view")
    }

    func testUnskip_restoresWatchtowerVisibility() async {
        await sut.refresh()
        sut.skip("v999.0.0")
        XCTAssertNil(sut.availableRelease)

        sut.unskip("v999.0.0")

        XCTAssertEqual(sut.availableRelease?.tag, "v999.0.0",
                       "unskip must let the Watchtower banner re-appear")
    }

    /// After the user installs an update, the next refresh returns a tag equal
    /// to `AppVersion.current`. `latestRelease` updates to the new payload but
    /// `hasNewerRelease` is false — UI shows "up to date".
    func testRefresh_currentEqualsRemote_clearsAvailable() async {
        await sut.refresh()
        XCTAssertNotNil(sut.availableRelease)

        mock.responseBody = #"""
        {"tag_name":"\#(AppVersion.current)","html_url":"https://example.com/r","body":""}
        """#.data(using: .utf8)!

        await sut.refresh(force: true)

        XCTAssertNil(sut.availableRelease)
        XCTAssertFalse(sut.hasNewerRelease)
        XCTAssertEqual(sut.latestRelease?.tag, AppVersion.current,
                       "latestRelease holds the newly-fetched payload regardless of newness")
    }

    // MARK: - Configurable throttle interval

    func testRefresh_neverInterval_blocksBackgroundProbe() async {
        config.appUpdateCheckInterval = .never

        await sut.refresh() // background — must short-circuit

        XCTAssertEqual(mock.callCount, 0,
                       ".never must disable background probes entirely")
    }

    func testRefresh_neverInterval_doesNotBlockForcedProbe() async {
        config.appUpdateCheckInterval = .never

        await sut.refresh(force: true)

        XCTAssertEqual(mock.callCount, 1,
                       "force=true must always fire even with .never interval")
    }

    func testRefresh_dailyInterval_skipsWithin24h() async {
        config.appUpdateCheckInterval = .daily
        config.lastAppUpdateCheckAt = Date()

        await sut.refresh()

        XCTAssertEqual(mock.callCount, 0,
                       "within-window probe must be throttled")
    }

    func testRefresh_dailyInterval_runsAfter24h() async {
        config.appUpdateCheckInterval = .daily
        config.lastAppUpdateCheckAt = Date().addingTimeInterval(-86_500)

        await sut.refresh()

        XCTAssertEqual(mock.callCount, 1,
                       "out-of-window probe must run")
    }
}
