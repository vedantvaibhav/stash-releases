import Foundation

/// One short-recording transcript saved to disk for the always-save delivery
/// model. `id` is a `UUID` so the same text recorded twice creates two
/// distinct entries (the user expects to find both in their history rather
/// than have the second silently merge into the first). `isRaw` is true when
/// LLM cleaning failed and we fell back to raw Whisper output — the UI may
/// flag this so the user understands why the text reads less polished.
struct DictationEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    let durationSec: Int
    let sourceAppBundleID: String?
    let sourceAppName: String?
    let isRaw: Bool
}

/// Persistent history of short voice transcripts. One of three delivery
/// channels for the always-paste model — ALWAYS receives a save regardless
/// of whether AutoPasteService actually landed the paste, so the user has a
/// recovery surface when paste misses (Finder desktop, unfocused renderer,
/// secure field, revoked permission, etc.).
///
/// Persistence: a single JSON array at
/// `~/Library/Application Support/QuickPanel/dictations.json`.
/// One file (rather than file-per-entry like NotesStorage) because the
/// payload is small (200–500 chars per entry) and we want the entire
/// history available in O(1) for the inline section in the Notes tab.
/// Atomic writes via `Data.write(to:options:.atomic)`.
///
/// Storage class is not `@MainActor`-isolated; it mirrors NotesStorage's
/// thread model — disk I/O on a private serial queue, `@Published` mutations
/// on main. All caller sites in the app run on the main thread.
final class DictationsStorage: ObservableObject {
    static let shared = DictationsStorage()

    /// Newest-first ordering. New saves prepend; loads decode whatever the
    /// JSON file says (which we wrote newest-first on the previous save).
    @Published private(set) var entries: [DictationEntry] = []

    private let fileURL: URL
    private let fileManager = FileManager.default
    /// Disk writes serialize on this queue so back-to-back save/delete/clear
    /// calls never interleave. Reads happen on whatever queue calls `load()`
    /// — currently only `init` (main) and `refresh()` (caller's queue).
    private let writeQueue = DispatchQueue(label: "com.stash.dictations.write", qos: .utility)

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        // Reuses NotesStorage / ClipboardManager / FileDropStorage's legacy
        // "QuickPanel" folder name. Keeps all app data in one place; if the
        // folder ever gets renamed to "Stash" (matching the bundle), all
        // four storage classes migrate together.
        let appDir = appSupport.appendingPathComponent("QuickPanel")
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("dictations.json")
        load()

        // Settings → "Clear all dictations" posts this; clearAll() is fire-
        // and-forget (no return value to surface back to the UI). Same shape
        // as NotesStorage's `.quickPanelClearNotes` observer.
        NotificationCenter.default.addObserver(
            forName: .quickPanelClearDictations,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearAll()
        }
    }

    /// Append a new dictation. Prepends to maintain newest-first order;
    /// kicks off an async write that won't block the caller.
    func save(_ entry: DictationEntry) {
        entries.insert(entry, at: 0)
        persist()
    }

    /// Remove a single entry by id. No-op if not found.
    func delete(id: UUID) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != before else { return }
        persist()
    }

    /// Wipe all dictations. Used by Settings → Clear dictations history.
    func clearAll() {
        guard !entries.isEmpty else { return }
        entries = []
        persist()
    }

    /// Re-read from disk. Useful after external file edits or to recover
    /// from a corrupted in-memory state. Synchronous read on the caller's
    /// queue.
    func refresh() {
        load()
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Corrupted JSON: log and reset to empty in memory but DO NOT
        // overwrite the file yet. The next successful save() will replace
        // the corrupt file. This gives the user a chance to manually recover
        // a valid file from Time Machine before we clobber it.
        if let decoded = try? decoder.decode([DictationEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    private func persist() {
        let snapshot = entries
        let target = fileURL
        writeQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            // `.atomic` writes to a temp file then renames — there's never a
            // moment where the file exists but is half-written, so a force-
            // quit during persist can lose the *latest* save but never
            // corrupts what was already on disk.
            try? data.write(to: target, options: .atomic)
        }
    }
}
