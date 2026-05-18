import Foundation

/// Disk-backed retry queue for transcription sessions. The queue owns the
/// `~/Library/Application Support/Stash/Transcription/pending/` directory
/// and orchestrates retry timing. The actual upload work is performed by
/// `TranscriptionService.uploadSession(sessionUUID:)` which the queue
/// invokes via a closure injected at app launch.
///
/// Concurrency: Swift actor. All disk writes and state mutations are
/// serialized through the actor. Upload work runs on detached tasks and
/// reports results back via `reportUploadResult`.
///
/// Retry policy: 5 attempts with exponential backoff (2s, 8s, 30s, 2m
/// between attempts). After 5 failures, the session remains in `pending/`
/// indefinitely but does not auto-retry — user must manually retry.
actor TranscriptionRetryQueue {
    static let shared = TranscriptionRetryQueue()

    /// Set at app launch. Returns `true` if the upload succeeded, `false`
    /// for transient errors (queue schedules retry). Throws for persistent
    /// errors (queue gives up after `maxAttempts`).
    var uploadHandler: ((PendingSessionMetadata) async throws -> Bool)?

    /// Published-equivalent state. Read by the UI via `pendingSnapshot()`.
    private var pending: [UUID: PendingSessionMetadata] = [:]
    private var retryTimers: [UUID: Task<Void, Never>] = [:]
    /// Keyed by token so subscribers can unsubscribe on view teardown.
    private var observers: [UUID: ([PendingSessionMetadata]) -> Void] = [:]

    private let maxAttempts = 5
    private let backoffSchedule: [TimeInterval] = [2, 8, 30, 120, 600]   // 2s, 8s, 30s, 2m, 10m

    /// Snapshot of current pending sessions for UI binding.
    func pendingSnapshot() -> [PendingSessionMetadata] {
        return pending.values.sorted(by: { $0.startedAt < $1.startedAt })
    }

    /// AsyncStream of pending-set snapshots. Use from SwiftUI `.task { ... }`
    /// which auto-cancels on view teardown — the stream's `onTermination`
    /// removes the observer so we don't leak callbacks across panel show/hide.
    nonisolated func pendingStream() -> AsyncStream<[PendingSessionMetadata]> {
        AsyncStream { continuation in
            let token = UUID()
            Task {
                // Register the observer on the actor.
                await self.addObserver(token: token) { snapshot in
                    continuation.yield(snapshot)
                }
                // Yield the initial snapshot to the subscriber.
                let initial = await self.pendingSnapshot()
                continuation.yield(initial)
            }
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeObserver(token: token) }
            }
        }
    }

    private func addObserver(token: UUID, callback: @escaping ([PendingSessionMetadata]) -> Void) {
        observers[token] = callback
    }

    private func removeObserver(token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func notifyObservers() {
        let snapshot = pendingSnapshot()
        for callback in observers.values {
            callback(snapshot)
        }
    }

    /// Bootstrap: read disk state on app launch and pre-populate the actor.
    /// Schedules retries for everything found.
    func bootstrap() async {
        do {
            try AudioPersistence.ensureDirectories()
            let onDisk = try AudioPersistence.listPendingSessions()
            for meta in onDisk {
                pending[meta.sessionUUID] = meta
            }
            notifyObservers()
            // Don't auto-drain at launch; wait for first reachability "satisfied"
            // event OR explicit user request. This avoids racing the cold-start
            // network state.
        } catch {
            #if DEBUG
            print("[RetryQueue] bootstrap failed: \(error)")
            #endif
        }
    }

    /// Enqueue a freshly finalized session. Called by TranscriptionService
    /// after `promoteActiveToPending` completes.
    func enqueue(_ metadata: PendingSessionMetadata) {
        pending[metadata.sessionUUID] = metadata
        do {
            try metadata.write()
        } catch {
            #if DEBUG
            print("[RetryQueue] failed to write meta.json: \(error)")
            #endif
        }
        notifyObservers()
        // Kick the first upload attempt immediately.
        scheduleAttempt(sessionUUID: metadata.sessionUUID, delay: 0)
    }

    /// Update the note id created for a session (called from the raw-first
    /// delivery path after `saveQuickNote` / `saveMeetingNote` returns).
    func setCreatedNoteID(for sessionUUID: UUID, noteID: String) {
        guard var meta = pending[sessionUUID] else { return }
        meta.createdNoteID = noteID
        pending[sessionUUID] = meta
        try? meta.write()
        notifyObservers()
    }

    /// Drain all pending sessions immediately (no backoff). Called on
    /// reachability satisfied events and on manual user retry.
    func drainNow() {
        for uuid in pending.keys {
            // Cancel any pending retry timer; we're going now.
            retryTimers[uuid]?.cancel()
            retryTimers.removeValue(forKey: uuid)
            scheduleAttempt(sessionUUID: uuid, delay: 0)
        }
    }

    /// Set the upload handler. Called once at app launch from StashApp.
    func setUploadHandler(_ handler: @escaping (PendingSessionMetadata) async throws -> Bool) {
        self.uploadHandler = handler
    }

    private func scheduleAttempt(sessionUUID: UUID, delay: TimeInterval) {
        retryTimers[sessionUUID]?.cancel()
        // No [weak self] — Swift actors can't be weakly captured. The queue is
        // a singleton with the same lifetime as the app, so retaining it is
        // both required and harmless.
        let task = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self.attemptUpload(sessionUUID: sessionUUID)
        }
        retryTimers[sessionUUID] = task
    }

    private func attemptUpload(sessionUUID: UUID) async {
        guard let meta = pending[sessionUUID] else { return }
        guard let handler = uploadHandler else {
            #if DEBUG
            print("[RetryQueue] uploadHandler not set; skipping attempt for \(sessionUUID)")
            #endif
            return
        }
        do {
            let success = try await handler(meta)
            if success {
                // Upload succeeded → archive + drop from queue.
                try? AudioPersistence.archivePending(sessionUUID: sessionUUID)
                pending.removeValue(forKey: sessionUUID)
                retryTimers.removeValue(forKey: sessionUUID)
                notifyObservers()
                return
            } else {
                // Transient failure — schedule next attempt.
                bumpAttempt(sessionUUID: sessionUUID, error: nil)
            }
        } catch {
            bumpAttempt(sessionUUID: sessionUUID, error: error)
        }
    }

    private func bumpAttempt(sessionUUID: UUID, error: Error?) {
        guard var meta = pending[sessionUUID] else { return }
        meta.attemptCount += 1
        meta.lastError = error.map { String(describing: $0) } ?? "transient"
        pending[sessionUUID] = meta
        try? meta.write()
        notifyObservers()
        guard meta.attemptCount < maxAttempts else {
            // Exhausted auto-retries. Stays in pending for manual retry.
            #if DEBUG
            print("[RetryQueue] giving up on \(sessionUUID) after \(meta.attemptCount) attempts (manual retry only)")
            #endif
            retryTimers.removeValue(forKey: sessionUUID)
            return
        }
        // Schedule next attempt using the backoff schedule. `attemptCount`
        // is already incremented; index `attemptCount - 1` gives the delay
        // before the NEXT attempt.
        let index = min(meta.attemptCount, backoffSchedule.count - 1)
        let delay = backoffSchedule[index]
        scheduleAttempt(sessionUUID: sessionUUID, delay: delay)
    }

    #if DEBUG
    func debugListPending() -> [PendingSessionMetadata] {
        return pendingSnapshot()
    }
    #endif
}
