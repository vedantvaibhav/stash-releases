import Testing
import Foundation
@testable import Stash

/// Round-trip tests: enqueue audio bytes, flush with a handler that either
/// accepts or rejects, verify the disk state matches. Each test gets an
/// isolated temp directory — never touches the developer's real queue.
@MainActor
struct UploadRetryQueueTests {

    /// Build an isolated UploadRetryQueue + temp dir for this test.
    /// Caller defers cleanup.
    private func makeQueue() -> (UploadRetryQueue, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadRetryQueueTests-\(UUID().uuidString)")
        let q = UploadRetryQueue(directory: dir)
        return (q, dir)
    }

    @Test func enqueueAndFlushSuccessDeletesEntry() async throws {
        let (q, dir) = makeQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data(repeating: 0x42, count: 1024)
        q.enqueue(audioData: bytes, durationSeconds: 30)
        #expect(q.pendingCount() == 1)

        var seenBytes = 0
        var seenDuration = 0
        q.start { audioData, duration in
            seenBytes = audioData.count
            seenDuration = duration
            return true
        }
        await q.flush()
        #expect(seenBytes == 1024)
        #expect(seenDuration == 30)
        #expect(q.pendingCount() == 0)
    }

    @Test func flushFailureKeepsEntry() async throws {
        let (q, dir) = makeQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        q.enqueue(audioData: Data(repeating: 0x01, count: 64), durationSeconds: 15)
        q.start { _, _ in false }
        await q.flush()
        #expect(q.pendingCount() == 1)
    }
}
