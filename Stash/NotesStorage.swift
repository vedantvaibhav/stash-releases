import AppKit
import Foundation

/// Written in the editor vs created from live transcription (`TranscriptionService`).
enum NoteOrigin: Equatable {
    case written
    case transcribed

    /// Row icon in the notes list (written vs transcription).
    var listIconSystemName: String {
        switch self {
        case .written: return "square.and.pencil"
        case .transcribed: return "waveform"
        }
    }
}

/// One note in the list: id (filename stem), title (first line max 40 chars), last edited date, origin.
struct NoteItem: Identifiable {
    let id: String
    let title: String
    let lastEdited: Date
    let origin: NoteOrigin
}

/// Manages notes at ~/Library/Application Support/QuickPanel/notes/ as `.txt` (plain) or `.rtf` (rich).
final class NotesStorage: ObservableObject {
    /// First-line prefix for notes saved from `TranscriptionService` (used to pick list icon).
    static let transcribedMeetingTitlePrefix = "Meeting — "

    @Published private(set) var notes: [NoteItem] = []

    private let fileManager = FileManager.default
    private let notesDirectory: URL
    private var listRefreshDebounce: DispatchWorkItem?

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let quickPanelDir = appSupport.appendingPathComponent("QuickPanel")
        try? fileManager.createDirectory(at: quickPanelDir, withIntermediateDirectories: true)
        notesDirectory = quickPanelDir.appendingPathComponent("notes")
        try? fileManager.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        refreshNotes(immediate: true)

        NotificationCenter.default.addObserver(
            forName: Notification.Name("QuickPanelClearNotes"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearAllNotes()
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NewNoteCreated"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNotes(immediate: true)
        }
    }

    /// When `immediate` is false, scans the notes folder after a short delay so saves (e.g. every keystroke in RTF) do not stall the UI.
    /// Safe to call from any thread.
    func refreshNotes(immediate: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if immediate {
                self.listRefreshDebounce?.cancel()
                self.listRefreshDebounce = nil
                self.kickOffRefresh()
                return
            }
            self.listRefreshDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.kickOffRefresh() }
            self.listRefreshDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func kickOffRefresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let items = self.buildNoteItems()
            DispatchQueue.main.async { self.notes = items }
        }
    }

    private func buildNoteItems() -> [NoteItem] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: notesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let noteURLs = contents.filter { url in
            let e = url.pathExtension.lowercased()
            return e == "txt" || e == "rtf"
        }

        var byId: [String: URL] = [:]
        for url in noteURLs {
            let id = url.deletingPathExtension().lastPathComponent
            if byId[id] != nil {
                if url.pathExtension.lowercased() == "rtf" { byId[id] = url }
            } else {
                byId[id] = url
            }
        }

        var items: [NoteItem] = []
        for (id, url) in byId {
            let (title, lastEdited, origin) = titleDateAndOrigin(for: url)
            items.append(NoteItem(id: id, title: title, lastEdited: lastEdited, origin: origin))
        }
        items.sort { $0.lastEdited > $1.lastEdited }
        return items
    }

    private func titleDateAndOrigin(for url: URL) -> (String, Date, NoteOrigin) {
        var lastEdited = Date.distantPast
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let mod = attrs[.modificationDate] as? Date {
            lastEdited = mod
        }

        let plainFirstLine: String
        if url.pathExtension.lowercased() == "rtf",
           let parsed = firstLineFromRTF(url: url) {
            plainFirstLine = parsed
        } else if let data = try? readUpToBytes(from: url, maxBytes: 8192),
                  let string = String(data: data, encoding: .utf8) {
            plainFirstLine = string
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else {
            return ("Untitled", lastEdited, .written)
        }

        let origin: NoteOrigin = plainFirstLine.hasPrefix(Self.transcribedMeetingTitlePrefix) ? .transcribed : .written
        let title = plainFirstLine.isEmpty ? "Untitled" : String(plainFirstLine.prefix(40))
        let trimmed = plainFirstLine.count > 40 ? title + "..." : title
        return (trimmed, lastEdited, origin)
    }

    private func readUpToBytes(from url: URL, maxBytes: Int) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        return (try fh.read(upToCount: maxBytes)) ?? Data()
    }

    /// Prefer a prefix read when refreshing the list; fall back to a full read if RTF is incomplete.
    private func firstLineFromRTF(url: URL) -> String? {
        if let prefix = try? readUpToBytes(from: url, maxBytes: 24_000),
           let attr = try? NSAttributedString(
            data: prefix,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            return attr.string
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = try? Data(contentsOf: url),
              let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ) else { return nil }
        return attr.string
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain string for copy/export (loses formatting in pasteboard as plain text).
    func loadNote(id: String) -> String {
        loadNoteAttributed(id: id).string
    }

    func loadNoteAttributed(id: String) -> NSAttributedString {
        let rtfURL = notesDirectory.appendingPathComponent("\(id).rtf")
        let txtURL = notesDirectory.appendingPathComponent("\(id).txt")

        if fileManager.fileExists(atPath: rtfURL.path),
           let data = try? Data(contentsOf: rtfURL),
           let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            return attr
        }

        if fileManager.fileExists(atPath: txtURL.path),
           let data = try? Data(contentsOf: txtURL),
           let string = String(data: data, encoding: .utf8) {
            return NSAttributedString(
                string: string,
                attributes: Self.defaultNoteAttributes()
            )
        }

        return NSAttributedString(string: "", attributes: Self.defaultNoteAttributes())
    }

    private static func defaultNoteAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]
    }

    func saveNoteAttributed(id: String, attributed: NSAttributedString) {
        let rtfURL = notesDirectory.appendingPathComponent("\(id).rtf")
        let txtURL = notesDirectory.appendingPathComponent("\(id).txt")
        let range = NSRange(location: 0, length: attributed.length)
        // Encode RTF on the calling thread (main) — NSAttributedString is not thread-safe.
        guard let data = try? attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            print("[NotesStorage] saveNoteAttributed: RTF encode failed id=\(id)")
            return
        }
        // Write to disk on a background thread so the main thread is never blocked.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try data.write(to: rtfURL, options: .atomic)
                if self.fileManager.fileExists(atPath: txtURL.path) {
                    try? self.fileManager.removeItem(at: txtURL)
                }
                self.refreshNotes(immediate: false)
            } catch {
                print("[NotesStorage] saveNoteAttributed FAILED id=\(id) error=\(error)")
            }
        }
    }

    func saveNote(id: String, text: String, debounceListRefresh: Bool = true) {
        let txtURL = notesDirectory.appendingPathComponent("\(id).txt")
        let rtfURL = notesDirectory.appendingPathComponent("\(id).rtf")
        guard let data = text.data(using: .utf8) else {
            print("[NotesStorage] saveNote: UTF-8 encode failed id=\(id)")
            return
        }
        do {
            try data.write(to: txtURL, options: .atomic)
            if fileManager.fileExists(atPath: rtfURL.path) {
                try? fileManager.removeItem(at: rtfURL)
            }
            print("[NotesStorage] saved plain id=\(id) path=\(txtURL.path) (\(data.count) bytes)")
        } catch {
            print("[NotesStorage] saveNote FAILED id=\(id) error=\(error)")
        }
        refreshNotes(immediate: !debounceListRefresh)
    }

    func deleteNote(id: String) {
        let txtURL = notesDirectory.appendingPathComponent("\(id).txt")
        let rtfURL = notesDirectory.appendingPathComponent("\(id).rtf")
        try? fileManager.removeItem(at: txtURL)
        try? fileManager.removeItem(at: rtfURL)
        refreshNotes(immediate: true)
    }

    func clearAllNotes() {
        let contents = (try? fileManager.contentsOfDirectory(
            at: notesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in contents {
            let e = url.pathExtension.lowercased()
            guard e == "txt" || e == "rtf" else { continue }
            try? fileManager.removeItem(at: url)
        }
        notes = []
    }

    func createNewNote() -> String {
        "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
    }

    /// Creates an on-disk placeholder so the note appears in the list before the first keystroke.
    func createEmptyNoteFile(id: String) {
        let txtURL = notesDirectory.appendingPathComponent("\(id).txt")
        let rtfURL = notesDirectory.appendingPathComponent("\(id).rtf")
        guard !fileManager.fileExists(atPath: txtURL.path),
              !fileManager.fileExists(atPath: rtfURL.path) else { return }
        saveNote(id: id, text: "", debounceListRefresh: false)
    }

    @discardableResult
    func createNoteWithTitle(_ title: String, body: String) -> String {
        let id = createNewNote()
        let fullText: String
        if body.isEmpty {
            fullText = title
        } else {
            fullText = title + "\n\n" + body
        }
        saveNote(id: id, text: fullText, debounceListRefresh: false)
        return id
    }
}
