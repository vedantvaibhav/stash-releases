import Foundation

/// Disk layout + Codable metadata for the transcription retry queue.
///
/// Directory structure under `~/Library/Application Support/Stash/Transcription/`:
///
///     Transcription/
///     ├── active/<sessionUUID>.m4a              # currently-recording file
///     ├── pending/<sessionUUID>/
///     │   ├── audio.m4a                          # finalized, awaiting upload
///     │   └── meta.json                          # session metadata
///     └── processed/<sessionUUID>/               # archived after success
///         └── audio.m4a
///
/// All transitions between `active/`, `pending/`, `processed/` use
/// `FileManager.moveItem(at:to:)` which is atomic on the same volume.
/// Never copy+delete — partial writes during a crash would orphan audio.
enum AudioPersistence {

    static let baseDirectory: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Stash/Transcription", isDirectory: true)
    }()

    static var activeDirectory: URL  { baseDirectory.appendingPathComponent("active",    isDirectory: true) }
    static var pendingDirectory: URL { baseDirectory.appendingPathComponent("pending",   isDirectory: true) }
    static var processedDirectory: URL { baseDirectory.appendingPathComponent("processed", isDirectory: true) }

    /// Create all three subdirectories if missing. Safe to call multiple times.
    static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [activeDirectory, pendingDirectory, processedDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    static func activeAudioURL(sessionUUID: UUID) -> URL {
        activeDirectory.appendingPathComponent("\(sessionUUID.uuidString).m4a")
    }

    static func pendingSessionDirectory(sessionUUID: UUID) -> URL {
        pendingDirectory.appendingPathComponent(sessionUUID.uuidString, isDirectory: true)
    }

    static func pendingAudioURL(sessionUUID: UUID) -> URL {
        pendingSessionDirectory(sessionUUID: sessionUUID).appendingPathComponent("audio.m4a")
    }

    static func pendingMetaURL(sessionUUID: UUID) -> URL {
        pendingSessionDirectory(sessionUUID: sessionUUID).appendingPathComponent("meta.json")
    }

    static func processedSessionDirectory(sessionUUID: UUID) -> URL {
        processedDirectory.appendingPathComponent(sessionUUID.uuidString, isDirectory: true)
    }

    /// Move `active/<uuid>.m4a` → `pending/<uuid>/audio.m4a`. Creates the
    /// pending session directory. Atomic on same volume.
    static func promoteActiveToPending(sessionUUID: UUID) throws {
        let fm = FileManager.default
        let activeURL = activeAudioURL(sessionUUID: sessionUUID)
        let pendingDir = pendingSessionDirectory(sessionUUID: sessionUUID)
        if !fm.fileExists(atPath: pendingDir.path) {
            try fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        }
        let pendingURL = pendingAudioURL(sessionUUID: sessionUUID)
        try fm.moveItem(at: activeURL, to: pendingURL)
    }

    /// Move `pending/<uuid>/` → `processed/<uuid>/`. Atomic on same volume.
    /// Caller is responsible for deciding when to archive (typically after
    /// the transcript has been saved to a note successfully).
    static func archivePending(sessionUUID: UUID) throws {
        let fm = FileManager.default
        let pendingDir = pendingSessionDirectory(sessionUUID: sessionUUID)
        let processedDir = processedSessionDirectory(sessionUUID: sessionUUID)
        // Remove any prior processed entry with the same uuid (defensive — UUIDs
        // are unique but a developer might force-retry the same session).
        if fm.fileExists(atPath: processedDir.path) {
            try fm.removeItem(at: processedDir)
        }
        try fm.moveItem(at: pendingDir, to: processedDir)
    }

    /// List all pending session UUIDs by scanning the disk. Sorted by `startedAt`
    /// (ascending) so the queue drains oldest-first.
    static func listPendingSessions() throws -> [PendingSessionMetadata] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pendingDirectory.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)
        var sessions: [PendingSessionMetadata] = []
        for entry in entries {
            let metaURL = entry.appendingPathComponent("meta.json")
            guard fm.fileExists(atPath: metaURL.path) else { continue }
            guard let data = try? Data(contentsOf: metaURL) else { continue }
            guard let meta = try? JSONDecoder.iso8601.decode(PendingSessionMetadata.self, from: data) else { continue }
            sessions.append(meta)
        }
        sessions.sort { $0.startedAt < $1.startedAt }
        return sessions
    }
}

/// Codable representation of `meta.json`. Schema is stable — additions are
/// fine but renames break old pending sessions on disk.
struct PendingSessionMetadata: Codable, Equatable {
    let sessionUUID: UUID
    let startedAt: Date
    let finishedAt: Date
    let durationSeconds: Int
    let intent: SessionIntent
    let frontmostAppBundleID: String?
    var attemptCount: Int
    var lastError: String?
    var createdNoteID: String?

    enum SessionIntent: String, Codable {
        case shortPaste
        case longNote
    }

    func write() throws {
        let url = AudioPersistence.pendingMetaURL(sessionUUID: sessionUUID)
        let data = try JSONEncoder.iso8601.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
