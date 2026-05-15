import Foundation
import Network

/// Persistent on-disk queue for Whisper uploads that failed even after
/// the in-process retry. Lives at:
///   ~/Library/Application Support/Stash/Transcription/pending/
///
/// Each entry is a pair: `<id>.m4a` (the original audio) plus
/// `<id>.json` (metadata — original duration, enqueued timestamp).
/// `flush(...)` enumerates the directory and invokes the provided
/// callback for each entry; the callback is expected to attempt a fresh
/// upload and either:
///   - return success → the entry is deleted
///   - return failure → the entry stays for the next flush
///
/// `flush(...)` is called: (1) once on app launch; (2) each time
/// `NWPathMonitor` transitions to `.satisfied`. Order on disk is by
/// filename (which embeds the enqueue timestamp), so older recordings
/// retry first.
@MainActor
final class UploadRetryQueue {
    /// Production singleton — uses the default `Stash/Transcription/pending/`
    /// directory. Tests construct their own instance via `init(directory:)`
    /// pointing at a temp path so they don't pollute the developer's real
    /// pending folder.
    static let shared = UploadRetryQueue(directory: UploadRetryQueue.defaultDirectory)

    /// Callback signature: invoked once per pending entry. Returns true on
    /// successful upload (entry will be deleted), false on failure (kept).
    typealias UploadHandler = (_ audioData: Data, _ durationSeconds: Int) async -> Bool

    /// Default production directory. See "Path divergence" in the plan
    /// preamble — `Stash/` per the brief, not the legacy `QuickPanel/`.
    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Stash")
            .appendingPathComponent("Transcription")
            .appendingPathComponent("pending")
    }

    let directory: URL
    private let pathMonitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "stash.uploadretryqueue.monitor")
    private var handler: UploadHandler?
    private var didStart = false
    private var isFlushing = false
    private var lastPath: NWPath.Status = .requiresConnection

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pathMonitor = NWPathMonitor()
    }

    /// Begin observing path changes and run an initial flush. Calling twice
    /// is a no-op for the monitor (re-starting NWPathMonitor logs a misuse
    /// warning); the handler is replaced and an initial flush still runs.
    func start(handler: @escaping UploadHandler) {
        self.handler = handler
        if !didStart {
            didStart = true
            // pathUpdateHandler fires on monitorQueue (non-main). We hop to
            // MainActor inside the Task before touching instance state. The
            // single `[weak self]` capture is sufficient — no need to repeat
            // it inside the inner Task (the closure already holds a weak ref).
            pathMonitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self else { return }
                    let newStatus = path.status
                    let wasOffline = self.lastPath != .satisfied
                    self.lastPath = newStatus
                    if newStatus == .satisfied && wasOffline {
                        await self.flush()
                    }
                }
            }
            pathMonitor.start(queue: monitorQueue)
        }
        // Initial flush in case anything was left over from a previous launch.
        Task { await self.flush() }
    }

    /// Persist a failed upload to disk. Caller passes the original audio
    /// data + the duration that was recorded; the queue assigns a unique
    /// timestamped id.
    func enqueue(audioData: Data, durationSeconds: Int) {
        let id = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        let audioURL = directory.appendingPathComponent("\(id).m4a")
        let metaURL  = directory.appendingPathComponent("\(id).json")
        try? audioData.write(to: audioURL, options: .atomic)
        let metadata: [String: Any] = [
            "durationSeconds": durationSeconds,
            "enqueuedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let metaData = try? JSONSerialization.data(withJSONObject: metadata) {
            try? metaData.write(to: metaURL, options: .atomic)
        }
    }

    /// Returns the current pending entry count — used by callers that
    /// want to show a "N waiting" badge.
    func pendingCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".m4a") }.count) ?? 0
    }

    /// Iterate pending entries and attempt each via the handler. Re-entrancy-safe.
    func flush() async {
        guard let handler else { return }
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        let audioURLs = contents.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for audioURL in audioURLs {
            let metaURL = audioURL.deletingPathExtension().appendingPathExtension("json")
            guard let audioData = try? Data(contentsOf: audioURL) else { continue }
            let duration: Int
            if let metaData = try? Data(contentsOf: metaURL),
               let json = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
               let d = json["durationSeconds"] as? Int {
                duration = d
            } else {
                duration = 0
            }
            let success = await handler(audioData, duration)
            if success {
                try? FileManager.default.removeItem(at: audioURL)
                try? FileManager.default.removeItem(at: metaURL)
            } else {
                // Stop on first failure — the network is still flaky and
                // hammering each entry would waste battery + bandwidth.
                // The next .satisfied transition (or next launch) retries.
                break
            }
        }
    }
}
