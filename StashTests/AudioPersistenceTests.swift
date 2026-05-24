import Testing
import Foundation
@testable import Stash

/// Disk-pipeline tests for `AudioPersistence`. Each test runs against a
/// fresh temp directory injected via `AudioPersistence(baseURL:)` — never
/// touches the user's real `Application Support/Stash/Transcription`.
@Suite("AudioPersistence")
struct AudioPersistenceTests {

    private func makePersistence() throws -> (AudioPersistence, URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        let ap = AudioPersistence(baseURL: temp)
        try ap.ensureDirectories()
        return (ap, temp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeMeta(uuid: UUID) -> PendingSessionMetadata {
        PendingSessionMetadata(
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
    }

    @Test func promoteActiveMovesAudioToPending() throws {
        let (ap, root) = try makePersistence()
        defer { cleanup(root) }
        let uuid = UUID()
        let active = ap.activeAudioURL(sessionUUID: uuid)
        try Data("fake-audio".utf8).write(to: active)

        try ap.promoteActiveToPending(sessionUUID: uuid)

        #expect(!FileManager.default.fileExists(atPath: active.path),
                "active file should be gone after promote")
        #expect(FileManager.default.fileExists(atPath: ap.pendingAudioURL(sessionUUID: uuid).path),
                "pending audio should exist after promote")
    }

    @Test func archivePendingOverwritesPriorProcessedEntry() throws {
        let (ap, root) = try makePersistence()
        defer { cleanup(root) }
        let uuid = UUID()
        // Pending session has the new audio
        try FileManager.default.createDirectory(at: ap.pendingSessionDirectory(sessionUUID: uuid),
                                                 withIntermediateDirectories: true)
        try Data("audio-v2".utf8).write(to: ap.pendingAudioURL(sessionUUID: uuid))
        // Prior processed entry has stale audio
        let processedDir = ap.processedSessionDirectory(sessionUUID: uuid)
        try FileManager.default.createDirectory(at: processedDir, withIntermediateDirectories: true)
        try Data("audio-v1-old".utf8).write(to: processedDir.appendingPathComponent("audio.m4a"))

        try ap.archivePending(sessionUUID: uuid)

        let archived = processedDir.appendingPathComponent("audio.m4a")
        #expect(FileManager.default.fileExists(atPath: archived.path))
        #expect(try Data(contentsOf: archived) == Data("audio-v2".utf8),
                "archive should contain new audio, not the stale prior entry")
    }

    @Test func listPendingSkipsSessionMissingAudio() throws {
        let (ap, root) = try makePersistence()
        defer { cleanup(root) }
        let uuid = UUID()
        let dir = ap.pendingSessionDirectory(sessionUUID: uuid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // meta.json exists, audio.m4a does not
        try makeMeta(uuid: uuid).write(in: ap)

        let sessions = try ap.listPendingSessions()

        #expect(sessions.isEmpty, "session missing audio.m4a must be skipped silently")
    }

    @Test func corruptMetaIsQuarantined() throws {
        let (ap, root) = try makePersistence()
        defer { cleanup(root) }
        let uuid = UUID()
        let dir = ap.pendingSessionDirectory(sessionUUID: uuid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Both files present, but meta.json is junk
        try Data("{not valid json}".utf8).write(to: ap.pendingMetaURL(sessionUUID: uuid))
        try Data("fake-audio".utf8).write(to: ap.pendingAudioURL(sessionUUID: uuid))

        let sessions = try ap.listPendingSessions()

        #expect(sessions.isEmpty, "corrupt-meta session must not be returned to the queue")
        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "pending dir should be moved out to quarantine")
        let quarantined = ap.listQuarantinedSessions()
        #expect(quarantined.count == 1)
        #expect(quarantined.first?.lastPathComponent == uuid.uuidString)
    }
}
