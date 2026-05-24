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
}
