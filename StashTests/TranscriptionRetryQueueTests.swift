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

    @Test func setUploadHandlerDoesNotAutoDrain() async throws {
        let (queue, persistence, root) = try makeQueue()
        defer { cleanup(root) }
        let meta = try seed(persistence)
        try meta.write(in: persistence)
        await queue.bootstrap()

        let counter = AttemptCounter()
        await queue.setUploadHandler { _ in
            await counter.bump()
            return false
        }
        await drain()

        // New contract: setUploadHandler MUST NOT trigger an upload attempt
        // by itself. The launch path is responsible for calling drainNow
        // explicitly. An earlier auto-drain caused a double-drain race
        // with the launch sequence's explicit drainNow — see the commit
        // that removed it for the URLError.cancelled-bumps-attemptCount
        // analysis.
        #expect(await counter.value == 0,
                "setUploadHandler must not auto-drain; only explicit drainNow / userRequestedDrain do")
    }

    @Test func drainNowSkipsExhaustedSessions() async throws {
        let (queue, persistence, root) = try makeQueue()
        defer { cleanup(root) }
        // Seed an exhausted session — attemptCount == maxAttempts (5).
        _ = try seed(persistence, attemptCount: 5)
        await queue.bootstrap()

        let counter = AttemptCounter()
        await queue.setUploadHandler { _ in
            await counter.bump()
            return false
        }
        await queue.drainNow()
        await drain()

        // drainNow must NOT attempt exhausted sessions — otherwise every
        // launch (and every reachability satisfied event) bumps their
        // attemptCount further past the cap. Only userRequestedDrain
        // (which resets attemptCount first) is allowed to re-attempt them.
        #expect(await counter.value == 0,
                "drainNow should skip sessions where attemptCount >= maxAttempts")
    }

    @Test func userRequestedDrainResetsAttemptCountForExhaustedSessions() async throws {
        let (queue, persistence, root) = try makeQueue()
        defer { cleanup(root) }
        _ = try seed(persistence, attemptCount: 5)
        await queue.bootstrap()

        let counter = AttemptCounter()
        await queue.setUploadHandler { _ in
            await counter.bump()
            return false
        }
        // setUploadHandler does NOT auto-drain (new contract). drainNow
        // alone would skip this exhausted session. Only userRequestedDrain
        // (which resets attemptCount to 0 first) can re-attempt.
        await queue.userRequestedDrain()
        await drain()

        let snapshot = await queue.pendingSnapshot()
        #expect(snapshot.first?.attemptCount == 1,
                "userRequestedDrain resets attemptCount to 0, then the immediate retry's transient failure bumps it to 1")
        #expect(await counter.value >= 1,
                "userRequestedDrain must trigger at least one upload attempt against the now-reset session")
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

    @Test func backoffStreamEmitsAttemptCountOnScheduledRetry() async throws {
        let (queue, persistence, root) = try makeQueue()
        defer { cleanup(root) }
        let meta = try seed(persistence)   // attemptCount 0

        let collector = BackoffEventCollector()
        let streamTask = Task {
            for await event in queue.backoffStream() {
                await collector.record(event)
            }
        }
        // Let the stream's observer register on the actor before we trigger
        // the failure that should emit an event.
        await drain()

        // Transient failure → bumpAttempt → scheduleAttempt(delay: 2) →
        // backoffStream emits with the incremented attemptCount.
        await queue.setUploadHandler { _ in false }
        await queue.enqueue(meta)
        await drain()

        streamTask.cancel()
        let events = await collector.events
        #expect(events.contains {
            $0.sessionUUID == meta.sessionUUID
                && $0.attemptCount == 1
                && $0.nextDelaySeconds == 2
        }, "first transient failure should emit a backoff event at attemptCount 1 / 2s delay")
    }
}

/// Actor-protected counter so the upload-handler closure (called from
/// detached tasks inside the queue) can record invocations without races.
private actor AttemptCounter {
    private(set) var value: Int = 0
    func bump() { value += 1 }
}

/// Actor-protected collector for backoff events observed off the stream.
private actor BackoffEventCollector {
    private(set) var events: [BackoffEvent] = []
    func record(_ event: BackoffEvent) { events.append(event) }
}
