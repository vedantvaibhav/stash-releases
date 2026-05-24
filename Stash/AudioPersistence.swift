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
///     ├── processed/<sessionUUID>/               # archived after success
///     │   └── audio.m4a
///     └── quarantine/<sessionUUID>/              # corrupt meta.json moved aside
///         └── audio.m4a                          # audio preserved for forensic recovery
///
/// All transitions between `active/`, `pending/`, `processed/`, `quarantine/`
/// use `FileManager.moveItem(at:to:)` which is atomic on the same volume.
/// Never copy+delete — partial writes during a crash would orphan audio.
///
/// `AudioPersistence` is a `struct` (not an `enum`) so tests can construct
/// their own instance with `init(baseURL:)` rooted in a temp directory and
/// exercise the disk pipeline in isolation. Production callers use
/// `AudioPersistence.shared`, which resolves to `Application Support/Stash/Transcription`.
struct AudioPersistence {

    /// Process-wide singleton used by all production code paths. Tests
    /// construct their own instance via `init(baseURL:)` instead.
    static let shared = AudioPersistence()

    let baseDirectory: URL

    /// `baseURL == nil` (the default) resolves the same Application Support
    /// path that ships in production. Tests pass an `URL` rooted in a temp
    /// directory so they don't stomp on the user's real `Stash/Transcription`
    /// tree.
    init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseDirectory = baseURL
        } else {
            let fm = FileManager.default
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.baseDirectory = support.appendingPathComponent("Stash/Transcription", isDirectory: true)
        }
    }

    var activeDirectory: URL  { baseDirectory.appendingPathComponent("active",    isDirectory: true) }
    var pendingDirectory: URL { baseDirectory.appendingPathComponent("pending",   isDirectory: true) }
    var processedDirectory: URL { baseDirectory.appendingPathComponent("processed", isDirectory: true) }
    /// Quarantine holds sessions whose `meta.json` failed to decode. The
    /// audio file is preserved so a human can recover it; the queue stops
    /// trying to load these on bootstrap.
    var quarantineDirectory: URL { baseDirectory.appendingPathComponent("quarantine", isDirectory: true) }

    /// Create all four subdirectories if missing. Safe to call multiple times.
    func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [activeDirectory, pendingDirectory, processedDirectory, quarantineDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    func activeAudioURL(sessionUUID: UUID) -> URL {
        activeDirectory.appendingPathComponent("\(sessionUUID.uuidString).m4a")
    }

    func pendingSessionDirectory(sessionUUID: UUID) -> URL {
        pendingDirectory.appendingPathComponent(sessionUUID.uuidString, isDirectory: true)
    }

    func pendingAudioURL(sessionUUID: UUID) -> URL {
        pendingSessionDirectory(sessionUUID: sessionUUID).appendingPathComponent("audio.m4a")
    }

    func pendingMetaURL(sessionUUID: UUID) -> URL {
        pendingSessionDirectory(sessionUUID: sessionUUID).appendingPathComponent("meta.json")
    }

    func processedSessionDirectory(sessionUUID: UUID) -> URL {
        processedDirectory.appendingPathComponent(sessionUUID.uuidString, isDirectory: true)
    }

    /// Move `active/<uuid>.m4a` → `pending/<uuid>/audio.m4a`. Creates the
    /// pending session directory. Atomic on same volume.
    func promoteActiveToPending(sessionUUID: UUID) throws {
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
    func archivePending(sessionUUID: UUID) throws {
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
    ///
    /// Sessions whose `meta.json` cannot be read or decoded are moved to
    /// `quarantine/` (audio preserved) instead of silently skipped — the prior
    /// `try?`-swallow path lost audio with no record. Quarantine events fire a
    /// Slack notification via the same webhook the transcription pipeline uses.
    func listPendingSessions() throws -> [PendingSessionMetadata] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pendingDirectory.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)
        var sessions: [PendingSessionMetadata] = []
        for entry in entries {
            let metaURL = entry.appendingPathComponent("meta.json")
            guard fm.fileExists(atPath: metaURL.path) else { continue }
            let audioURL = entry.appendingPathComponent("audio.m4a")
            guard fm.fileExists(atPath: audioURL.path) else {
                // Missing audio.m4a — session is unusable for upload. Skip
                // silently (no quarantine; the meta file alone isn't worth
                // preserving). Likely cause: interrupted promote or manual
                // file deletion.
                continue
            }
            guard let data = try? Data(contentsOf: metaURL) else {
                quarantineSession(at: entry, reason: "meta.json unreadable")
                continue
            }
            do {
                let meta = try JSONDecoder.iso8601.decode(PendingSessionMetadata.self, from: data)
                sessions.append(meta)
            } catch {
                quarantineSession(at: entry, reason: "meta.json decode failed: \(error)")
            }
        }
        sessions.sort { $0.startedAt < $1.startedAt }
        return sessions
    }

    /// List quarantined session folders. Hook for a future "recover audio"
    /// admin UI — the queue itself never touches these.
    func listQuarantinedSessions() -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: quarantineDirectory.path) else { return [] }
        let entries = (try? fm.contentsOfDirectory(at: quarantineDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Read-modify-write of `meta.json` for a pending session. Throws if the
    /// session's meta is missing or undecodable — callers should treat a
    /// throw as "in-memory state is still authoritative, disk drifted".
    func updateMeta(sessionUUID: UUID, mutate: (inout PendingSessionMetadata) -> Void) throws {
        let url = pendingMetaURL(sessionUUID: sessionUUID)
        let data = try Data(contentsOf: url)
        var meta = try JSONDecoder.iso8601.decode(PendingSessionMetadata.self, from: data)
        mutate(&meta)
        try meta.write(in: self)
    }

    /// Move a broken pending session into `quarantine/`. Audio is preserved
    /// so a human can recover it; the queue stops trying to bootstrap it.
    /// If a same-named entry already exists in quarantine (rare), the new
    /// one gets a timestamp suffix so neither is overwritten.
    private func quarantineSession(at folderURL: URL, reason: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: quarantineDirectory.path) {
            try? fm.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        }
        let primaryTarget = quarantineDirectory.appendingPathComponent(folderURL.lastPathComponent, isDirectory: true)
        let target: URL
        if fm.fileExists(atPath: primaryTarget.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            target = quarantineDirectory.appendingPathComponent("\(folderURL.lastPathComponent)-\(stamp)", isDirectory: true)
        } else {
            target = primaryTarget
        }
        do {
            try fm.moveItem(at: folderURL, to: target)
            #if DEBUG
            print("[AudioPersistence] quarantined \(folderURL.lastPathComponent): \(reason)")
            #endif
            Self.reportQuarantineToSlack(sessionFolder: folderURL.lastPathComponent, reason: reason)
        } catch {
            #if DEBUG
            print("[AudioPersistence] FAILED to quarantine \(folderURL.lastPathComponent): \(error)")
            #endif
        }
    }

    /// Best-effort Slack notification for a quarantine event. Mirrors the
    /// payload shape `TranscriptionService.reportToSlack` uses so the same
    /// channel receives all transcription-pipeline anomalies. Errors and
    /// missing webhook URLs are swallowed — disk-write failure of meta.json
    /// is rare and the quarantine itself is the primary signal. Static so it
    /// works even when called from a test-injected instance whose `APIKeys`
    /// resolution is the production one.
    private static func reportQuarantineToSlack(sessionFolder: String, reason: String) {
        guard !APIKeys.slackErrorWebhookURL.isEmpty,
              let url = URL(string: APIKeys.slackErrorWebhookURL) else { return }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let timestamp = formatter.string(from: Date())
        let text = """
        🟠 *Audio session quarantined*
        *Session folder:* \(sessionFolder)
        *Reason:* \(reason)
        *App version:* \(appVersion) (\(buildNumber))
        *macOS:* \(osString)
        *Time:* \(timestamp)
        """
        let body: [String: Any] = ["text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        URLSession.shared.dataTask(with: request).resume()
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

    /// `persistence` defaults to `.shared` so production callers don't have
    /// to thread an instance through. Tests pass their own injected
    /// `AudioPersistence` so the write lands in a temp directory.
    func write(in persistence: AudioPersistence = .shared) throws {
        let url = persistence.pendingMetaURL(sessionUUID: sessionUUID)
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
