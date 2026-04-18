import Foundation
import AppKit
import SQLite3

struct ClipboardEntry: Identifiable {
    let id: Int64
    let text: String
    var isPinned: Bool
}

/// Monitors the system pasteboard every 0.5s, saves plain text to SQLite, and exposes the last 50 entries.
final class ClipboardManager: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published var highlightedId: Int64? = nil
    /// Brief message (e.g. pin limit); cleared automatically.
    @Published var transientMessage: String?

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    /// Plain text of the last entry we persisted (avoids duplicate rows for identical successive copies).
    private var lastSavedContent: String = ""
    private var timer: Timer?
    private let dbPath: String
    private let interval: TimeInterval = 0.5
    private let maxEntries = 50
    private let maxPinnedEntries = 6
    private let previewLength = 60

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let quickPanelDir = appSupport.appendingPathComponent("QuickPanel")
        try? FileManager.default.createDirectory(at: quickPanelDir, withIntermediateDirectories: true)
        dbPath = quickPanelDir.appendingPathComponent("clipboard.db").path
        createTableIfNeeded()
        loadEntries()
        startMonitoring()

        // Settings danger-zone: clear all entries when requested.
        NotificationCenter.default.addObserver(
            forName: .quickPanelClearClipboard,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearAll()
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func startMonitoring() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func createTableIfNeeded() {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE IF NOT EXISTS clipboard (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            created_at INTEGER DEFAULT (strftime('%s','now')),
            is_pinned INTEGER NOT NULL DEFAULT 0
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
        let addColumnSQL = """
            ALTER TABLE clipboard
            ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0
        """
        sqlite3_exec(db, addColumnSQL, nil, nil, nil)
    }

    private func checkPasteboard() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // Only consider plain text; ignore images and files
        guard let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        guard string != lastSavedContent else { return }
        if latestStoredText() == string { return }

        insertEntry(text: string)
    }

    private func latestStoredText() -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        let sql = "SELECT text FROM clipboard ORDER BY id DESC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let cText = sqlite3_column_text(stmt, 0)
        return cText.map { String(cString: $0) }
    }

    private func insertEntry(text: String) {
        if let latest = latestStoredText(), latest == text {
            DispatchQueue.main.async { [weak self] in
                self?.lastSavedContent = text
            }
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        let sql = "INSERT INTO clipboard (text) VALUES (?1);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (text as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
        trimExcessUnpinnedEntries(db: db)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastSavedContent = text
            self.loadEntries()
        }
    }

    /// Removes oldest unpinned rows until at most `maxEntries` rows remain.
    private func trimExcessUnpinnedEntries(db: OpaquePointer) {
        while true {
            var countStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clipboard;", -1, &countStmt, nil) == SQLITE_OK,
                  let cStmt = countStmt else { break }
            defer { sqlite3_finalize(cStmt) }
            guard sqlite3_step(cStmt) == SQLITE_ROW else { break }
            let total = Int(sqlite3_column_int(cStmt, 0))
            guard total > maxEntries else { break }

            let delSql = """
                DELETE FROM clipboard WHERE id = (
                  SELECT id FROM clipboard
                  WHERE IFNULL(is_pinned, 0) = 0
                  ORDER BY created_at ASC, id ASC
                  LIMIT 1
                );
            """
            var delStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, delSql, -1, &delStmt, nil) == SQLITE_OK,
                  let dStmt = delStmt else { break }
            sqlite3_step(dStmt)
            let changed = sqlite3_changes(db)
            sqlite3_finalize(dStmt)
            if changed == 0 { break }
        }
    }

    private func countPinnedInDB() -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clipboard WHERE IFNULL(is_pinned, 0) = 1;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Toggle pin. Returns `false` if pin limit reached (toast already scheduled).
    @discardableResult
    func togglePinned(for entry: ClipboardEntry) -> Bool {
        if entry.isPinned {
            setPinned(id: entry.id, pinned: false)
            loadEntries()
            return true
        }
        guard countPinnedInDB() < maxPinnedEntries else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.transientMessage = "Max 6 pinned items"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    if self?.transientMessage == "Max 6 pinned items" {
                        self?.transientMessage = nil
                    }
                }
            }
            return false
        }
        setPinned(id: entry.id, pinned: true)
        loadEntries()
        return true
    }

    private func setPinned(id: Int64, pinned: Bool) {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        let sql = "UPDATE clipboard SET is_pinned = ?1 WHERE id = ?2;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    func loadEntries() {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, text, IFNULL(is_pinned, 0) FROM clipboard
            ORDER BY is_pinned DESC, created_at DESC, id DESC
            LIMIT ?1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(maxEntries))

        var result: [ClipboardEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let cText = sqlite3_column_text(stmt, 1)
            let text = cText.map { String(cString: $0) } ?? ""
            let pinned = sqlite3_column_int(stmt, 2) != 0
            result.append(ClipboardEntry(id: id, text: text, isPinned: pinned))
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries = result
            self.lastSavedContent = self.latestStoredText() ?? ""
        }
    }

    func clearAll() {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "DELETE FROM clipboard;", nil, nil, nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries = []
            self.lastSavedContent = ""
        }
    }

    func copyToPasteboard(entry: ClipboardEntry) {
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        lastSavedContent = entry.text

        highlightedId = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.highlightedId = nil
        }
    }

    func preview(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= previewLength { return trimmed }
        return String(trimmed.prefix(previewLength)) + "..."
    }
}
