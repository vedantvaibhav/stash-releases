# Quick Look Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Finder-style Quick Look preview to file thumbnails in Stash, with persistent single-selection, keyboard navigation, and tight lifecycle control.

**Architecture:** Introduce a single `FileQuickLookController` (@MainActor, NSObject) owned by `PanelController`. It holds the QL-focused file id, installs/removes a local `NSEvent` key monitor on panel show/hide, handles arrow navigation against a surface-specific source (grid vs. horizontal row), and conforms to `QLPreviewPanelDataSource` + `QLPreviewPanelDelegate`. `FileSelectionState` (existing multi-select) is lifted to a single instance shared across the Files tab and the All-tab Recent Files row so both surfaces reflect one source of truth. A 1.5pt `systemBlue` ring is added on top of the existing white fill to signal the QL-focused file.

**Tech Stack:** Swift, SwiftUI + AppKit bridging (NSHostingView / NSViewRepresentable), Quartz (QLPreviewPanel), NSEvent monitors.

---

## File Structure

**Created:**
- `Stash/FileQuickLookController.swift` — new class; owns QL selection, key monitor, arrow nav, QL delegate

**Modified:**
- `Stash/PanelController.swift` — instantiate controller; install/remove monitor in show/hide; clear selection in hide; pass controller down
- `Stash/FileDropZoneView.swift` — add QL-selected visual ring; remove transient selection wipe on mouseExit; plumb `onPlainSelect` callback; thread QL selection through `FileDropCardRepresentable`; lift shared-selection ownership out of `FileDropListContent`
- `Stash/PanelSharedSections.swift` — accept shared `FileSelectionState` / `FileGridHoverState` / `FileQuickLookController` on `AllCombinedView` instead of creating local `@StateObject` instances

**Not touched:**
- `GlobalHotKey.swift`, `AuthService.swift`, `TranscriptionService.swift`
- Drag-in / drag-out logic (NSDraggingSource paths, `FileDropContainerView`)
- `NotesEditorView`, clipboard, transcription
- Sparkle / appcast, Signing & Capabilities, Info.plist

---

## Task 1: Expose text-input check on KeyablePanel

**Files:**
- Modify: `Stash/PanelController.swift:48-53`

The `FileQuickLookController` must ask the panel whether a text view is currently first responder before consuming spacebar/arrow keys. The existing private property `isPasteTargetedAtTextInput` has the exact logic — promote it to internal and rename it `isTextInputActive` so its scope is obvious. Keep the existing caller (`sendEvent`) working.

- [ ] **Step 1: Rename and expose the check**

Edit `Stash/PanelController.swift`. Change the property:

```swift
// Before (line 48-53):
private var isPasteTargetedAtTextInput: Bool {
    guard let fr = firstResponder else { return false }
    if fr is NSTextView { return true }
    if let tf = fr as? NSTextField, tf.isEditable { return true }
    return false
}

// After:
var isTextInputActive: Bool {
    guard let fr = firstResponder else { return false }
    if fr is NSTextView { return true }
    if let tf = fr as? NSTextField, tf.isEditable { return true }
    return false
}
```

- [ ] **Step 2: Update the existing caller in `sendEvent`**

Edit the same file, line 24:

```swift
// Before:
!isPasteTargetedAtTextInput {

// After:
!isTextInputActive {
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Stash -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Stash/PanelController.swift
git commit -m "refactor(panel): expose KeyablePanel.isTextInputActive"
```

---

## Task 2: Create FileQuickLookController skeleton

**Files:**
- Create: `Stash/FileQuickLookController.swift`

Introduce the controller class with state, a navigation-source type, and stub methods for select/clear. No key monitor or QL code yet — those come in Tasks 6 and 10. The class must compile and be usable as an `@ObservedObject` from SwiftUI.

- [ ] **Step 1: Write the file**

Create `Stash/FileQuickLookController.swift` with this exact content:

```swift
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

    func toggleQuickLook() { /* filled in Task 10 */ }
    func closeQuickLookIfVisible() { /* filled in Task 10 */ }
    func reloadQuickLookIfVisible() { /* filled in Task 10 */ }
}
```

- [ ] **Step 2: Add to Xcode target via `xcodeproj` Ruby gem (agent-executable)**

The project uses an Xcode project; a new `.swift` file must be registered in `Stash.xcodeproj/project.pbxproj` as a Sources build-phase entry. Do NOT hand-edit the pbxproj. Install `xcodeproj` once, then run a short script:

```bash
gem install xcodeproj 2>/dev/null || sudo gem install xcodeproj
ruby - <<'RUBY'
require 'xcodeproj'
project_path = 'Stash.xcodeproj'
proj = Xcodeproj::Project.open(project_path)
target = proj.targets.find { |t| t.name == 'Stash' } or abort 'Stash target not found'
group  = proj.main_group['Stash'] or abort 'Stash group not found'
file_path = 'Stash/FileQuickLookController.swift'
# Idempotent: skip if already added
unless group.files.any? { |f| f.path == 'FileQuickLookController.swift' }
  ref = group.new_reference('FileQuickLookController.swift')
  target.add_file_references([ref])
end
proj.save
RUBY
```

Expected: `project.pbxproj` gains a `PBXFileReference` + `PBXBuildFile` entry. Verify with `git diff Stash.xcodeproj/project.pbxproj` — one reference, one build file entry.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Stash -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED — the class compiles standalone.

- [ ] **Step 4: Commit**

```bash
git add Stash/FileQuickLookController.swift Stash.xcodeproj
git commit -m "feat(files): add FileQuickLookController skeleton"
```

---

## Task 3: Own and plumb FileQuickLookController in PanelController

**Files:**
- Modify: `Stash/PanelController.swift`

`PanelController` instantiates the controller once, clears selection in `hidePanel`, and makes it available to the SwiftUI tree via `QuickPanelRootView` → `PanelContentView`. Also lift the shared `FileSelectionState` + `FileGridHoverState` here so both tabs reference the same objects.

- [ ] **Step 1: Add the three shared objects to `PanelController`**

Edit `Stash/PanelController.swift`, around line 212 (after `panelInteractionState`):

```swift
// Before:
    let panelInteractionState = PanelInteractionState()
    /// Single instance for panel layout, cards layout, and the floating transcription pill.
    let transcriptionService = TranscriptionService()

// After:
    let panelInteractionState = PanelInteractionState()
    /// Shared across Files tab and All-tab Recent Files row so selection is
    /// a single source of truth (multi-select for drag).
    let fileSelection = FileSelectionState()
    /// Shared grid hover state — keeps only one card hovered at a time across surfaces.
    let fileGridHover = FileGridHoverState()
    /// Owns QL-focused file id, arrow navigation, local key monitor, QL lifecycle.
    let fileQuickLook = FileQuickLookController()
    /// Single instance for panel layout, cards layout, and the floating transcription pill.
    let transcriptionService = TranscriptionService()
```

- [ ] **Step 2: Pass the new objects into `QuickPanelRootView`**

Edit the `QuickPanelRootView(...)` call in `createContentPanel()` (around line 512):

```swift
// Before:
        let root = QuickPanelRootView(
            makePanelKey: { [weak self] in
                self?.contentPanel?.makeKeyAndOrderFront(nil)
            },
            fileDropStorage: fileDropStorage,
            clipboard: clipboardManager,
            notesStorage: notesStorage,
            transcription: transcriptionService,
            panelInteraction: panelInteractionState
        )

// After:
        let root = QuickPanelRootView(
            makePanelKey: { [weak self] in
                self?.contentPanel?.makeKeyAndOrderFront(nil)
            },
            fileDropStorage: fileDropStorage,
            clipboard: clipboardManager,
            notesStorage: notesStorage,
            transcription: transcriptionService,
            panelInteraction: panelInteractionState,
            fileSelection: fileSelection,
            fileGridHover: fileGridHover,
            fileQuickLook: fileQuickLook
        )
```

- [ ] **Step 3: Update `QuickPanelRootView` struct**

Edit the struct definition (line 877) to accept the new objects:

```swift
// Before:
struct QuickPanelRootView: View {
    var makePanelKey: () -> Void
    @ObservedObject var fileDropStorage: FileDropStorage
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var notesStorage: NotesStorage
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var panelInteraction: PanelInteractionState

// After:
struct QuickPanelRootView: View {
    var makePanelKey: () -> Void
    @ObservedObject var fileDropStorage: FileDropStorage
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var notesStorage: NotesStorage
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var panelInteraction: PanelInteractionState
    @ObservedObject var fileSelection: FileSelectionState
    @ObservedObject var fileGridHover: FileGridHoverState
    @ObservedObject var fileQuickLook: FileQuickLookController
```

- [ ] **Step 4: Pass them through to `PanelContentView`**

Edit the `PanelContentView(...)` call inside `QuickPanelRootView.body` (around line 896):

```swift
// Before:
                PanelContentView(
                    makePanelKey: makePanelKey,
                    fileDropStorage: fileDropStorage,
                    clipboard: clipboard,
                    notesStorage: notesStorage,
                    transcription: transcription,
                    panelInteraction: panelInteraction,
                    showTranscriptionPage: Binding(
                    ...
                    panelWidth: settings.panelWidth
                )

// After:
                PanelContentView(
                    makePanelKey: makePanelKey,
                    fileDropStorage: fileDropStorage,
                    clipboard: clipboard,
                    notesStorage: notesStorage,
                    transcription: transcription,
                    panelInteraction: panelInteraction,
                    fileSelection: fileSelection,
                    fileGridHover: fileGridHover,
                    fileQuickLook: fileQuickLook,
                    showTranscriptionPage: Binding(
                        get: { panelInteraction.showTranscriptionPage },
                        set: { panelInteraction.showTranscriptionPage = $0 }
                    ),
                    editingNoteId: Binding(
                        get: { panelInteraction.editingNoteId },
                        set: { panelInteraction.editingNoteId = $0 }
                    ),
                    noteToDelete: Binding(
                        get: { panelInteraction.noteToDelete },
                        set: { panelInteraction.noteToDelete = $0 }
                    ),
                    fileToDelete: Binding(
                        get: { panelInteraction.fileToDelete },
                        set: { panelInteraction.fileToDelete = $0 }
                    ),
                    panelWidth: settings.panelWidth
                )
```

- [ ] **Step 5: Update `PanelContentView` struct signature**

Edit the struct (around line 938):

```swift
// Before:
struct PanelContentView: View {
    var makePanelKey: () -> Void
    @ObservedObject var fileDropStorage: FileDropStorage
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var notesStorage: NotesStorage
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var panelInteraction: PanelInteractionState
    @Binding var showTranscriptionPage: Bool

// After:
struct PanelContentView: View {
    var makePanelKey: () -> Void
    @ObservedObject var fileDropStorage: FileDropStorage
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var notesStorage: NotesStorage
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var panelInteraction: PanelInteractionState
    @ObservedObject var fileSelection: FileSelectionState
    @ObservedObject var fileGridHover: FileGridHoverState
    @ObservedObject var fileQuickLook: FileQuickLookController
    @Binding var showTranscriptionPage: Bool
```

- [ ] **Step 6: Close Quick Look and drop the key monitor SYNCHRONOUSLY before the slide-out**

Ordering matters: if QL closes inside the animation completion handler, QL remains frontmost for ~250ms while Stash's panel is already sliding away, and a spacebar press during that window could retrigger the monitor. Close QL and remove the monitor as the FIRST action in `hidePanel`, before the animation starts. The selection state wipe can stay in the completion handler (visual-only).

Edit `hidePanel()` (line 763):

```swift
// Before:
    func hidePanel() {
        guard let panel = contentPanel, panel.isVisible else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            ...
        }, completionHandler: { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.transcriptionFloatingWidget.setPanelOpenForWidget(false)
            self.stopClickOutsideMonitor()
            self.idleTimer?.invalidate()
            self.idleTimer = nil
        })
    }

// After:
    func hidePanel() {
        guard let panel = contentPanel, panel.isVisible else { return }

        // Quick Look and the key monitor must go BEFORE the animation — otherwise
        // QL lingers on-screen for ~250ms after the slide-out starts, and a
        // spacebar press during that window can retrigger the monitor.
        fileQuickLook.closeQuickLookIfVisible()
        fileQuickLook.removeKeyMonitor()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            ...
        }, completionHandler: { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.transcriptionFloatingWidget.setPanelOpenForWidget(false)
            self.stopClickOutsideMonitor()
            self.idleTimer?.invalidate()
            self.idleTimer = nil
            // State wipe comes last: UI is already gone, nothing else to see.
            self.fileQuickLook.clearSelection()
        })
    }
```

- [ ] **Step 7: Build**

Run: `xcodebuild -scheme Stash -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. The app now compiles with the controller plumbed through; nothing visual has changed yet.

- [ ] **Step 8: Commit**

```bash
git add Stash/PanelController.swift
git commit -m "feat(files): plumb FileQuickLookController + shared selection through panel tree"
```

---

## Task 4: Accept shared selection state in FileDropListContent (Files tab)

**Files:**
- Modify: `Stash/FileDropZoneView.swift:103-197`

Replace `FileDropListContent`'s local `@StateObject` instances with external bindings. Also publish the current column count via a new callback so `FileQuickLookController` can use it for grid navigation.

- [ ] **Step 1: Swap `@StateObject` for external observed objects**

Edit `Stash/FileDropZoneView.swift` around line 103:

```swift
// Before:
struct FileDropListContent: View {
    @ObservedObject var storage: FileDropStorage
    var onRequestDelete: (DroppedFileItem) -> Void
    var maxItems: Int? = nil

    @StateObject private var selection = FileSelectionState()
    @StateObject private var gridHover = FileGridHoverState()

// After:
struct FileDropListContent: View {
    @ObservedObject var storage: FileDropStorage
    var onRequestDelete: (DroppedFileItem) -> Void
    var maxItems: Int? = nil
    @ObservedObject var selection: FileSelectionState
    @ObservedObject var gridHover: FileGridHoverState
    @ObservedObject var fileQuickLook: FileQuickLookController
```

- [ ] **Step 2: Publish the live column count into `fileQuickLook` via `.onChange`**

The column count drives grid arrow navigation. Writing it through a `@State` captured in a closure is broken (the closure sees stale values and SwiftUI's `let _ = { ... }()` side-effect hack triggers "Modifying state during view update" warnings). Instead, compute `cols` from the current width and push it into the controller directly — once on appear, again on width change.

Replace the current `body`:

```swift
// Before:
    var body: some View {
        Group {
            if storage.files.isEmpty {
                ...
            } else {
                GeometryReader { geo in
                    fileGrid(availableWidth: geo.size.width)
                }
            }
        }
    }

// After:
    var body: some View {
        Group {
            if storage.files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 32))
                        .foregroundColor(Color(NSColor.placeholderTextColor))
                    Text("Drop files here")
                        .font(.subheadline)
                        .foregroundColor(Color(NSColor.placeholderTextColor))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
            } else {
                GeometryReader { geo in
                    fileGrid(availableWidth: geo.size.width)
                        .onAppear {
                            fileQuickLook.currentColumns =
                                numColumns(for: geo.size.width - outerPadding * 2)
                        }
                        .onChange(of: geo.size.width) { newWidth in
                            fileQuickLook.currentColumns =
                                numColumns(for: newWidth - outerPadding * 2)
                        }
                }
            }
        }
    }
```

Do NOT introduce `@State lastKnownColumns`. `fileGrid(availableWidth:)` keeps its current body — no side-effect hack.

- [ ] **Step 3: Update the `FileDropCardRepresentable` call site with the new `onPlainSelect` callback**

Inside `fileGrid`, modify the `FileDropCardRepresentable(...)` call (around line 170). Task 7 will add the `isQuickLookSelected` param and `onPlainSelect` closure in full; for now pass placeholders so this task still compiles:

```swift
// After (transitional — Task 7 finalizes):
                        FileDropCardRepresentable(
                            storage: storage,
                            item: item,
                            fileURL: storage.fileURL(for: item),
                            exists: storage.fileExists(item),
                            relativeTime: fileDropRelativeTime(since: item.dateDropped),
                            isNewlyAdded: storage.newlyAddedIDs.contains(item.id),
                            isSelected: selection.isSelected(item.id),
                            isQuickLookSelected: fileQuickLook.selectedFileID == item.id,
                            selection: selection,
                            hoverState: gridHover,
                            onTap: {
                                if storage.fileExists(item) { storage.openFile(item) }
                            },
                            onPlainSelect: { [weak fileQuickLook, storage] in
                                guard let fileQuickLook else { return }
                                let source = FileSelectionSource(
                                    id: "filesTab",
                                    storage: storage,
                                    itemsProvider: { storage.files },
                                    layout: .grid
                                )
                                fileQuickLook.select(item.id, from: source)
                            },
                            onRequestDelete: { onRequestDelete(item) },
                            onDragSessionEnded: {
                                storage.handleDragOutSessionEnded(item: item, operation: $0)
                            }
                        )
                        .frame(width: cardW, height: 88)
```

Note: `FileDropCardRepresentable` does not yet accept `isQuickLookSelected` or `onPlainSelect`. This file will not compile until Task 7 completes — that's expected; commit of this task comes after Task 7 to keep the build green. (See combined commit at end of Task 7.)

- [ ] **Step 4: Do NOT commit yet**

This task's edits must land together with Task 7's representable changes for the build to pass. Hold off on the commit.

---

## Task 5: Thread shared selection into AllCombinedView (All tab)

**Files:**
- Modify: `Stash/PanelSharedSections.swift:890-906`

Replace the local `@StateObject` instances in `AllCombinedView` with external ones. Update the single call site in `PanelController.swift`.

- [ ] **Step 1: Update `AllCombinedView` struct**

Edit `Stash/PanelSharedSections.swift` around line 890:

```swift
// Before:
struct AllCombinedView: View {
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var notesStorage: NotesStorage
    @ObservedObject var fileDropStorage: FileDropStorage
    @Binding var fileToDelete: DroppedFileItem?
    var makePanelKey: () -> Void
    @ObservedObject var transcription: TranscriptionService
    @Binding var showTranscriptionPage: Bool
    @Binding var editingNoteId: String?
    @Binding var noteToDelete: NoteItem?
    var switchToNotesTab: () -> Void = {}

    @StateObject private var fileSelection = FileSelectionState()
    @StateObject private var fileGridHover = FileGridHoverState()

// After:
struct AllCombinedView: View {
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var notesStorage: NotesStorage
    @ObservedObject var fileDropStorage: FileDropStorage
    @Binding var fileToDelete: DroppedFileItem?
    var makePanelKey: () -> Void
    @ObservedObject var transcription: TranscriptionService
    @Binding var showTranscriptionPage: Bool
    @Binding var editingNoteId: String?
    @Binding var noteToDelete: NoteItem?
    var switchToNotesTab: () -> Void = {}

    @ObservedObject var fileSelection: FileSelectionState
    @ObservedObject var fileGridHover: FileGridHoverState
    @ObservedObject var fileQuickLook: FileQuickLookController
```

- [ ] **Step 2: Update the `FileDropCardRepresentable` call in the Recent Files row**

Edit the call site in `AllCombinedView` (around line 957):

```swift
// After (transitional — Task 7 finalizes):
                                    FileDropCardRepresentable(
                                        storage: fileDropStorage,
                                        item: file,
                                        fileURL: fileDropStorage.fileURL(for: file),
                                        exists: fileDropStorage.fileExists(file),
                                        relativeTime: fileDropRelativeTime(since: file.dateDropped),
                                        isNewlyAdded: fileDropStorage.newlyAddedIDs.contains(file.id),
                                        isSelected: fileSelection.isSelected(file.id),
                                        isQuickLookSelected: fileQuickLook.selectedFileID == file.id,
                                        selection: fileSelection,
                                        hoverState: fileGridHover,
                                        onTap: {
                                            if fileDropStorage.fileExists(file) { fileDropStorage.openFile(file) }
                                        },
                                        onPlainSelect: { [weak fileQuickLook, fileDropStorage] in
                                            guard let fileQuickLook else { return }
                                            let source = FileSelectionSource(
                                                id: "allTabRecent",
                                                storage: fileDropStorage,
                                                itemsProvider: { Array(fileDropStorage.files.prefix(12)) },
                                                layout: .horizontalRow
                                            )
                                            fileQuickLook.select(file.id, from: source)
                                        },
                                        onRequestDelete: { fileToDelete = file },
                                        onDragSessionEnded: {
                                            fileDropStorage.handleDragOutSessionEnded(item: file, operation: $0)
                                        }
                                    )
                                    .frame(width: fileCardWidth, height: fileCardHeight)
```

- [ ] **Step 3: Update the `AllCombinedView(...)` call in PanelController**

Edit `Stash/PanelController.swift` around line 994:

```swift
// Before:
                                    AllCombinedView(
                                        clipboard: clipboard,
                                        notesStorage: notesStorage,
                                        fileDropStorage: fileDropStorage,
                                        fileToDelete: $fileToDelete,
                                        makePanelKey: makePanelKey,
                                        transcription: transcription,
                                        showTranscriptionPage: $showTranscriptionPage,
                                        editingNoteId: $editingNoteId,
                                        noteToDelete: $noteToDelete,
                                        switchToNotesTab: { selectedTab = .notes }
                                    )

// After:
                                    AllCombinedView(
                                        clipboard: clipboard,
                                        notesStorage: notesStorage,
                                        fileDropStorage: fileDropStorage,
                                        fileToDelete: $fileToDelete,
                                        makePanelKey: makePanelKey,
                                        transcription: transcription,
                                        showTranscriptionPage: $showTranscriptionPage,
                                        editingNoteId: $editingNoteId,
                                        noteToDelete: $noteToDelete,
                                        switchToNotesTab: { selectedTab = .notes },
                                        fileSelection: fileSelection,
                                        fileGridHover: fileGridHover,
                                        fileQuickLook: fileQuickLook
                                    )
```

Also update the `SharedFilesColumn(...)` call site (line 1020) — see Task 6 for the `.files` tab wiring.

- [ ] **Step 4: Do NOT commit yet**

Still waiting on Task 7. Keep the edits local.

---

## Task 6: Thread shared selection into SharedFilesColumn

**Files:**
- Modify: `Stash/PanelSharedSections.swift` (SharedFilesColumn), `Stash/PanelController.swift` (call sites), `Stash/CardsModeAppKit.swift` (cards-mode call site)

`SharedFilesColumn` hosts the Files tab's grid by wrapping `FileDropListContent`. It must accept and forward the three shared objects.

- [ ] **Step 1: Find `SharedFilesColumn` and update its signature**

Run: `grep -n "struct SharedFilesColumn" Stash/PanelSharedSections.swift` — open the struct and add the three parameters to its `var` list. Pass them into the `FileDropListContent(...)` call inside its body. Example shape:

```swift
// Add to struct:
    @ObservedObject var fileSelection: FileSelectionState
    @ObservedObject var fileGridHover: FileGridHoverState
    @ObservedObject var fileQuickLook: FileQuickLookController

// In body, update the FileDropListContent(...) call:
    FileDropListContent(
        storage: fileDropStorage,
        onRequestDelete: { item in fileToDelete = item },
        maxItems: ...existing...,
        selection: fileSelection,
        gridHover: fileGridHover,
        fileQuickLook: fileQuickLook
    )
```

- [ ] **Step 2: Update panel-mode call site**

Edit `Stash/PanelController.swift` line 1020:

```swift
// Before:
                        case .files:
                            SharedFilesColumn(
                                fileDropStorage: fileDropStorage,
                                fileToDelete: $fileToDelete,
                                forCardsMode: false
                            )

// After:
                        case .files:
                            SharedFilesColumn(
                                fileDropStorage: fileDropStorage,
                                fileToDelete: $fileToDelete,
                                forCardsMode: false,
                                fileSelection: fileSelection,
                                fileGridHover: fileGridHover,
                                fileQuickLook: fileQuickLook
                            )
```

Also update the `FileDropZoneRepresentable` fallback for `.clipboard` / `.notes` tabs? No — those do not render file cards directly; they only route drops. Leave them alone.

- [ ] **Step 3: Extend `CardsFilesRoot` with the three shared objects**

Edit `Stash/CardsModeAppKit.swift` `CardsFilesRoot` struct (line 99):

```swift
// Before:
private struct CardsFilesRoot: View {
    @ObservedObject var fileStorage: FileDropStorage
    @ObservedObject var interaction: PanelInteractionState

    var body: some View {
        SharedFilesColumn(
            fileDropStorage: fileStorage,
            fileToDelete: Binding(
                get: { interaction.fileToDelete },
                set: { interaction.fileToDelete = $0 }
            ),
            forCardsMode: true,
            maxFileItems: 4
        )
        ...

// After:
private struct CardsFilesRoot: View {
    @ObservedObject var fileStorage: FileDropStorage
    @ObservedObject var interaction: PanelInteractionState
    @ObservedObject var fileSelection: FileSelectionState
    @ObservedObject var fileGridHover: FileGridHoverState
    @ObservedObject var fileQuickLook: FileQuickLookController

    var body: some View {
        SharedFilesColumn(
            fileDropStorage: fileStorage,
            fileToDelete: Binding(
                get: { interaction.fileToDelete },
                set: { interaction.fileToDelete = $0 }
            ),
            forCardsMode: true,
            maxFileItems: 4,
            fileSelection: fileSelection,
            fileGridHover: fileGridHover,
            fileQuickLook: fileQuickLook
        )
        ...
```

- [ ] **Step 4: Extend `CardsModeContainerView.init`**

Edit `Stash/CardsModeAppKit.swift` (line 601):

```swift
// Before:
    init(
        clipboard: ClipboardManager,
        notes: NotesStorage,
        fileStorage: FileDropStorage,
        interaction: PanelInteractionState,
        transcription: TranscriptionService,
        makePanelKey: @escaping () -> Void,
        panelController: PanelController
    ) {
        super.init(frame: .zero)
        ...
        let filesRoot = AnyView(CardsFilesRoot(fileStorage: fileStorage, interaction: interaction))

// After:
    init(
        clipboard: ClipboardManager,
        notes: NotesStorage,
        fileStorage: FileDropStorage,
        interaction: PanelInteractionState,
        transcription: TranscriptionService,
        makePanelKey: @escaping () -> Void,
        panelController: PanelController,
        fileSelection: FileSelectionState,
        fileGridHover: FileGridHoverState,
        fileQuickLook: FileQuickLookController
    ) {
        super.init(frame: .zero)
        ...
        let filesRoot = AnyView(CardsFilesRoot(
            fileStorage: fileStorage,
            interaction: interaction,
            fileSelection: fileSelection,
            fileGridHover: fileGridHover,
            fileQuickLook: fileQuickLook
        ))
```

- [ ] **Step 5: Extend the `CardsModeContainerView` call in `PanelController.createContentPanel()`**

Edit `Stash/PanelController.swift` (line 524):

```swift
// Before:
        let cardsView = CardsModeContainerView(
            clipboard: clipboardManager,
            notes: notesStorage,
            fileStorage: fileDropStorage,
            interaction: panelInteractionState,
            transcription: transcriptionService,
            makePanelKey: { [weak self] in
                self?.contentPanel?.makeKeyAndOrderFront(nil)
            },
            panelController: self
        )

// After:
        let cardsView = CardsModeContainerView(
            clipboard: clipboardManager,
            notes: notesStorage,
            fileStorage: fileDropStorage,
            interaction: panelInteractionState,
            transcription: transcriptionService,
            makePanelKey: { [weak self] in
                self?.contentPanel?.makeKeyAndOrderFront(nil)
            },
            panelController: self,
            fileSelection: fileSelection,
            fileGridHover: fileGridHover,
            fileQuickLook: fileQuickLook
        )
```

**Note on cards-mode QL behavior:** because cards mode receives the same shared instances as panel mode, spacebar + QL work there too — selection is one source of truth across both layouts. That's a free win; no extra guard required.

- [ ] **Step 4: Do NOT commit yet**

Still joined with Task 7.

---

## Task 7: Add QL-selection to FileDropCardRepresentable and card visual

**Files:**
- Modify: `Stash/FileDropZoneView.swift:199-446` (FileDropCardContentView), `:450-845` (DraggableFileView), `:848-930` (FileDropCardRepresentable)

Add the visual ring and the selection callback plumbing. This closes the loop for Tasks 4–6 so the build goes green.

- [ ] **Step 1: Add `isQuickLookSelected` state to `FileDropCardContentView`**

Edit around line 208:

```swift
// Before:
    private var fileExists = true
    private var isHovering = false
    private var isSelected = false
    private var thumbnailRequestID = UUID()

// After:
    private var fileExists = true
    private var isHovering = false
    private var isSelected = false
    private var isQuickLookSelected = false
    private var thumbnailRequestID = UUID()
```

- [ ] **Step 2: Add `setQuickLookSelected` method**

Add immediately after `setSelected(_:)` (around line 320):

```swift
    func setQuickLookSelected(_ active: Bool) {
        guard isQuickLookSelected != active else { return }
        isQuickLookSelected = active
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            updateHoverAppearance()
        }
    }
```

- [ ] **Step 3: Extend `updateHoverAppearance` to render the blue ring**

Edit the method (line 423):

```swift
// Before:
    private func updateHoverAppearance() {
        guard let layer else { return }
        if isSelected {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        } else if isHovering {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
        }
    }

// After:
    private func updateHoverAppearance() {
        guard let layer else { return }
        if isSelected {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        } else if isHovering {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
        }

        // Blue ring overlays the fill when this is the Quick-Look-focused file.
        if isQuickLookSelected {
            layer.borderWidth = 1.5
            layer.borderColor = NSColor.systemBlue.cgColor
        } else {
            layer.borderWidth = 0
            layer.borderColor = NSColor.clear.cgColor
        }
    }
```

- [ ] **Step 4: Wire up `onPlainSelect` on `DraggableFileView`**

Edit around line 460:

```swift
// Before:
    var onTap: (() -> Void)?
    var onRequestDelete: (() -> Void)?
    var onDragSessionEnded: ((NSDragOperation) -> Void)?

// After:
    var onTap: (() -> Void)?
    /// Fired on a plain click (no shift/cmd). Used to set the Quick-Look-focused file.
    var onPlainSelect: (() -> Void)?
    var onRequestDelete: (() -> Void)?
    var onDragSessionEnded: ((NSDragOperation) -> Void)?
```

- [ ] **Step 5: Call `onPlainSelect` from `mouseUp`**

Edit `mouseUp` (line 592):

```swift
// Before:
        if !wasModifierSelect {
            selection?.selectOnly(item.id)
        }

// After:
        if !wasModifierSelect {
            selection?.selectOnly(item.id)
            onPlainSelect?()
        }
```

- [ ] **Step 6: Remove the transient selection wipe in `mouseExited`**

Edit `mouseExited` (line 530):

```swift
// Before:
    override func mouseExited(with event: NSEvent) {
        if gridHoverState?.hoveredFileID == item.id {
            gridHoverState?.hoveredFileID = nil
        }
        // Clear selected appearance when the pointer leaves, unless Shift is held (multi-select).
        // Skip while a drag is active so selection isn't wiped mid–drag session.
        guard !dragSessionStarted else { return }
        guard !event.modifierFlags.contains(.shift) else { return }
        if selection?.isSelected(item.id) == true {
            selection?.removeFromSelection(item.id)
        }
    }

// After:
    override func mouseExited(with event: NSEvent) {
        if gridHoverState?.hoveredFileID == item.id {
            gridHoverState?.hoveredFileID = nil
        }
        // Selection is now sticky (spec: clears only on outside-click, tab switch, or panel hide).
        // Do not wipe on mouse exit.
    }
```

- [ ] **Step 7: Update `FileDropCardRepresentable` to accept `isQuickLookSelected` + `onPlainSelect`**

Edit around line 854:

```swift
// Before:
struct FileDropCardRepresentable: NSViewRepresentable {
    @ObservedObject var storage: FileDropStorage
    let item: DroppedFileItem
    let fileURL: URL
    let exists: Bool
    let relativeTime: String
    let isNewlyAdded: Bool
    var isSelected: Bool
    var selection: FileSelectionState
    @ObservedObject var hoverState: FileGridHoverState
    var onTap: () -> Void
    var onRequestDelete: () -> Void
    var onDragSessionEnded: (NSDragOperation) -> Void

// After:
struct FileDropCardRepresentable: NSViewRepresentable {
    @ObservedObject var storage: FileDropStorage
    let item: DroppedFileItem
    let fileURL: URL
    let exists: Bool
    let relativeTime: String
    let isNewlyAdded: Bool
    var isSelected: Bool
    var isQuickLookSelected: Bool
    var selection: FileSelectionState
    @ObservedObject var hoverState: FileGridHoverState
    var onTap: () -> Void
    var onPlainSelect: () -> Void
    var onRequestDelete: () -> Void
    var onDragSessionEnded: (NSDragOperation) -> Void
```

- [ ] **Step 8: Forward `onPlainSelect` in `makeNSView` and `updateNSView`**

Edit `makeNSView` (line 878):

```swift
// Before:
    func makeNSView(context: Context) -> DraggableFileView {
        let v = DraggableFileView(...)
        v.fileDropStorage    = storage
        v.selection          = selection
        v.gridHoverState     = hoverState
        v.onTap              = onTap
        v.onRequestDelete    = onRequestDelete
        v.onDragSessionEnded = onDragSessionEnded
        ...

// After:
    func makeNSView(context: Context) -> DraggableFileView {
        let v = DraggableFileView(...)
        v.fileDropStorage    = storage
        v.selection          = selection
        v.gridHoverState     = hoverState
        v.onTap              = onTap
        v.onPlainSelect      = onPlainSelect
        v.onRequestDelete    = onRequestDelete
        v.onDragSessionEnded = onDragSessionEnded
        ...
```

And edit `updateNSView` (line 897):

```swift
// Before:
    func updateNSView(_ nsView: DraggableFileView, context: Context) {
        nsView.fileDropStorage    = storage
        nsView.selection          = selection
        nsView.gridHoverState     = hoverState
        nsView.onTap              = onTap
        nsView.onRequestDelete    = onRequestDelete
        nsView.onDragSessionEnded = onDragSessionEnded
        ...

        nsView.cardContent.setSelected(isSelected)
        nsView.cardContent.setCardHover(hoverState.hoveredFileID == item.id)
    }

// After:
    func updateNSView(_ nsView: DraggableFileView, context: Context) {
        nsView.fileDropStorage    = storage
        nsView.selection          = selection
        nsView.gridHoverState     = hoverState
        nsView.onTap              = onTap
        nsView.onPlainSelect      = onPlainSelect
        nsView.onRequestDelete    = onRequestDelete
        nsView.onDragSessionEnded = onDragSessionEnded
        ...

        nsView.cardContent.setSelected(isSelected)
        nsView.cardContent.setQuickLookSelected(isQuickLookSelected)
        nsView.cardContent.setCardHover(hoverState.hoveredFileID == item.id)
    }
```

Also update `dismantleNSView` (line 922) to clear `onPlainSelect`:

```swift
// Add this line:
        nsView.onPlainSelect = nil
```

- [ ] **Step 9: Build**

Run: `xcodebuild -scheme Stash -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

If build fails, expected errors are a missing call-site argument somewhere — fix them all by propagating `fileSelection`, `fileGridHover`, `fileQuickLook` through the chain until the compiler is quiet.

- [ ] **Step 10: Manual smoke test**

1. Launch app, show panel
2. Drop a file into the Files tab
3. Click the thumbnail — a blue 1.5pt ring should appear
4. Move mouse off — ring persists
5. Click empty area of panel — ring clears
6. Switch tab → back — ring does not reappear (spec: start fresh)

- [ ] **Step 11: Commit Tasks 4–7 together**

```bash
git add Stash/FileDropZoneView.swift Stash/PanelSharedSections.swift Stash/PanelController.swift Stash/CardsModeAppKit.swift
git commit -m "feat(files): single-source file selection + Quick-Look-focused blue ring"
```

---

## Task 8: Clear QL selection on tab switch + click outside grid

**Files:**
- Modify: `Stash/PanelController.swift` (PanelContentView)

`PanelContentView` observes its `selectedTab` and clears the QL selection whenever it changes. A transparent background tap on the panel's `ZStack` (outside any card) also clears selection.

- [ ] **Step 1: Clear on tab change**

Edit `PanelContentView.body` (around line 1056) — extend the existing `.onChange`:

```swift
// Before:
            .onChange(of: panelInteraction.requestedTab) { tab in
                guard let tab else { return }
                selectedTab = tab
                panelInteraction.requestedTab = nil
            }

// After:
            .onChange(of: panelInteraction.requestedTab) { tab in
                guard let tab else { return }
                selectedTab = tab
                panelInteraction.requestedTab = nil
            }
            .onChange(of: selectedTab) { _ in
                fileQuickLook.clearSelection()
            }
```

- [ ] **Step 2: Clear on click outside the grid (still inside the panel)**

Per spec, clicking the panel's empty area (not a card, not a control) clears the selection. The outer `Color.black` behind the content (line 955) is the cheapest attach point. Add a `.contentShape(Rectangle())` + `.onTapGesture` that clears selection. Only the `Color.black` layer will receive this — cards and scroll views consume their own taps.

Edit `PanelContentView.body`:

```swift
// Before:
        ZStack {
            Color.black
            VStack(spacing: 0) {

// After:
        ZStack {
            Color.black
                .contentShape(Rectangle())
                .onTapGesture { fileQuickLook.clearSelection() }
            VStack(spacing: 0) {
```

- [ ] **Step 3: Build + smoke test**

Run: `xcodebuild -scheme Stash -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

Manual test:
1. Select a file in Files tab → ring shows
2. Click empty black area inside panel → ring clears
3. Re-select a file → switch to All tab → back to Files tab → ring is NOT present (spec: start fresh)
4. Re-select a file → switch tab → ring clears; QL (not yet implemented) won't be open

- [ ] **Step 4: Commit**

```bash
git add Stash/PanelController.swift
git commit -m "feat(files): clear Quick-Look focus on tab switch + outside-grid click"
```

---

## Task 9: Implement local key monitor + spacebar → Quick Look

**Files:**
- Modify: `Stash/FileQuickLookController.swift`, `Stash/PanelController.swift`

Add the `NSEvent.addLocalMonitorForEvents` monitor. On spacebar keyDown, if a file is selected AND no text input is focused AND QL is closed → open QL. If QL is open → close it. Consume (return nil) only when we acted.

- [ ] **Step 1: Add monitor install/remove to `FileQuickLookController`**

Edit `Stash/FileQuickLookController.swift` — add these at the bottom of the class:

```swift
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
        case 123, 124, 125, 126: // left, right, down, up — filled in Task 10
            return false
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
```

- [ ] **Step 2: Fill in the Quick Look methods**

Replace the three stub methods in the controller with real implementations:

```swift
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
        guard selectedURL != nil else { return }
        let panel = QLPreviewPanel.shared()
        panel?.dataSource = self
        panel?.delegate = self
        panel?.reloadData()
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
```

- [ ] **Step 3: Add QLPreviewPanelDataSource conformance (delegate added in Task 11)**

Append outside the class (still in `FileQuickLookController.swift`):

```swift
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
    func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Defensive — QL is tearing down its control of us.
    }
}

// MARK: - QLPreviewPanelDelegate (arrow navigation filled in Task 11)

extension FileQuickLookController: QLPreviewPanelDelegate { }
```

- [ ] **Step 4: Open QL at the correct initial index**

QL reads `currentPreviewItemIndex` to decide which item to show first. Before showing QL, set the index to the selected file's position in the source.

Update `openQuickLook()`:

```swift
// Before:
    func openQuickLook() {
        guard selectedURL != nil else { return }
        let panel = QLPreviewPanel.shared()
        panel?.dataSource = self
        panel?.delegate = self
        panel?.reloadData()
        panel?.makeKeyAndOrderFront(nil)
    }

// After:
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
```

- [ ] **Step 5: Install the key monitor when the panel shows**

Edit `showPanel()` in `Stash/PanelController.swift` — add the install just before `resetPanelIdleTimer()` at the end (line 760). No delay needed: `NSApp.activate(ignoringOtherApps: true)` has already run at the top of `showPanel`, so the local monitor will fire for our process.

```swift
// Before:
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            guard self.contentPanel?.isVisible ?? false else { return }
            self.startClickOutsideMonitor()
        }
        resetPanelIdleTimer()
    }

// After:
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            guard self.contentPanel?.isVisible ?? false else { return }
            self.startClickOutsideMonitor()
        }
        if let panel = contentPanel {
            fileQuickLook.installKeyMonitor(on: panel)
        }
        resetPanelIdleTimer()
    }
```

`hidePanel()` already removes the monitor synchronously (Task 3 Step 6). Nothing else to add here.

- [ ] **Step 6: Close QL when recording starts**

Recording hides the panel (existing behavior, line 473-477). When the panel hides, `fileQuickLook.clearSelection()` already closes QL — so recording is already handled transitively. No new code needed.

- [ ] **Step 7: Build**

Run: `xcodebuild -scheme Stash -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Manual test matrix**

1. Select a file in Files tab → press space → QL opens showing that file
2. Press space again → QL closes
3. Open notes editor, type — space inserts a space (QL does NOT trigger)
4. Press space with no file selected → nothing happens
5. Press space in All tab after selecting a Recent Files thumbnail → QL opens
6. Open QL → hide panel via hotkey → QL closes alongside
7. Open QL → start a recording → panel hides → QL closes

- [ ] **Step 9: Commit**

```bash
git add Stash/FileQuickLookController.swift Stash/PanelController.swift
git commit -m "feat(files): spacebar toggles Quick Look for the focused file"
```

---

## Task 10: Implement arrow key navigation

**Files:**
- Modify: `Stash/FileQuickLookController.swift`

Handle arrow keys inside `handleLocalKeyEvent`. The grid / horizontal-row semantics already live in `moveSelection(_:)` from Task 2.

- [ ] **Step 1: Replace the arrow-key stub branch**

Per spec, up/down in `.horizontalRow` layout is a no-op BUT the event must still be consumed so it never reaches the desktop. Easiest: always consume arrow keys when a file is selected (`moveSelection` already no-ops for unsupported directions, so there's no ambiguity).

Edit `handleLocalKeyEvent` in `FileQuickLookController.swift`:

```swift
// Before:
        case 123, 124, 125, 126: // left, right, down, up — filled in Task 10
            return false

// After:
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
```

- [ ] **Step 2: Build + smoke test**

Run: `xcodebuild -scheme Stash -configuration Debug -destination 'platform=macOS' build`

Manual test:
1. Files tab, select a file in row 1 col 2 → press right → col 3 selected. Right again → col 4 (or clamps).
2. Left at col 1 → clamps (does not escape).
3. Down → row 2 same col. Up at row 1 → clamps.
4. All tab Recent Files row, select a file → left/right navigate. Up/down does nothing but also doesn't leak — verify by pressing Up while your desktop is visible: no change-of-wallpaper focus, no Spotlight, no Mission Control.
5. Background Stash (cmd-tab) → QL/selection still held → foreground — selection persists or was cleared when panel hid (depends on hide trigger).

- [ ] **Step 3: Commit**

```bash
git add Stash/FileQuickLookController.swift
git commit -m "feat(files): arrow-key navigation for Quick-Look focus; never leaks to desktop"
```

---

## Task 11: Arrow keys + space inside Quick Look

**Files:**
- Modify: `Stash/FileQuickLookController.swift`

When QL is open, our local keyDown monitor does not see the events (QL is key). Implement the QLPreviewPanelDelegate method `previewPanel(_:handle:)` to catch arrows and space inside QL.

- [ ] **Step 1: Replace the empty delegate extension**

Edit the `QLPreviewPanelDelegate` extension at the bottom:

```swift
// Before:
extension FileQuickLookController: QLPreviewPanelDelegate { }

// After:
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
```

- [ ] **Step 2: Add `syncQuickLookIndex` helper**

Add to the main class:

```swift
    /// After our selection moves, tell QL which index to display.
    private func syncQuickLookIndex() {
        guard isQuickLookVisible,
              let id = selectedFileID,
              let source = currentSource,
              let index = source.itemsProvider().firstIndex(where: { $0.id == id }) else { return }
        QLPreviewPanel.shared().currentPreviewItemIndex = index
    }
```

- [ ] **Step 3: Build + smoke test**

Run: `xcodebuild -scheme Stash -configuration Debug -destination 'platform=macOS' build`

Manual test:
1. Select file, press space → QL opens
2. Press right → QL advances to next file AND when you close QL, Stash ring is on the new file
3. Press up/down (Files tab grid) → QL moves by row stride
4. Press space in QL → QL closes, ring remains on current file
5. All tab Recent Files: open QL → up/down is a no-op inside QL (clamp)

- [ ] **Step 4: Commit**

```bash
git add Stash/FileQuickLookController.swift
git commit -m "feat(files): keep Quick Look and Stash selection in sync during QL navigation"
```

---

## Task 12: Reconcile with storage edits

**Files:**
- Modify: `Stash/FileQuickLookController.swift`, `Stash/PanelController.swift`

If the focused file is deleted from storage (via × button or right-click menu), selection must clear gracefully and QL (if showing that file) must close.

- [ ] **Step 1: Observe FileDropStorage.files**

`FileDropStorage` already publishes `files` via `@Published`. Subscribe in `PanelController.setup()` — not in the controller, because the controller doesn't own the storage reference.

Edit `Stash/PanelController.swift` `setup()` (around line 460). Add after the existing transcription `sink` (before `createContentPanel()`):

```swift
        // When a file is removed from storage, clear the QL focus if it was pointing there.
        fileDropStorage.$files
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.fileQuickLook.reconcileWithStorage()
            }
            .store(in: &cancellables)
```

(`reconcileWithStorage()` was added in Task 2.)

- [ ] **Step 2: Build + smoke test**

Run: `xcodebuild -scheme Stash -configuration Debug -destination 'platform=macOS' build`

Manual test:
1. Select file, open QL → press `×` on the card (or use right-click → Remove): file vanishes, ring clears, QL closes
2. Select last file in grid, delete it: selection clears cleanly (no crash)
3. Drop new files while a different file is selected: selection untouched

- [ ] **Step 3: Commit**

```bash
git add Stash/PanelController.swift
git commit -m "feat(files): clear Quick-Look focus when the focused file is removed"
```

---

## Task 13: Build, format, lint, simplify

**Files:** all modified

- [ ] **Step 1: Full release-config build**

Run: `xcodebuild -scheme Stash -configuration Debug -destination 'platform=macOS' clean build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: SwiftFormat + SwiftLint**

Run (if installed): `swiftformat Stash/FileQuickLookController.swift Stash/FileDropZoneView.swift Stash/PanelController.swift Stash/PanelSharedSections.swift Stash/CardsModeAppKit.swift`

Then: `swiftlint lint --path Stash/FileQuickLookController.swift Stash/FileDropZoneView.swift Stash/PanelController.swift Stash/PanelSharedSections.swift Stash/CardsModeAppKit.swift`

Fix any warnings.

- [ ] **Step 3: Run `/simplify`**

Review the diff with fresh eyes. Look for:
- Any `DispatchQueue.main.async` that should be `@MainActor` direct
- Any callback that could collapse
- Comments that state the obvious (delete them)
- Any edge case handling that duplicates Task 12's storage reconciliation

- [ ] **Step 4: Final manual acceptance pass (full spec)**

Run through every point in the original spec one by one. Note anything that differs and either fix it or document why.

- [ ] **Step 5: Commit any format/lint fixes**

```bash
git add -u
git commit -m "chore(files): format and lint Quick-Look-related files"
```

---

## Self-review checklist (run before handing off to execution)

- **Spec coverage:**
  - ✅ Hover state: already existed via `FileGridHoverState`; untouched
  - ✅ Active/selected state, persistent: Task 7 removes mouseExit wipe
  - ✅ Single selection across surfaces: Tasks 3–6 lift state to `PanelController`
  - ✅ Clear on outside-click / tab-switch / panel-hide: Tasks 3, 8
  - ✅ Spacebar toggle QL, text-input guard: Task 9
  - ✅ Arrow keys consumed, clamp, no desktop leak: Task 10
  - ✅ Arrow keys inside QL: Task 11
  - ✅ Storage reconciliation: Task 12
  - ✅ systemBlue ring 1.5pt: Task 7 Step 3
  - ✅ Grid columns: Task 4 publishes live column count into `fileQuickLook.currentColumns` via `.onChange(of: geo.size.width)`; Task 2's `moveSelection` reads it directly

- **Placeholder scan:** no TBD / TODO / fill-in-later remain in code blocks

- **Type consistency:**
  - `FileQuickLookController.select(_:from:)` — signature used consistently in Tasks 4, 5
  - `FileSelectionSource.Layout` — `.grid` and `.horizontalRow` (no associated values); controller reads `currentColumns` live
  - `onPlainSelect` — same name everywhere (struct field, NSView prop, closure param)
  - `isQuickLookSelected` — same name on content view + representable
  - `isTextInputActive` — renamed property; caller updated in Task 1 Step 2

- **Previously-broken patterns now fixed (per review pass):**
  - `@State lastKnownColumns` capture in a view-body closure → replaced with `.onChange(of: geo.size.width)` writing to `fileQuickLook.currentColumns`
  - QL close inside `hidePanel`'s animation completion handler → moved to SYNCHRONOUSLY BEFORE the slide-out
  - Missing QLPreviewPanelController protocol methods (`acceptsPreviewPanelControl`, `beginPreviewPanelControl:`, `endPreviewPanelControl:`) → added
  - Stale `QLPreviewPanel.shared().dataSource` / `.delegate` refs after close → nil'd with identity guard
  - 1–2 frame key-window gap after closing QL via in-QL space → `self.panel?.makeKeyAndOrderFront(nil)` restores Stash panel
  - `reconcileWithStorage` ordering → close QL first, then clear state (indices stay valid for any in-flight redraw)
  - `onPlainSelect` closure strong-capturing `fileQuickLook` into AppKit view → `[weak fileQuickLook]` everywhere
  - Xcode GUI "drag-the-file" step → replaced with `xcodeproj` Ruby snippet
  - Cards-mode threading hand-wave → concrete before/after for `CardsFilesRoot`, `CardsModeContainerView.init`, and `PanelController.swift:524`

- **Accepted-by-design behaviors:**
  - Cmd-Tabbing away keeps panel + selection visible (matches spec: only panel-hide clears). When Stash is not the active app, arrow keys route to the active app naturally — not a leak because they were never consumed by Stash in the first place.
  - Outside-click clearing is `Color.black.onTapGesture` only: scroll view empty areas inside the grid/row are part of the "grid surface" per spec and must NOT clear.
  - Re-clicking the already-selected file is a no-op (Q3 answer: C — sticky)
  - Blue border overlays the white multi-select fill (Q1 answer: B)
  - All editable text views suppress spacebar QL (Q2 answer: A)
  - Selection does NOT restore when returning to Files tab (Q4 answer: B — start fresh)

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-20-quick-look-preview.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
