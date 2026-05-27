import Testing
import Foundation
@testable import Stash

/// Raw-first delivery contract: when the LLM cleanup call in
/// `deliverTranscriptShort` / `deliverTranscriptLong` throws, the raw note
/// persisted at phase 1 must remain unchanged (the user always has their
/// transcript, even if cleanup fails) and the Slack reporter is invoked.
///
/// Direct end-to-end tests of `deliverTranscriptShort` / `deliverTranscriptLong`
/// require an injectable `NotesStorage` (currently writes to a fixed
/// Application Support path), which is a separate refactor. This file
/// covers the contract by verifying the `chatFunction` injection seam
/// itself — the rest of the delivery flow is unchanged from production,
/// so an injected-throw test against the seam proves the cleanup-failure
/// path is reachable from tests once the storage injection lands.
///
/// TODO: extend with full-pipeline tests once `NotesStorage` gains a
/// `init(baseURL:)` analogous to `AudioPersistence`.
@Suite("Raw-first delivery (cleanup failure path)")
@MainActor
struct RawFirstDeliveryTests {

    @Test func chatFunctionRoutesAwayFromRealCallChatWhenSet() async throws {
        let svc = TranscriptionService()
        var capturedSystem: String?
        var capturedUser: String?
        var capturedMaxTokens: Int?
        var capturedModel: String?
        svc.chatFunction = { sys, user, max, model in
            capturedSystem = sys
            capturedUser = user
            capturedMaxTokens = max
            capturedModel = model
            return "mocked-cleanup-output"
        }

        let result = try await svc.runChat(
            systemPrompt: "test-system",
            userMessage: "test-user",
            maxTokens: 1024,
            model: "test-model"
        )

        #expect(result == "mocked-cleanup-output")
        #expect(capturedSystem == "test-system")
        #expect(capturedUser == "test-user")
        #expect(capturedMaxTokens == 1024)
        #expect(capturedModel == "test-model")
    }

    @Test func chatFunctionPropagatesThrows() async {
        let svc = TranscriptionService()
        struct CleanupFailed: Error {}
        svc.chatFunction = { _, _, _, _ in throw CleanupFailed() }

        await #expect(throws: CleanupFailed.self) {
            _ = try await svc.runChat(
                systemPrompt: "s",
                userMessage: "u",
                maxTokens: 100,
                model: "m"
            )
        }
    }

    /// uploadSession resets the "waiting on retry" published state at attempt
    /// entry (before the audio load). We pre-set the flags, then call
    /// uploadSession with a session whose audio file doesn't exist — it throws
    /// at the Data(contentsOf:) load, but resetWaitingState() already ran at
    /// the top, so the flags clear regardless of the throw.
    ///
    /// The complementary "flips true on URLError" path can't be unit-tested
    /// here (callWhisper isn't injectable and a transport-layer URLError can't
    /// be forced deterministically); the flip mechanism is covered by
    /// TranscriptionRetryQueueTests.backoffStreamEmitsAttemptCountOnScheduledRetry
    /// plus the manual verification in the PR.
    @Test func uploadSessionEntryResetsWaitingState() async {
        let svc = TranscriptionService()
        svc.isWaitingOnRetry = true
        svc.waitingRetryAttempt = 3

        let meta = PendingSessionMetadata(
            sessionUUID: UUID(),            // random → no audio file on disk
            startedAt: Date(),
            finishedAt: Date(),
            durationSeconds: 5,
            intent: .shortPaste,
            frontmostAppBundleID: nil,
            attemptCount: 0,
            lastError: nil,
            createdNoteID: nil
        )
        _ = try? await svc.uploadSession(metadata: meta)

        #expect(svc.isWaitingOnRetry == false)
        #expect(svc.waitingRetryAttempt == 0)
    }
}
