import Testing
import Foundation
@testable import Stash

/// Behavioural tests for `TranscriptionRetryQueue`. Every test constructs
/// its own queue + `AudioPersistence(baseURL:)` rooted in a temp dir, so
/// state never leaks between tests or into the user's real Stash data.
///
/// Backoff-timing tests verify scheduling decisions WITHOUT actually
/// waiting the scheduled interval — the queue's `attemptCount` increment +
/// `lastError` updates are observable via `pendingSnapshot()` immediately
/// after a failing upload attempt resolves.
@Suite("TranscriptionRetryQueue")
struct TranscriptionRetryQueueTests {

    private func makeQueue() throws -> (TranscriptionRetryQueue, AudioPersistence, URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetryQueueTests-\(UUID().uuidString)", isDirectory: true)
        let persistence = AudioPersistence(baseURL: temp)
        try persistence.ensureDirectories()
        let queue = TranscriptionRetryQueue(persistence: persistence)
        return (queue, persistence, temp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func seed(_ persistence: AudioPersistence, attemptCount: Int = 0) throws -> PendingSessionMetadata {
        let uuid = UUID()
        let dir = persistence.pendingSessionDirectory(sessionUUID: uuid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("fake-audio".utf8).write(to: persistence.pendingAudioURL(sessionUUID: uuid))
        let meta = PendingSessionMetadata(
            sessionUUID: uuid,
            startedAt: Date(),
            finishedAt: Date(),
            durationSeconds: 5,
            intent: .shortPaste,
            frontmostAppBundleID: nil,
            attemptCount: attemptCount,
            lastError: nil,
            createdNoteID: nil
        )
        try meta.write(in: persistence)
        return meta
    }

    /// Yield repeatedly so any pending Tasks the queue scheduled have a
    /// chance to run. Used after enqueue / drainNow to let the upload
    /// handler closure fire before we assert.
    private func drain(maxYields: Int = 50) async {
        for _ in 0..<maxYields {
            await Task.yield()
        }
    }

    @Test func enqueueSuccessArchivesAudioAndClearsSession() async throws {
        let (queue, persistence, root) = try makeQueue()
        defer { cleanup(root) }
        let uuid = UUID()
        try Data("fake-audio".utf8).write(to: persistence.activeAudioURL(sessionUUID: uuid))
        try persistence.promoteActiveToPending(sessionUUID: uuid)
        let meta = PendingSessionMetadata(
            sessionUUID: uuid,
            startedAt: Date(),
            finishedAt: Date(),
            durationSeconds: 5,
            intent: .shortPaste,
            frontmostAppBundleID: nil,
            attemptCount: 0,
            lastError: nil,
            createdNoteID: nil
        )
        await queue.setUploadHandler { _ in true }
        await queue.enqueue(meta)
        await drain()

        let remaining = await queue.pendingSnapshot()
        #expect(remaining.isEmpty, "successful upload should remove session from pending")
        #expect(FileManager.default.fileExists(atPath: persistence.processedSessionDirectory(sessionUUID: uuid).path),
                "successful upload should archive the session to processed/")
    }

    @Test func transientFailureIncrementsAttemptCountAndSchedulesBackoff() async throws {
        let (queue, persistence, root) = try makeQueue()
        defer { cleanup(root) }
        await queue.setUploadHandler { _ in false }   // transient
        let meta = try seed(persistence)
        await queue.enqueue(meta)
        await drain()

        let snapshot = await queue.pendingSnapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.attemptCount == 1,
                "transient failure should bump attemptCount to 1")
    }

    @Test func persistentFailureBumpsAttemptCountAndExhaustsAtMaxAttempts() async throws {
        let (queue, persistence, root) = try makeQueue()
        defer { cleanup(root) }
        // Throwing handler — the queue treats throws as persistent failure
        // (still increments attemptCount per attempt).
        struct UploadError: Error {}
        await queue.setUploadHandler { _ in throw UploadError() }
        let meta = try seed(persistence, attemptCount: 4)  // one attempt away from maxAttempts (5)
        await queue.enqueue(meta)
        await drain()

        let snapshot = await queue.pendingSnapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.attemptCount == 5,
                "5th failure should land exactly at maxAttempts; the queue keeps the entry but stops auto-retrying")
    }

    @Test func drainNowSchedulesEveryPending() async throws {
        let (queue, persistence, root) = try makeQueue()
        defer { cleanup(root) }
        let counter = AttemptCounter()
        await queue.setUploadHandler { _ in
            await counter.bump()
            return false   // keep them in pending so we can count
        }
        let m1 = try seed(persistence)
        let m2 = try seed(persistence)
        await queue.enqueue(m1)
        await queue.enqueue(m2)
        await drain()
        let initialCalls = await counter.value
        #expect(initialCalls >= 2, "both sessions should have been attempted at least once")

        // Now call drainNow — both should be re-attempted immediately.
        await queue.drainNow()
        await drain()
        let afterDrain = await counter.value
        #expect(afterDrain > initialCalls, "drainNow should fire fresh attempts for all pending sessions")
    }

    @Test func setUploadHandlerFiresDrainOnNilToNonNilTransition() async throws {
        let (queue, persistence, root) = try makeQueue()
        defer { cleanup(root) }
        let meta = try seed(persistence)
        // Bypass enqueue's scheduleAttempt by writing directly to disk; then
        // bootstrap to populate the queue's in-memory state without firing
        // the initial upload (handler is still nil here).
        try meta.write(in: persistence)
        await queue.bootstrap()

        let counter = AttemptCounter()
        await queue.setUploadHandler { _ in
            await counter.bump()
            return false
        }
        await drain()

        #expect(await counter.value >= 1,
                "setUploadHandler on nil→non-nil should auto-drain so the orphan loaded by bootstrap gets attempted")
    }

    @Test func userRequestedDrainResetsAttemptCountForExhaustedSessions() async throws {
        let (queue, persistence, root) = try makeQueue()
        defer { cleanup(root) }
        // Seed an exhausted session directly on disk
        let meta = try seed(persistence, attemptCount: 5)
        await queue.bootstrap()

        let counter = AttemptCounter()
        await queue.setUploadHandler { _ in
            await counter.bump()
            return false
        }
        await drain()
        // setUploadHandler's auto-drain might attempt — but at attemptCount=5
        // (>= maxAttempts), the queue's scheduling logic still attempts once
        // and then exhausts. To isolate: snapshot, reset counter, then user-retry.
        await queue.userRequestedDrain()
        await drain()

        let snapshot = await queue.pendingSnapshot()
        #expect(snapshot.first?.attemptCount == 1 || snapshot.first?.attemptCount == 0,
                "userRequestedDrain should reset attemptCount, then the immediate retry bumps it to 1 (or 0 if the handler hasn't fired yet)")
        _ = meta
    }

    @Test func bootstrapRepopulatesFromDisk() async throws {
        let (queue, persistence, root) = try makeQueue()
        defer { cleanup(root) }
        let m1 = try seed(persistence)
        let m2 = try seed(persistence)

        let beforeBootstrap = await queue.pendingSnapshot()
        #expect(beforeBootstrap.isEmpty, "queue starts empty; disk has unread entries")

        await queue.bootstrap()
        let afterBootstrap = await queue.pendingSnapshot()
        #expect(afterBootstrap.count == 2)
        let uuids = Set(afterBootstrap.map(\.sessionUUID))
        #expect(uuids.contains(m1.sessionUUID))
        #expect(uuids.contains(m2.sessionUUID))
    }
}

/// Actor-protected counter so the upload-handler closure (called from
/// detached tasks inside the queue) can record invocations without races.
private actor AttemptCounter {
    private(set) var value: Int = 0
    func bump() { value += 1 }
}
