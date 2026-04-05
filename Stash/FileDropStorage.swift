import AppKit
import Foundation

struct DroppedFileItem: Identifiable, Codable {
    let id: String
    let fileName: String
    let dateDropped: Date
}

/// Manages files stored in ~/Documents/QuickPanel/.
/// Drop-in: moves source into folder (moves atomically when possible; falls back to copy+delete).
/// Drag-out: removes shelf copy after destination finishes reading.
final class FileDropStorage: ObservableObject {
    @Published private(set) var files: [DroppedFileItem] = []
    @Published var lastDropErrorMessage: String?

    /// IDs of items added in the current session — used to trigger green flash on new cards.
    private(set) var newlyAddedIDs: Set<String> = []

    private let fileManager = FileManager.default
    let dropFolder: URL
    private let jsonURL: URL

    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        dropFolder = documents.appendingPathComponent("QuickPanel")
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("QuickPanel")
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        jsonURL = appDir.appendingPathComponent("files.json")

        try? fileManager.createDirectory(at: dropFolder, withIntermediateDirectories: true)
        loadFromJSON()
        reconcileWithDisk()

        NotificationCenter.default.addObserver(
            forName: Notification.Name("QuickPanelClearDroppedFiles"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.clearAll() }

        NotificationCenter.default.addObserver(
            forName: Notification.Name("FileRemovedFromPanel"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.object as? URL else { return }
            self?.files.removeAll { $0.fileName == url.lastPathComponent }
            self?.saveToJSON()
        }
    }

    // MARK: - Persistence

    private func loadFromJSON() {
        guard fileManager.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL) else { files = []; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        files = (try? decoder.decode([DroppedFileItem].self, from: data)) ?? []
    }

    private func saveToJSON() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(files) else { return }
        try? data.write(to: jsonURL)
    }

    /// Reconciles the in-memory list with actual disk contents.
    /// Files on disk but not in JSON are added; files in JSON missing from disk are kept (shown as "File missing").
    private func reconcileWithDisk() {
        guard let diskContents = try? fileManager.contentsOfDirectory(
            at: dropFolder,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let knownNames = Set(files.map { $0.fileName })
        var changed = false

        for diskURL in diskContents {
            let name = diskURL.lastPathComponent
            guard !knownNames.contains(name) else { continue }
            let created = (try? diskURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let item = DroppedFileItem(id: UUID().uuidString, fileName: name, dateDropped: created)
            files.append(item)
            changed = true
        }

        if changed {
            files.sort { $0.dateDropped > $1.dateDropped }
            saveToJSON()
        }
    }

    // MARK: - Public helpers

    func fileURL(for item: DroppedFileItem) -> URL {
        dropFolder.appendingPathComponent(item.fileName)
    }

    func fileExists(_ item: DroppedFileItem) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: item).path)
    }

    /// Called by the grid after a card's flash animation has been shown.
    func clearNewlyAddedID(_ id: String) {
        newlyAddedIDs.remove(id)
    }

    // MARK: - Unique destination

    private func uniqueDestination(for source: URL) -> URL {
        var dest = dropFolder.appendingPathComponent(source.lastPathComponent)
        guard fileManager.fileExists(atPath: dest.path) else { return dest }
        let name = source.deletingPathExtension().lastPathComponent
        let ext  = source.pathExtension
        var counter = 2
        repeat {
            let candidate = ext.isEmpty ? "\(name)-\(counter)" : "\(name)-\(counter).\(ext)"
            dest = dropFolder.appendingPathComponent(candidate)
            counter += 1
        } while fileManager.fileExists(atPath: dest.path)
        return dest
    }

    // MARK: - ⌘V Paste from clipboard

    @discardableResult
    func tryPasteFromPasteboard() -> Bool {
        lastDropErrorMessage = nil
        let pb = NSPasteboard.general

        // Priority 1 — File URLs (⌘C on a file in Finder)
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            print("[Files] Pasting \(urls.count) file(s) from clipboard")
            addFiles(urls)
            return true
        }

        // Priority 2 — NSImage (screenshot, copied from browser/Figma)
        if let image = NSImage(pasteboard: pb) {
            print("[Files] Pasting image from clipboard")
            return savePastedImageAsPNG(image)
        }

        // Priority 3 — Raw PNG / TIFF data
        for type in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType.tiff] {
            if let data = pb.data(forType: type), let image = NSImage(data: data) {
                print("[Files] Pasting raw \(type.rawValue) data")
                return savePastedImageAsPNG(image)
            }
        }

        print("[Files] Nothing pasteable found in clipboard")
        return false
    }

    private func savePastedImageAsPNG(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:]) else { return false }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Pasted Image \(formatter.string(from: Date()))"
        var fileName = "\(base).png"
        var dest = dropFolder.appendingPathComponent(fileName)
        var suffix = 1
        while fileManager.fileExists(atPath: dest.path) {
            suffix += 1
            fileName = "\(base) \(suffix).png"
            dest = dropFolder.appendingPathComponent(fileName)
        }

        do { try png.write(to: dest) } catch { return false }
        guard fileManager.fileExists(atPath: dest.path) else { return false }

        let item = DroppedFileItem(id: UUID().uuidString, fileName: fileName, dateDropped: Date())
        newlyAddedIDs.insert(item.id)
        files.insert(item, at: 0)
        saveToJSON()
        return true
    }

    // MARK: - Drop-in (move-first)

    func addFiles(_ urls: [URL]) {
        lastDropErrorMessage = nil
        try? fileManager.createDirectory(at: dropFolder, withIntermediateDirectories: true)
        var hadSuccess = false

        for url in urls {
            guard url.isFileURL else { continue }

            let src = (url as NSURL).filePathURL?.standardizedFileURL ?? url.standardizedFileURL
            let originalName = src.lastPathComponent

            // Already tracked — bring to top
            if let idx = files.firstIndex(where: { $0.fileName == originalName }) {
                let existing = files.remove(at: idx)
                files.insert(existing, at: 0)
                saveToJSON()
                hadSuccess = true
                continue
            }

            let dest     = uniqueDestination(for: src)
            let destName = dest.lastPathComponent

            if fileManager.fileExists(atPath: dest.path) {
                let item = DroppedFileItem(id: UUID().uuidString, fileName: destName, dateDropped: Date())
                newlyAddedIDs.insert(item.id)
                files.insert(item, at: 0)
                saveToJSON()
                hadSuccess = true
                continue
            }

            let accessed = src.startAccessingSecurityScopedResource()
            defer { if accessed { src.stopAccessingSecurityScopedResource() } }

            // Attempt 1: atomic move (handles both same-volume and cross-volume)
            var moveSucceeded = false
            do {
                try fileManager.moveItem(at: src, to: dest)
                moveSucceeded = true
                print("[Files] Moved: \(originalName) → \(dest.path)")
            } catch {
                print("[Files] Move failed (\(error.localizedDescription)) — trying copy")
            }

            // Attempt 2: copy, then best-effort delete source
            if !moveSucceeded {
                do {
                    try fileManager.copyItem(at: src, to: dest)
                    print("[Files] Copied: \(originalName) → \(dest.path)")
                    let srcStd = src.standardizedFileURL
                    if !srcStd.path.hasPrefix(dropFolder.standardizedFileURL.path) {
                        do {
                            try fileManager.removeItem(at: srcStd)
                            print("[Files] Source removed after copy: \(srcStd.path)")
                        } catch {
                            print("[Files] Source delete skipped (TCC or in-use): \(error.localizedDescription)")
                        }
                    }
                } catch {
                    lastDropErrorMessage = "Could not add \"\(originalName)\" to Quick Panel."
                    print("[Files] Copy also failed: \(error)")
                    continue
                }
            }

            guard fileManager.fileExists(atPath: dest.path) else {
                lastDropErrorMessage = "Could not add \"\(originalName)\" to Quick Panel."
                continue
            }

            let newItem = DroppedFileItem(id: UUID().uuidString, fileName: destName, dateDropped: Date())
            newlyAddedIDs.insert(newItem.id)
            files.insert(newItem, at: 0)
            saveToJSON()
            hadSuccess = true
        }

        if hadSuccess { lastDropErrorMessage = nil }
    }

    // MARK: - Drag-out

    /// Called by `DraggableFileView.draggingSession(_:endedAt:operation:)`.
    /// Removes grid entry immediately; after 0.3 s checks disk — if file is still there the
    /// destination made a copy so we delete our shelf copy; if it's gone the destination moved it.
    func handleDragOutSessionEnded(item: DroppedFileItem, operation: NSDragOperation) {
        guard !operation.isEmpty else {
            print("[Files] Drag cancelled — keeping \(item.fileName)")
            return
        }

        files.removeAll { $0.id == item.id }
        saveToJSON()

        let target = dropFolder.appendingPathComponent(item.fileName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if self.files.contains(where: { $0.fileName == item.fileName }) { return }

            if self.fileManager.fileExists(atPath: target.path) {
                print("[Files] Destination copied — removing shelf copy: \(item.fileName)")
                self.safeRemove(at: target)
            } else {
                print("[Files] File was moved by destination — already gone: \(item.fileName)")
            }
        }
    }

    // MARK: - Clear all (Settings)

    func clearAll() {
        let contents = (try? fileManager.contentsOfDirectory(
            at: dropFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        for url in contents { safeRemove(at: url) }
        files = []
        saveToJSON()
    }

    // MARK: - Delete from grid

    func removeFile(_ item: DroppedFileItem) {
        safeRemove(at: fileURL(for: item))
        files.removeAll { $0.id == item.id }
        saveToJSON()
    }

    // MARK: - Open / reveal

    func openFile(_ item: DroppedFileItem) {
        let url = fileURL(for: item)
        guard fileManager.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    func showInFinder(_ item: DroppedFileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: item)])
    }

    // MARK: - Safety wall: only removes paths inside dropFolder

    private func safeRemove(at url: URL) {
        let allowed  = dropFolder.standardizedFileURL.path
        let resolved = url.standardizedFileURL
        guard resolved.path.hasPrefix(allowed) else {
            print("[Files] BLOCKED: Attempted removeItem outside QuickPanel folder: \(url.path)")
            return
        }
        do {
            try fileManager.removeItem(at: resolved)
            print("[Files] Removed: \(resolved.path)")
        } catch {
            print("[Files] removeItem failed: \(resolved.path) — \(error)")
        }
    }
}
