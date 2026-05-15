import Foundation

/// Persistent rejection log for DEBUG triage. Stored as a JSON array;
/// the file is read-modify-written on every rejection and truncated to
/// the most recent `maxEntries`. Reads are cheap (~50 small JSON objects)
/// and writes are infrequent (one per rejection — typically <10/day).
///
/// Not for production telemetry — Slack reports handle that. This is for
/// the engineer to inspect what's being rejected against what the actual
/// transcript was. Surfaced via Debug ▸ Open rejection log.
///
/// Instance-based with a `shared` singleton for production. Tests construct
/// their own instance pointing at a temp directory so they don't clobber
/// the developer's real log file.
///
/// `@MainActor` because every production call site is on MainActor (via
/// `TranscriptionService.logRejection`) and the append path does a
/// read-modify-write of the on-disk array. Annotating the class makes the
/// thread-safety guarantee enforced by the compiler — a future background
/// caller (e.g. the upload-retry replay path running on a Task) would
/// have to `await` an explicit hop, which is the desired behavior.
@MainActor
final class RejectionLog {
    static let maxEntries = 50

    /// Production singleton — writes to `~/Library/Application Support/Stash/`.
    static let shared = RejectionLog(directory: RejectionLog.defaultDirectory)

    /// Default production directory. See "Path divergence" in the plan
    /// preamble — we deliberately use `Stash/` rather than the legacy
    /// `QuickPanel/` per the brief's explicit path.
    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Stash")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    struct Entry: Codable {
        let timestamp: Date
        let durationSeconds: Int
        let rawText: String
        let gate: String
        // Flattened signal fields. `[String: Double?]` was tempting but
        // Swift's auto-synthesised Codable encodes nil values as *missing
        // keys* (not as JSON null) for dictionaries, so the round-trip
        // would be asymmetric and entries would have inconsistent shapes.
        // Explicit optional fields are decisive.
        let noSpeechProb: Double?
        let avgLogprob: Double?
        let voiceActiveSeconds: Double?
        let peakPowerDBFS: Double?
    }

    let directory: URL
    var logURL: URL { directory.appendingPathComponent("rejections.json") }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Append an entry, truncate to `maxEntries`, write atomically.
    /// Errors are swallowed deliberately — best-effort debug instrumentation.
    func append(_ entry: Entry) {
        var entries = read()
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    /// Read the log. Returns [] on any decode failure (including a missing
    /// or corrupt file) so the caller never sees an error path.
    func read() -> [Entry] {
        guard let data = try? Data(contentsOf: logURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }
}
