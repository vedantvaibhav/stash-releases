import AppKit
import Foundation

enum NoteOrigin: Equatable {
    case written
    case meeting     // Mode C: ≥ 5 min — cleaned transcript + overview tabs
    case voice       // Mode B: 3–5 min — overview only, no tabs
    case quick       // Mode A: < 3 min — cleaned text + summary, clipboard primary
    case transcribed // legacy format (old files)

    var listIconSystemName: String {
        switch self {
        case .written:     return "square.and.pencil"
        case .meeting:     return "calendar"
        case .voice:       return "mic.fill"
        case .quick:       return "text.bubble"
        case .transcribed: return "waveform"
        }
    }
}

struct NoteItem: Identifiable {
    let id: String
    let title: String
    let preview: String
    let lastEdited: Date
    let origin: NoteOrigin
    let duration: Int   // seconds; 0 for written notes
}

/// Parsed sections of a new-format note.
struct ParsedNote {
    var transcript: String = ""
    var overview: String = ""
    var duration: Int = 0
    var type: NoteOrigin = .written
}

/// Manages notes at ~/Library/Application Support/QuickPanel/notes/ as `.txt` (plain) or `.rtf` (rich).
final class NotesStorage: ObservableObject {
    /// First-line prefix for notes saved from `TranscriptionService` (used to pick list icon).
    static let transcribedMeetingTitlePrefix = "Meeting — "

    @Published private(set) var notes: [NoteItem] = []
    private(set) var hasLoadedInitialList = false

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
            forName: .quickPanelClearNotes,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearAllNotes()
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

    /// Only triggers a refresh if the list has never been loaded.
    /// Safe to call from onAppear — avoids redundant directory scans.
    func loadIfNeeded() {
        guard !hasLoadedInitialList else { return }
        refreshNotes(immediate: true)
    }

    private func kickOffRefresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let items = self.buildNoteItems()
            DispatchQueue.main.async {
                self.hasLoadedInitialList = true
                self.notes = items
            }
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
            let (title, preview, lastEdited, origin, duration) = titlePreviewDateAndOrigin(for: url)
            items.append(NoteItem(id: id, title: title, preview: preview, lastEdited: lastEdited, origin: origin, duration: duration))
        }
        items.sort { $0.lastEdited > $1.lastEdited }
        return items
    }

    private func titlePreviewDateAndOrigin(for url: URL) -> (String, String, Date, NoteOrigin, Int) {
        var lastEdited = Date.distantPast
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let mod = attrs[.modificationDate] as? Date {
            lastEdited = mod
        }

        // New delimited format — detect by checking first line of txt file.
        if url.pathExtension.lowercased() == "txt",
           let data = try? Data(contentsOf: url),
           let string = String(data: data, encoding: .utf8),
           string.hasPrefix("---TRANSCRIPT---") {
            return parseNewFormatMeta(string: string, lastEdited: lastEdited)
        }

        let allLines: [String]
        if url.pathExtension.lowercased() == "rtf",
           let parsed = linesFromRTF(url: url) {
            allLines = parsed
        } else if let data = try? readUpToBytes(from: url, maxBytes: 8192),
                  let string = String(data: data, encoding: .utf8) {
            allLines = string.components(separatedBy: .newlines)
        } else {
            return ("Untitled", "", lastEdited, .written, 0)
        }

        let nonEmptyLines = allLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let rawFirstLine = nonEmptyLines.first ?? ""

        // Detect legacy transcribed origin
        let origin: NoteOrigin = rawFirstLine.hasPrefix(Self.transcribedMeetingTitlePrefix)
            || rawFirstLine.hasPrefix("# Meeting —")
            || rawFirstLine.hasPrefix("# Transcript —")
            ? .transcribed : .written

        let strippedTitle = Self.stripMarkdown(rawFirstLine)
        let title = strippedTitle.isEmpty ? "Untitled" : String(strippedTitle.prefix(60))

        let rawPreview = nonEmptyLines.count > 1 ? nonEmptyLines[1] : ""
        let preview = Self.stripMarkdownForPreview(rawPreview)

        return (title, String(preview.prefix(80)), lastEdited, origin, 0)
    }

    // MARK: - New delimited format helpers

    private func parseNewFormatMeta(string: String, lastEdited: Date) -> (String, String, Date, NoteOrigin, Int) {
        let meta = Self.parseMetaSection(from: string)
        let typeStr = meta["type"] ?? "written"
        let duration = Int(meta["duration"] ?? "0") ?? 0
        let origin: NoteOrigin = typeStr == "meeting" ? .meeting : (typeStr == "voice" ? .voice : (typeStr == "quick" ? .quick : .written))

        if origin == .meeting {
            let overview = Self.parseSection(from: string, named: "OVERVIEW")
            let lines = overview.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Use first non-header line as title
            let firstContent = lines.first(where: { !$0.hasPrefix("#") && !$0.hasPrefix("---") }) ?? lines.first ?? ""
            let title = String(Self.stripMarkdown(firstContent).prefix(60))
            let preview = lines.count > 1 ? String(Self.stripMarkdownForPreview(lines[1]).prefix(80)) : ""
            return (title.isEmpty ? "Meeting Note" : title, preview, lastEdited, origin, duration)
        } else {
            let transcript = Self.parseSection(from: string, named: "TRANSCRIPT")
            let firstLine = transcript.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { !$0.isEmpty }) ?? ""
            let title = String(firstLine.prefix(60))
            return (title.isEmpty ? "Quick Transcript" : title, "", lastEdited, origin, duration)
        }
    }

    static func parseSection(from string: String, named name: String) -> String {
        let startMarker = "---\(name)---"
        guard let startRange = string.range(of: startMarker) else { return "" }
        let afterStart = string[startRange.upperBound...]
        // End at next --- marker or end of string
        if let endRange = afterStart.range(of: "\n---") {
            return String(afterStart[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(afterStart).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseMetaSection(from string: String) -> [String: String] {
        let raw = parseSection(from: string, named: "META")
        var result: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    /// Parses all sections out of a new-format note file.
    func parseNote(id: String) -> ParsedNote {
        let url = notesDirectory.appendingPathComponent("\(id).txt")
        guard let data = try? Data(contentsOf: url),
              let string = String(data: data, encoding: .utf8),
              string.hasPrefix("---TRANSCRIPT---") else {
            // Not new format — return plain text as transcript
            return ParsedNote(transcript: loadNote(id: id), overview: "", duration: 0, type: .written)
        }
        let meta = Self.parseMetaSection(from: string)
        let typeStr = meta["type"] ?? "written"
        let type: NoteOrigin = typeStr == "meeting" ? .meeting : (typeStr == "voice" ? .voice : (typeStr == "quick" ? .quick : .written))
        return ParsedNote(
            transcript: Self.parseSection(from: string, named: "TRANSCRIPT"),
            overview: Self.parseSection(from: string, named: "OVERVIEW"),
            duration: Int(meta["duration"] ?? "0") ?? 0,
            type: type
        )
    }

    // MARK: - Save new-format notes

    @discardableResult
    func saveMeetingNote(transcript: String, overview: String, durationSeconds: Int) -> String {
        let id = createNewNote()
        let isoDate = ISO8601DateFormatter().string(from: Date())
        let content = "---TRANSCRIPT---\n\(transcript)\n---OVERVIEW---\n\(overview)\n---META---\nduration: \(durationSeconds)\ndate: \(isoDate)\ntype: meeting"
        saveNote(id: id, text: content, debounceListRefresh: false)
        return id
    }

    @discardableResult
    func saveVoiceNote(overview: String, durationSeconds: Int) -> String {
        let id = createNewNote()
        let isoDate = ISO8601DateFormatter().string(from: Date())
        let content = "---TRANSCRIPT---\n\(overview)\n---META---\nduration: \(durationSeconds)\ndate: \(isoDate)\ntype: voice"
        saveNote(id: id, text: content, debounceListRefresh: false)
        return id
    }

    @discardableResult
    func saveQuickNote(text: String, durationSeconds: Int) -> String {
        let id = createNewNote()
        let isoDate = ISO8601DateFormatter().string(from: Date())
        let content = "---TRANSCRIPT---\n\(text)\n---META---\nduration: \(durationSeconds)\ndate: \(isoDate)\ntype: quick"
        saveNote(id: id, text: content, debounceListRefresh: false)
        return id
    }

    /// Extracts all lines from an RTF file as plain text.
    private func linesFromRTF(url: URL) -> [String]? {
        if let prefix = try? readUpToBytes(from: url, maxBytes: 24_000),
           let attr = try? NSAttributedString(
            data: prefix,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            return attr.string.components(separatedBy: .newlines)
        }
        guard let data = try? Data(contentsOf: url),
              let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ) else { return nil }
        return attr.string.components(separatedBy: .newlines)
    }

    /// Strips markdown heading prefixes (# ## ### etc.) from a line for display as title.
    static func stripMarkdown(_ line: String) -> String {
        var s = line
        // Strip leading # symbols
        while s.hasPrefix("#") { s = String(s.dropFirst()) }
        s = s.trimmingCharacters(in: .whitespaces)
        // Strip bold markers
        s = s.replacingOccurrences(of: "**", with: "")
        return s
    }

    /// Strips markdown symbols for preview display, converting checkboxes to unicode.
    static func stripMarkdownForPreview(_ line: String) -> String {
        var s = line
        // Strip heading markers
        while s.hasPrefix("#") { s = String(s.dropFirst()) }
        s = s.trimmingCharacters(in: .whitespaces)
        // Convert checkboxes
        s = s.replacingOccurrences(of: "- [ ] ", with: "☐ ")
        s = s.replacingOccurrences(of: "- [x] ", with: "☑ ")
        s = s.replacingOccurrences(of: "- [X] ", with: "☑ ")
        // Strip bold
        s = s.replacingOccurrences(of: "**", with: "")
        // Strip list dash prefix
        if s.hasPrefix("- ") { s = String(s.dropFirst(2)) }
        return s
    }

    private func readUpToBytes(from url: URL, maxBytes: Int) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        return (try fh.read(upToCount: maxBytes)) ?? Data()
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
                string: Self.cleanedDisplayText(from: string),
                attributes: Self.defaultNoteAttributes()
            )
        }

        return NSAttributedString(string: "", attributes: Self.defaultNoteAttributes())
    }

    /// Strips section markers and META from new-format notes for clean display.
    /// Meeting notes return transcript + overview combined; others return transcript only.
    private static func cleanedDisplayText(from raw: String) -> String {
        guard raw.hasPrefix("---TRANSCRIPT---") else { return raw }
        let transcript = parseSection(from: raw, named: "TRANSCRIPT")
        let overview   = parseSection(from: raw, named: "OVERVIEW")
        if !overview.isEmpty {
            return transcript.isEmpty ? overview : transcript + "\n\n---\n\n" + overview
        }
        return transcript
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
        ) else { return }
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
                // Write failed — note will remain in last known state on next refresh.
            }
        }
    }

    func saveNote(id: String, text: String, debounceListRefresh: Bool = true) {
        let txtURL = notesDirectory.appendingPathComponent("\(id).txt")
        let rtfURL = notesDirectory.appendingPathComponent("\(id).rtf")
        guard let data = text.data(using: .utf8) else { return }
        try? data.write(to: txtURL, options: .atomic)
        if fileManager.fileExists(atPath: rtfURL.path) {
            try? fileManager.removeItem(at: rtfURL)
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
