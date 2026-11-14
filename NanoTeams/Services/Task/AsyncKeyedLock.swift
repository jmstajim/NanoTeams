import Foundation

/// A FIFO lock per key, held across suspension points — the per-folder lock of the snapshot
/// store (`TaskSnapshotService.withFolderLock`). In-process only: it serializes this process's
/// git calls on a store, not another process's (D-M18, N17).
nonisolated final class AsyncKeyedLock: @unchecked Sendable {
    private let lock = NSLock()
    private var lockedKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(key: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !lockedKeys.contains(key) {
                lockedKeys.insert(key)
                lock.unlock()
                continuation.resume()
            } else {
                waiters[key, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    func release(key: String) {
        lock.lock()
        if var keyWaiters = waiters[key], !keyWaiters.isEmpty {
            let next = keyWaiters.removeFirst()
            if keyWaiters.isEmpty {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = keyWaiters
            }
            lock.unlock()
            next.resume()
        } else {
            lockedKeys.remove(key)
            lock.unlock()
        }
    }
}
