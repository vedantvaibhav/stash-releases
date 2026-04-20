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

    // MARK: - Local key monitor

    private var keyMonitor: Any?
    private weak var panel: NSPanel?

    /// Installs a local keyDown monitor scoped to this process. Call in panel showPanel().
    func installKeyMonitor(on panel: NSPanel) {
        removeKeyMonitor()
        self.panel = panel
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalKeyEvent(event) ? nil : event
        }
    }

    /// Removes the monitor. Call in panel hidePanel() completion.
    func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        panel = nil
    }

    /// Returns true when the event was consumed.
    private func handleLocalKeyEvent(_ event: NSEvent) -> Bool {
        guard let panel = panel, panel.isVisible else { return false }
        // Never interfere with typing.
        if let kp = panel as? KeyablePanel, kp.isTextInputActive { return false }

        switch event.keyCode {
        case 49: // space
            return handleSpacebar()
        case 123, 124, 125, 126: // arrow keys
            guard selectedFileID != nil else { return false }
            switch event.keyCode {
            case 123: moveSelection(.left)
            case 124: moveSelection(.right)
            case 125: moveSelection(.down)
            case 126: moveSelection(.up)
            default: break
            }
            return true // always consume so arrows never reach desktop
        default:
            return false
        }
    }

    private func handleSpacebar() -> Bool {
        if isQuickLookVisible {
            closeQuickLookIfVisible()
            return true
        }
        guard selectedFileID != nil else { return false }
        openQuickLook()
        return true
    }

    // MARK: - Quick Look

    private var isQuickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func toggleQuickLook() {
        if isQuickLookVisible {
            closeQuickLookIfVisible()
        } else if selectedFileID != nil {
            openQuickLook()
        }
    }

    func openQuickLook() {
        guard let id = selectedFileID,
              let source = currentSource,
              let index = source.itemsProvider().firstIndex(where: { $0.id == id }) else { return }
        let panel = QLPreviewPanel.shared()
        panel?.dataSource = self
        panel?.delegate = self
        panel?.reloadData()
        panel?.currentPreviewItemIndex = index
        panel?.makeKeyAndOrderFront(nil)
    }

    func closeQuickLookIfVisible() {
        guard isQuickLookVisible else { return }
        let panel = QLPreviewPanel.shared()
        panel?.orderOut(nil)
        // Don't leave the shared QL panel holding a stale ref to us. Using
        // ObjectIdentifier so we only nil when we're still the owner.
        if let ds = panel?.dataSource as AnyObject?,
           ObjectIdentifier(ds) == ObjectIdentifier(self) {
            panel?.dataSource = nil
        }
        if let dl = panel?.delegate as AnyObject?,
           ObjectIdentifier(dl) == ObjectIdentifier(self) {
            panel?.delegate = nil
        }
    }

    func reloadQuickLookIfVisible() {
        guard isQuickLookVisible else { return }
        QLPreviewPanel.shared().reloadData()
    }

    /// After our selection moves, tell QL which index to display.
    private func syncQuickLookIndex() {
        guard isQuickLookVisible,
              let id = selectedFileID,
              let source = currentSource,
              let index = source.itemsProvider().firstIndex(where: { $0.id == id }) else { return }
        QLPreviewPanel.shared().currentPreviewItemIndex = index
    }
}

// MARK: - QLPreviewPanelDataSource

extension FileQuickLookController: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentSource?.itemsProvider().count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let source = currentSource else { return NSURL() as QLPreviewItem }
        let items = source.itemsProvider()
        guard items.indices.contains(index) else { return NSURL() as QLPreviewItem }
        let url = source.storage.fileURL(for: items[index])
        return url as NSURL
    }
}

// MARK: - QLPreviewPanelController (informal — helps QL dispatch if responder chain finds us)

extension FileQuickLookController {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Defensive — QL is tearing down its control of us.
    }
}

// MARK: - QLPreviewPanelDelegate

extension FileQuickLookController: QLPreviewPanelDelegate {
    /// QL forwards unhandled key events here before running its defaults.
    /// Returning true means we fully handled it.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 49: // space → close QL, hand key status back to Stash's panel
            closeQuickLookIfVisible()
            // Without this, there is a 1–2 frame window where no window is key
            // and a quickly-repeated space can leak to whatever becomes key next.
            self.panel?.makeKeyAndOrderFront(nil)
            return true
        case 123: // left
            moveSelection(.left)
            panel?.reloadData()
            syncQuickLookIndex()
            return true
        case 124: // right
            moveSelection(.right)
            panel?.reloadData()
            syncQuickLookIndex()
            return true
        case 125, 126: // up, down
            // In grid layout up/down must also change the focused file in QL.
            switch event.keyCode {
            case 125: moveSelection(.down)
            case 126: moveSelection(.up)
            default: break
            }
            panel?.reloadData()
            syncQuickLookIndex()
            return true
        default:
            return false
        }
    }
}
