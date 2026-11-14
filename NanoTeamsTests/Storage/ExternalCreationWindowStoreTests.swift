import XCTest
@testable import NanoTeams

/// The creation window on disk (F6 L4): what a relaunch reads back, and what it refuses to.
final class ExternalCreationWindowStoreTests: XCTestCase {

    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("autovisor/external_creations.json") }
    private let agent = UUID(uuidString: "eeeeeeee-6666-2222-3333-444444444441")!
    private let other = UUID(uuidString: "eeeeeeee-6666-2222-3333-444444444442")!
    private let now = Date(timeIntervalSince1970: 1_799_971_200)

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    func testARoundTrip_keepsEachAgentsStampsInOrder() throws {
        let store = ExternalCreationWindowStore(url: url)
        let stamps: [UUID: [Date]] = [
            agent: [now.addingTimeInterval(-60), now.addingTimeInterval(-600)],
            other: [now.addingTimeInterval(-30)],
        ]
        try store.save(stamps, now: now)
        let loaded = store.load(now: now)
        XCTAssertEqual(loaded[agent], [now.addingTimeInterval(-600), now.addingTimeInterval(-60)])
        XCTAssertEqual(loaded[other], [now.addingTimeInterval(-30)])
    }

    func testAMissingFile_isAnEmptyWindow() {
        XCTAssertEqual(ExternalCreationWindowStore(url: url).load(now: now), [:])
    }

    func testAnUnreadableFile_isAnEmptyWindow() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(ExternalCreationWindowStore(url: url).load(now: now), [:])
    }

    /// Past the retention a stamp can belong to no window the settings offer.
    func testAStampPastTheRetention_isDropped() throws {
        let retention = TimeInterval(AutovisorConstants.maxExternalCreationWindowMinutes * 60)
        let store = ExternalCreationWindowStore(url: url)
        try store.save([agent: [now.addingTimeInterval(-retention - 1), now.addingTimeInterval(-retention)]], now: now)
        XCTAssertEqual(store.load(now: now)[agent], [now.addingTimeInterval(-retention)], "the boundary stays")
    }

    /// A store for a window longer than the settings offer keeps stamps that far back — on save
    /// and on load alike.
    func testALongerRetention_keepsOlderStamps() throws {
        let sixHours = TimeInterval(6 * 3_600)
        let longStore = ExternalCreationWindowStore(
            url: url, retentionMinutes: ExternalCreationWindowStore.retentionMinutes(forWindow: 420))
        try longStore.save([agent: [now.addingTimeInterval(-sixHours)]], now: now)
        XCTAssertEqual(longStore.load(now: now)[agent], [now.addingTimeInterval(-sixHours)])
        XCTAssertNil(ExternalCreationWindowStore(url: url).load(now: now)[agent],
                     "the default retention does not reach six hours back")
    }

    /// A stamp in the future is a clock that moved back since; counting it would hold the window
    /// shut for as long as the clock is behind.
    func testAStampInTheFuture_isDropped() throws {
        let store = ExternalCreationWindowStore(url: url)
        try store.save([agent: [now, now.addingTimeInterval(1)]], now: now.addingTimeInterval(1))
        XCTAssertEqual(store.load(now: now)[agent], [now])
    }

    /// An agent left with no stamp in range is not written as an empty entry.
    func testAnAgentWithNothingInRange_isAbsent() throws {
        let store = ExternalCreationWindowStore(url: url)
        try store.save([agent: [now.addingTimeInterval(-86_400)], other: [now]], now: now)
        let loaded = store.load(now: now)
        XCTAssertNil(loaded[agent])
        XCTAssertEqual(loaded[other], [now])
    }

    func testAKeyThatIsNotAnAgentID_isSkipped() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = ExternalCreationWindowStore.Contents(creations: ["not-a-uuid": [now], agent.uuidString: [now]])
        try AtomicJSONStore().write(contents, to: url)
        let loaded = ExternalCreationWindowStore(url: url).load(now: now)
        XCTAssertEqual(Array(loaded.keys), [agent])
    }

    func testTheDirectoryItCreates_isOwnerOnly() throws {
        try ExternalCreationWindowStore(url: url).save([agent: [now]], now: now)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
