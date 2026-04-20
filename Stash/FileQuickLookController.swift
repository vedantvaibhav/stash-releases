import AppKit
import Combine
import Quartz

/// Describes a collection of files the Quick Look controller is currently
/// navigating, and the layout it came from (grid vs. horizontal row).
///
/// `itemsProvider` is a closure so the list stays fresh across storage edits.
/// `currentColumns` (for grid arrow navigation) lives on the controller, not
/// on this struct, so view-body @State closure-capture bugs cannot desync it.
struct FileSelectionSource {
    enum Layout {
        /// Files-tab grid. Controller reads `FileQuickLookController.currentColumns` live.
        case grid
        /// All-tab Recent Files horizontal row — left/right only; up/down is a no-op.
        case horizontalRow
    }

    let id: String
    let storage: FileDropStorage
    let itemsProvider: () -> [DroppedFileItem]
    let layout: Layout
}

enum FileQuickLookArrow {
    case left, right, up, down
}

@MainActor
final class FileQuickLookController: NSObject, ObservableObject {
    @Published private(set) var selectedFileID: String?

    /// Live column count for grid arrow navigation. Updated by FileDropListContent
    /// from its GeometryReader `.onChange`. Default survives a render before the
    /// first measurement lands.
    var currentColumns: Int = 4

    private var currentSource: FileSelectionSource?

    /// Returns the currently focused item from the active source's live item list.
    var selectedItem: DroppedFileItem? {
        guard let id = selectedFileID, let items = currentSource?.itemsProvider() else { return nil }
        return items.first { $0.id == id }
    }

    /// Resolved on-disk URL for the focused item, or nil if missing.
    var selectedURL: URL? {
        guard let item = selectedItem, let storage = currentSource?.storage else { return nil }
        let url = storage.fileURL(for: item)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Selection

    /// Replaces the active selection with `fileID` and records the navigation source.
    func select(_ fileID: String, from source: FileSelectionSource) {
        currentSource = source
        selectedFileID = fileID
    }

    /// Clears the focused file and, if Quick Look is visible, dismisses it.
    func clearSelection() {
        selectedFileID = nil
        currentSource = nil
        closeQuickLookIfVisible()
    }

    /// Called when the focused file no longer exists in storage — drop the selection.
    /// Order matters: close QL FIRST while the items list is still the one QL
    /// is rendering; then wipe local state. If we cleared state first, QL's
    /// next `previewItemAt:` call for the already-queued redraw might see an
    /// out-of-bounds index.
    func reconcileWithStorage() {
        guard let id = selectedFileID, let items = currentSource?.itemsProvider() else { return }
        guard !items.contains(where: { $0.id == id }) else { return }
        closeQuickLookIfVisible()
        selectedFileID = nil
        currentSource = nil
    }

    // MARK: - Arrow navigation

    /// Moves the focused index within the active source. Clamps at boundaries
    /// (no wrap). Up/down in `.horizontalRow` layout is a no-op.
    func moveSelection(_ direction: FileQuickLookArrow) {
        guard let source = currentSource,
              let id = selectedFileID else { return }
        let items = source.itemsProvider()
        guard let current = items.firstIndex(where: { $0.id == id }) else { return }

        let nextIndex: Int
        switch source.layout {
        case .horizontalRow:
            switch direction {
            case .left:  nextIndex = max(0, current - 1)
            case .right: nextIndex = min(items.count - 1, current + 1)
            case .up, .down: return
            }
        case .grid:
            let cols = max(1, currentColumns)
            switch direction {
            case .left:  nextIndex = max(0, current - 1)
            case .right: nextIndex = min(items.count - 1, current + 1)
            case .up:    nextIndex = max(0, current - cols)
            case .down:  nextIndex = min(items.count - 1, current + cols)
            }
        }

        guard nextIndex != current else { return }
        selectedFileID = items[nextIndex].id
        reloadQuickLookIfVisible()
    }

    // MARK: - Quick Look (stubs filled in later tasks)

    func toggleQuickLook() { /* filled in Task 9 */ }
    func closeQuickLookIfVisible() { /* filled in Task 9 */ }
    func reloadQuickLookIfVisible() { /* filled in Task 9 */ }
}
