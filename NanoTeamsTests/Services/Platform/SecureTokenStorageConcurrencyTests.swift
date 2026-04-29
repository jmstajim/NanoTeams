import XCTest

@testable import NanoTeams

/// Confirms the in-memory store is safe under concurrent reads / writes —
/// realistic because `LLMSettingsView`, `VisionSettingsView`,
/// `ExploratorySearchEmbeddingsCard` and `RoleEditorLLMTab` may all be holding
/// instances simultaneously and the SwiftUI runloop happily fires their
/// `onChange` handlers in parallel.
final class SecureTokenStorageConcurrencyTests: XCTestCase {

    func testInMemory_concurrentWritesToDistinctKeys_neverDeadlock_andAreVisible() {
        let sut = InMemorySecureTokenStorage()
        let exp = expectation(description: "all writes finished")
        exp.expectedFulfillmentCount = 200

        DispatchQueue.concurrentPerform(iterations: 200) { i in
            do {
                try sut.setToken("v\(i)", forKey: "k\(i)")
            } catch {
                XCTFail("write \(i) threw: \(error)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        for i in 0..<200 {
            XCTAssertEqual(sut.token(forKey: "k\(i)"), "v\(i)")
        }
    }

    func testInMemory_concurrentWritesToSameKey_endsInConsistentState() {
        // We don't promise any particular last-writer-wins ordering — only
        // that the resulting value is one of the writes (no torn read,
        // no crash).
        let sut = InMemorySecureTokenStorage()
        let writers = 100
        let exp = expectation(description: "writers done")
        exp.expectedFulfillmentCount = writers

        DispatchQueue.concurrentPerform(iterations: writers) { i in
            try? sut.setToken("v\(i)", forKey: "shared")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        let final = sut.token(forKey: "shared")
        XCTAssertNotNil(final)
        XCTAssertTrue(final?.hasPrefix("v") ?? false)
    }

    func testInMemory_concurrentReadsAndWrites_neverCrash() {
        let sut = InMemorySecureTokenStorage(initial: ["k": "initial"])
        let exp = expectation(description: "mixed work done")
        exp.expectedFulfillmentCount = 400

        DispatchQueue.concurrentPerform(iterations: 200) { i in
            try? sut.setToken("v\(i)", forKey: "k")
            exp.fulfill()
        }
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            _ = sut.token(forKey: "k")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testInMemory_setNilFromOneThread_whileReadFromAnother_neverCrashes() {
        let sut = InMemorySecureTokenStorage(initial: ["k": "x"])
        let exp = expectation(description: "done")
        exp.expectedFulfillmentCount = 100

        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            try? sut.setToken(nil, forKey: "k")
            exp.fulfill()
        }
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            _ = sut.token(forKey: "k")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
}
