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
/// Retry policy: 5 attempts with exponential backoff (2s, 8s, 30s, 2m, 10m
/// between attempts). After 5 failures, the session remains in `pending/`
/// indefinitely but does not auto-retry — user must manually retry.
actor TranscriptionRetryQueue {
    static let shared = TranscriptionRetryQueue()

    /// `persistence == .shared` (the default) is the production-wired
    /// Application Support location. Tests construct their own queue with
    /// an `AudioPersistence(baseURL:)` rooted in a temp directory so disk
    /// writes don't escape into the user's real Stash data.
    private let persistence: AudioPersistence

    init(persistence: AudioPersistence = .shared) {
        self.persistence = persistence
    }

    /// Set at app launch. Returns `true` if the upload succeeded, `false`
    /// for transient errors (queue schedules retry). Throws for persistent
    /// errors (queue gives up after `maxAttempts`).
    var uploadHandler: ((PendingSessionMetadata) async throws -> Bool)?

    /// Published-equivalent state. Read by the UI via `pendingSnapshot()`.
    private var pending: [UUID: PendingSessionMetadata] = [:]
    private var retryTimers: [UUID: Task<Void, Never>] = [:]
    /// Keyed by token so subscribers can unsubscribe on view teardown.
    private var observers: [UUID: ([PendingSessionMetadata]) -> Void] = [:]
    /// Backoff-event subscribers (mirrors `observers`). Fired each time a
    /// retry is scheduled with a non-zero delay, so the UI can show
    /// "waiting on retry" with the current attempt count.
    private var backoffObservers: [UUID: (BackoffEvent) -> Void] = [:]

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
                // Register the observer on the actor, then yield the initial
                // snapshot to the subscriber.
                await self.registerObserver(token: token) { snapshot in
                    continuation.yield(snapshot)
                }
                let initial = await self.pendingSnapshot()
                continuation.yield(initial)
            }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregisterObserver(token: token) }
            }
        }
    }

    /// Actor-isolated observer mutators called from the nonisolated
    /// `pendingStream`. Kept as one-line helpers (vs. inlining `observers[...] = ...`
    /// at the call site) because the call site lives inside an `AsyncStream`
    /// closure that has no direct access to actor-isolated state without an
    /// `await`-able function.
    private func registerObserver(token: UUID, callback: @escaping ([PendingSessionMetadata]) -> Void) {
        observers[token] = callback
    }

    private func unregisterObserver(token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// AsyncStream of backoff events — one per retry scheduled with delay > 0.
    /// Mirrors `pendingStream`'s observer lifecycle. Subscribers (the
    /// TranscriptionService) flip "waiting on retry" UI state on each event.
    nonisolated func backoffStream() -> AsyncStream<BackoffEvent> {
        AsyncStream { continuation in
            let token = UUID()
            Task {
                await self.registerBackoffObserver(token: token) { event in
                    continuation.yield(event)
                }
            }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregisterBackoffObserver(token: token) }
            }
        }
    }

    private func registerBackoffObserver(token: UUID, callback: @escaping (BackoffEvent) -> Void) {
        backoffObservers[token] = callback
    }

    private func unregisterBackoffObserver(token: UUID) {
        backoffObservers.removeValue(forKey: token)
    }

    private func notifyBackoffObservers(_ event: BackoffEvent) {
        for callback in backoffObservers.values {
            callback(event)
        }
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
            try persistence.ensureDirectories()
            let onDisk = try persistence.listPendingSessions()
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
            try metadata.write(in: persistence)
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
        try? meta.write(in: persistence)
        notifyObservers()
    }

    /// Drain all pending sessions immediately (no backoff). Called on
    /// launch and on reachability satisfied events.
    ///
    /// Skips sessions where `attemptCount >= maxAttempts` — those have
    /// exhausted the auto-retry budget and should only be re-attempted via
    /// `userRequestedDrain`, which resets `attemptCount` first. Without this
    /// guard, every launch / reachability event pings dead sessions, wastes
    /// Whisper API calls, and (worse) bumps their `attemptCount` further
    /// past the cap via the `bumpAttempt` write that happens before the
    /// exhaustion check.
    func drainNow() {
        for (uuid, meta) in pending where meta.attemptCount < maxAttempts {
            // Cancel any pending retry timer; we're going now.
            retryTimers[uuid]?.cancel()
            retryTimers.removeValue(forKey: uuid)
            scheduleAttempt(sessionUUID: uuid, delay: 0)
        }
    }

    /// User-driven retry (tapped the "N waiting" pill). Resets every pending
    /// session's `attemptCount` to 0 — including sessions that have exhausted
    /// the auto-retry budget (`attemptCount >= maxAttempts`), which `drainNow`
    /// alone wouldn't re-attempt because their retry timer was removed at
    /// exhaustion. After resetting in-memory + persisting via
    /// `AudioPersistence.updateMeta`, falls through to `drainNow`.
    func userRequestedDrain() {
        for uuid in pending.keys {
            guard var meta = pending[uuid] else { continue }
            meta.attemptCount = 0
            meta.lastError = nil
            pending[uuid] = meta
            do {
                try persistence.updateMeta(sessionUUID: uuid) { stored in
                    stored.attemptCount = 0
                    stored.lastError = nil
                }
            } catch {
                #if DEBUG
                print("[RetryQueue] userRequestedDrain: failed to persist reset for \(uuid): \(error)")
                #endif
            }
        }
        notifyObservers()
        drainNow()
    }

    /// Set the upload handler. Called once at app launch from StashApp,
    /// which is also responsible for invoking `drainNow()` explicitly
    /// after wiring the handler. The queue does NOT auto-drain here — an
    /// earlier auto-drain caused a double-drain race with the launch path's
    /// explicit `drainNow`: `scheduleAttempt`'s `retryTimers[uuid]?.cancel()`
    /// fires `URLError.cancelled` on the in-flight `URLSession.data(for:)`,
    /// which `uploadSession` catches as transient and `bumpAttempt`s. Result:
    /// every orphan session's `attemptCount` bumped on every launch even
    /// when no real upload was attempted.
    func setUploadHandler(_ handler: @escaping (PendingSessionMetadata) async throws -> Bool) {
        uploadHandler = handler
    }

    private func scheduleAttempt(sessionUUID: UUID, delay: TimeInterval) {
        retryTimers[sessionUUID]?.cancel()
        // Emit a backoff event for delayed (real retry) scheduling only. The
        // delay == 0 case is an immediate drain, not a wait, so it doesn't
        // drive the "waiting on retry" UI.
        if delay > 0 {
            let attemptCount = pending[sessionUUID]?.attemptCount ?? 0
            notifyBackoffObservers(BackoffEvent(
                sessionUUID: sessionUUID,
                attemptCount: attemptCount,
                nextDelaySeconds: delay
            ))
        }
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
                // Upload succeeded → archive + drop from queue. Order matters:
                // if archive fails (disk full, permissions), keep the session
                // in `pending` so bootstrap doesn't re-enqueue it on next
                // launch (the upload already succeeded — re-running would
                // produce a duplicate note).
                do {
                    try persistence.archivePending(sessionUUID: sessionUUID)
                    pending.removeValue(forKey: sessionUUID)
                    retryTimers.removeValue(forKey: sessionUUID)
                    notifyObservers()
                } catch {
                    #if DEBUG
                    print("[RetryQueue] archivePending failed after successful upload: \(error) — session \(sessionUUID) stays in pending to prevent duplicate on next launch")
                    #endif
                }
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
        try? meta.write(in: persistence)
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
        // was just incremented to count the failure we're handling, so we
        // subtract 1 to index into the schedule for the delay BEFORE the
        // next retry. After 1st failure (attemptCount=1), index=0 → 2s.
        // After 2nd failure (attemptCount=2), index=1 → 8s. Etc.
        let index = min(meta.attemptCount - 1, backoffSchedule.count - 1)
        let delay = backoffSchedule[index]
        scheduleAttempt(sessionUUID: sessionUUID, delay: delay)
    }

}

/// Emitted by `TranscriptionRetryQueue.backoffStream()` whenever a retry is
/// scheduled with a non-zero delay. Sendable so it can cross the actor
/// boundary into the AsyncStream consumer.
struct BackoffEvent: Sendable {
    let sessionUUID: UUID
    let attemptCount: Int
    let nextDelaySeconds: TimeInterval
}
