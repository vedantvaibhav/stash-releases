import AppKit
import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Pasteboard types Finder and most apps advertise for filesystem drags.
private enum StashFileDragPasteboard {
    static let types: [NSPasteboard.PasteboardType] = {
        var t: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ]
        if #available(macOS 11.0, *) {
            let id = UTType.fileURL.identifier
            if !t.contains(NSPasteboard.PasteboardType(id)) {
                t.append(NSPasteboard.PasteboardType(id))
            }
        }
        return t
    }()
}

/// Shared drop chrome (matches earlier Stash style): thin border, soft icon tint, optional hint. No full-card dim layer.
enum ProminentExternalFileDragChrome {
    static let borderWidth: CGFloat = 2
    static let borderBlackAlpha: CGFloat = 0.80
    static let cornerRadius: CGFloat = 12
    static let iconSide: CGFloat = 32
    /// Prior upload state used ~60% white on the SF Symbol.
    static let iconTintAlpha: CGFloat = 0.60
    static let hintFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let hint = "Release to add files"
    static let symbolName = "tray.and.arrow.down.fill"
    /// Strong fade for list/grid behind the drop overlay (lower = fainter background items).
    static let filesColumnContentFade: CGFloat = 0.06
}

// MARK: - QuickLook thumbnails (Finder-like)

func generateThumbnail(for fileURL: URL, size: CGSize, completion: @escaping (NSImage?) -> Void) {
    let request = QLThumbnailGenerator.Request(
        fileAt: fileURL,
        size: size,
        scale: NSScreen.main?.backingScaleFactor ?? 2.0,
        representationTypes: .thumbnail
    )

    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
        DispatchQueue.main.async {
            if let thumb = thumbnail {
                completion(thumb.nsImage)
            } else {
                completion(NSWorkspace.shared.icon(forFile: fileURL.path))
            }
        }
    }
}

// MARK: - Relative time

func fileDropRelativeTime(since date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 60 { return "Just now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
    if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    if seconds < 86400 * 7 { return "\(Int(seconds / 86400))d ago" }
    let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none
    return f.string(from: date)
}

// MARK: - Multi-select state

final class FileSelectionState: ObservableObject {
    @Published var selectedIDs: Set<String> = []

    /// Shift/Cmd+click — add or remove from the multi-selection.
    func toggle(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }
    /// Regular click — select only this one, clear everything else.
    func selectOnly(_ id: String) {
        selectedIDs = [id]
    }
    func clear() { selectedIDs.removeAll() }

    func removeFromSelection(_ id: String) {
        selectedIDs.remove(id)
    }

    func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }
}

/// Only one file id may read as hovered at a time; avoids stale `isHovering` when `LazyVGrid` reuses `NSView`s.
final class FileGridHoverState: ObservableObject {
    @Published var hoveredFileID: String?
}

// MARK: - SwiftUI grid

struct FileDropListContent: View {
    @ObservedObject var storage: FileDropStorage
    var onRequestDelete: (DroppedFileItem) -> Void
    var maxItems: Int? = nil
    @ObservedObject var selection: FileSelectionState
    @ObservedObject var gridHover: FileGridHoverState
    @ObservedObject var fileQuickLook: FileQuickLookController

    private let rowSpacing: CGFloat = 8
    private let columnSpacing: CGFloat = 8
    private let outerPadding: CGFloat = 12
    private let minCardWidth: CGFloat = 60
    private let defaultCols = 4

    private var displayedFiles: [DroppedFileItem] {
        guard let cap = maxItems else { return storage.files }
        return Array(storage.files.prefix(cap))
    }

    var body: some View {
        Group {
            if storage.files.isEmpty {
                PanelEmptyState(
                    title: "No Files",
                    subtitle: "Drag and drop your files for quick access"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 20)
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

    private func numColumns(for width: CGFloat) -> Int {
        let w4 = (width - CGFloat(defaultCols - 1) * columnSpacing) / CGFloat(defaultCols)
        return w4 >= minCardWidth ? defaultCols : 3
    }

    @ViewBuilder
    private func fileGrid(availableWidth: CGFloat) -> some View {
        // Subtract left + right outer padding so cards never overflow.
        let contentWidth = availableWidth - outerPadding * 2
        let cols = numColumns(for: contentWidth)
        let cardW = (contentWidth - CGFloat(cols - 1) * columnSpacing) / CGFloat(cols)
        let gridItems = Array(repeating: GridItem(.fixed(cardW), spacing: columnSpacing), count: cols)

        VStack(alignment: .leading, spacing: 0) {
            if let msg = storage.lastDropErrorMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, outerPadding)
                    .padding(.top, 4)
            }

            // No .clipped() — it clips the top row of cards.
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: gridItems, alignment: .leading, spacing: rowSpacing) {
                    ForEach(displayedFiles) { item in
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
                    }
                }
                // Top + horizontal padding only — last row scrolls flush to panel bottom.
                .padding(.top, outerPadding)
                .padding(.horizontal, outerPadding)
            }
        }
    }
}

// MARK: - Card content view

final class FileDropCardContentView: NSView {
    fileprivate let deleteButton = NSButton()
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")

    private var fileExists = true
    private var isHovering = false
    private var isSelected = false
    private var isQuickLookSelected = false
    private var thumbnailRequestID = UUID()
    /// Skips redundant thumbnail reloads when SwiftUI re-renders (e.g. selection changes only).
    private var appliedContentSignature: String = ""

    private static let imageExtensions: Set<String> = ["png","jpg","jpeg","gif","webp","heic","tiff","bmp"]

    var onDelete: (() -> Void)?

    init(item: DroppedFileItem, fileURL: URL, exists: Bool, relativeTime: String) {
        self.fileExists = exists
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // 48×48 icon/thumbnail, centred, layer-backed for corner radius
        imageView.imageScaling = .scaleAxesIndependently   // fills 48×48 after we pre-crop
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        // SF Pro Regular 11px, white 85%, 2 lines, centred, max 64px wide
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        nameLabel.alignment = .center
        if #available(macOS 12.0, *) { nameLabel.maximumNumberOfLines = 2 }
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.cell?.wraps = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // Small × top-right, only on hover
        deleteButton.title = "×"
        deleteButton.font = NSFont.systemFont(ofSize: 14)
        deleteButton.contentTintColor = NSColor(white: 0.64, alpha: 1) // #A3A3A3
        deleteButton.bezelStyle = .texturedRounded
        deleteButton.isBordered = false
        deleteButton.alphaValue = 0
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(nameLabel)
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            // Icon: 48×48, 8pt from top, centred
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 48),
            imageView.heightAnchor.constraint(equalToConstant: 48),

            // Name: 4pt below icon, 6px inset each side, centred, 8pt from bottom
            nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),

            // × button: top-right corner
            deleteButton.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            deleteButton.widthAnchor.constraint(equalToConstant: 18),
            deleteButton.heightAnchor.constraint(equalToConstant: 18)
        ])

        applyContent(item: item, fileURL: fileURL, relativeTime: relativeTime)
        appliedContentSignature = Self.contentSignature(item: item, fileURL: fileURL, exists: exists)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func contentSignature(item: DroppedFileItem, fileURL: URL, exists: Bool) -> String {
        "\(item.id)|\(fileURL.path)|\(exists)"
    }

    func updateContent(item: DroppedFileItem, fileURL: URL, exists: Bool, relativeTime: String) {
        let sig = Self.contentSignature(item: item, fileURL: fileURL, exists: exists)
        guard sig != appliedContentSignature else { return }
        appliedContentSignature = sig
        thumbnailRequestID = UUID() // cancel any in-flight async load
        fileExists = exists
        applyContent(item: item, fileURL: fileURL, relativeTime: relativeTime)
    }

    func setCardHover(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        // Animate background at 0.1s — allowsImplicitAnimation lets CALayer interpolate the colour.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            updateHoverAppearance()
            deleteButton.animator().alphaValue = (hovering && fileExists) ? 1 : 0
        }
    }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            updateHoverAppearance()
        }
    }

    func setQuickLookSelected(_ active: Bool) {
        guard isQuickLookSelected != active else { return }
        isQuickLookSelected = active
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            updateHoverAppearance()
        }
    }

    /// Flashes the card background green for 0.4 s to indicate a successful drop.
    func flashGreen() {
        guard let layer else { return }
        let flash = CABasicAnimation(keyPath: "backgroundColor")
        flash.fromValue = NSColor.systemGreen.withAlphaComponent(0.35).cgColor
        flash.toValue   = layer.backgroundColor
        flash.duration  = 0.4
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(flash, forKey: "greenFlash")
    }

    private func applyContent(item: DroppedFileItem, fileURL: URL, relativeTime: String) {
        if fileExists {
            nameLabel.stringValue = item.fileName
            nameLabel.textColor = NSColor.white.withAlphaComponent(0.85)

            let ext = fileURL.pathExtension.lowercased()
            let isImage = Self.imageExtensions.contains(ext)

            if isImage {
                // Show Finder icon as placeholder while thumbnail loads
                let placeholder = NSWorkspace.shared.icon(forFile: fileURL.path)
                imageView.image = placeholder
                imageView.contentTintColor = nil
                imageView.layer?.cornerRadius = 0

                let requestID = UUID()
                thumbnailRequestID = requestID
                let url = fileURL

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    // Try direct NSImage load first; fall back to QL
                    let cropped: NSImage?
                    if let raw = NSImage(contentsOf: url) {
                        cropped = self?.cropToSquare(raw, size: 48)
                    } else {
                        cropped = nil
                    }

                    if let img = cropped {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.thumbnailRequestID == requestID else { return }
                            self.setThumbnail(img, isImage: true)
                        }
                    } else {
                        // QL fallback
                        generateThumbnail(for: url, size: CGSize(width: 96, height: 96)) { [weak self] thumb in
                            guard let self, self.thumbnailRequestID == requestID else { return }
                            let final = thumb.flatMap { self.cropToSquare($0, size: 48) } ?? thumb
                            self.setThumbnail(final, isImage: true)
                        }
                    }
                }
            } else {
                // Non-image: Finder icon, no corner radius
                let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
                icon.size = NSSize(width: 48, height: 48)
                imageView.image = icon
                imageView.contentTintColor = nil
                imageView.layer?.cornerRadius = 0
            }
        } else {
            // Missing file: outline triangle, grey name, no delete button
            thumbnailRequestID = UUID()
            if let sym = NSImage(systemSymbolName: "exclamationmark.triangle",
                                 accessibilityDescription: nil) {
                sym.isTemplate = true
                imageView.image = sym
            }
            imageView.contentTintColor = NSColor(white: 0.4, alpha: 1)
            imageView.layer?.cornerRadius = 0
            nameLabel.stringValue = item.fileName
            nameLabel.textColor = NSColor(white: 0.4, alpha: 1)
        }
        updateHoverAppearance()
    }

    private func setThumbnail(_ image: NSImage?, isImage: Bool) {
        imageView.image = image
        imageView.contentTintColor = nil
        imageView.layer?.cornerRadius = isImage ? 4 : 0  // Fix 4: 4px for images, 0 for icons
    }

    /// Centre-crop `image` to a square then scale to `size`×`size` — aspectFill with no letterbox.
    private func cropToSquare(_ image: NSImage, size: CGFloat) -> NSImage? {
        let src = image.size
        guard src.width > 0, src.height > 0 else { return nil }
        let side = min(src.width, src.height)
        let srcRect = NSRect(x: (src.width - side) / 2,
                             y: (src.height - side) / 2,
                             width: side, height: side)
        let out = NSImage(size: NSSize(width: size, height: size))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: srcRect, operation: .copy, fraction: 1,
                   respectFlipped: true, hints: nil)
        out.unlockFocus()
        return out
    }

    private func updateHoverAppearance() {
        guard let layer else { return }
        // Default: clear. Hover: light fill. Selected (incl. multi-select): slightly stronger, persists without hover.
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        nameLabel.preferredMaxLayoutWidth = nameLabel.bounds.width
        updateHoverAppearance()
    }

    @objc private func deleteClicked() { onDelete?() }
}

// MARK: - Draggable card view

final class DraggableFileView: NSView, NSDraggingSource {
    let cardContent: FileDropCardContentView
    private let item: DroppedFileItem
    private var fileURL: URL
    private var fileExists: Bool

    weak var fileDropStorage: FileDropStorage?
    weak var selection: FileSelectionState?
    weak var gridHoverState: FileGridHoverState?

    var onTap: (() -> Void)?
    /// Fired on a plain click (no shift/cmd). Used to set the Quick-Look-focused file.
    var onPlainSelect: (() -> Void)?
    var onRequestDelete: (() -> Void)?
    var onDragSessionEnded: ((NSDragOperation) -> Void)?

    /// Populated during a multi-file drag session; cleared when session ends.
    private var multiDragItems: [DroppedFileItem] = []

    private var mouseDownEvent: NSEvent?
    private var dragSessionStarted = false
    private var mouseDownOnDelete  = false
    /// True when this click used Shift/Cmd to toggle selection in `mouseDown` (plain `mouseUp` must not call `selectOnly`).
    private var usedModifierClickForSelection = false

    init(item: DroppedFileItem, fileURL: URL, exists: Bool, relativeTime: String) {
        self.item         = item
        self.fileURL      = fileURL
        self.fileExists   = exists
        self.cardContent  = FileDropCardContentView(
            item: item, fileURL: fileURL, exists: exists, relativeTime: relativeTime)
        super.init(frame: .zero)
        cardContent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardContent)
        NSLayoutConstraint.activate([
            cardContent.topAnchor.constraint(equalTo: topAnchor),
            cardContent.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardContent.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardContent.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        cardContent.onDelete = { [weak self] in self?.onRequestDelete?() }

        // Prevent natural image/content size from overriding SwiftUI's proposed grid column width.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func updateCard(item: DroppedFileItem, fileURL: URL, exists: Bool, relativeTime: String) {
        self.fileURL    = fileURL
        self.fileExists = exists
        cardContent.updateContent(item: item, fileURL: fileURL, exists: exists, relativeTime: relativeTime)
    }

    // MARK: Hit-testing & tracking

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        NotificationCenter.default.post(name: .quickPanelUserInteraction, object: nil)
        gridHoverState?.hoveredFileID = item.id
    }

    override func mouseExited(with event: NSEvent) {
        if gridHoverState?.hoveredFileID == item.id {
            gridHoverState?.hoveredFileID = nil
        }
        // Selection is now sticky (spec: clears only on outside-click, tab switch, or panel hide).
        // Do not wipe on mouse exit.
    }
    override func mouseMoved(with event: NSEvent) {
        NotificationCenter.default.post(name: .quickPanelUserInteraction, object: nil)
    }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        mouseDownEvent    = event
        dragSessionStarted = false
        mouseDownOnDelete  = false
        usedModifierClickForSelection = false

        let p      = convert(event.locationInWindow, from: nil)
        let pCard  = convert(p, to: cardContent)
        let btn    = cardContent.deleteButton
        if !btn.isHidden, btn.frame.contains(pCard) {
            mouseDownOnDelete = true
            onRequestDelete?()
        }

        // Shift/Cmd → toggle multi-selection in `mouseDown` so drag sees the new set.
        let mods = event.modifierFlags
        usedModifierClickForSelection = mods.contains(.shift) || mods.contains(.command)
        if usedModifierClickForSelection {
            selection?.toggle(item.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !mouseDownOnDelete,
              !dragSessionStarted,
              let downEvent = mouseDownEvent else { return }

        let start = downEvent.locationInWindow
        let now   = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        dragSessionStarted = true

        // Multi-drag when this card is selected and there are other selected cards.
        let selectedIDs = selection?.selectedIDs ?? []
        if selectedIDs.contains(item.id), selectedIDs.count > 1,
           let storage = fileDropStorage {
            startMultiFileDrag(mouseEvent: downEvent, storage: storage, selectedIDs: selectedIDs)
        } else {
            startSingleFileDrag(mouseEvent: downEvent)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDelete = mouseDownOnDelete
        let wasModifierSelect = usedModifierClickForSelection
        defer {
            mouseDownEvent = nil
            dragSessionStarted = false
            mouseDownOnDelete = false
            usedModifierClickForSelection = false
        }

        if dragSessionStarted { return }
        if wasDelete { return }

        if let down = mouseDownEvent {
            let start = down.locationInWindow
            let end = event.locationInWindow
            if hypot(end.x - start.x, end.y - start.y) > 3 { return }
        }

        // Plain click: single selection only. Shift/Cmd already toggled in `mouseDown`.
        if !wasModifierSelect {
            selection?.selectOnly(item.id)
            onPlainSelect?()
        }
    }

    // MARK: - Drag image thumbnail (sync)
    private func generateSyncThumbnail(for url: URL, size: CGSize) -> NSImage? {
        // For images load directly — fastest and most accurate
        let imageExts = ["png","jpg","jpeg","gif","webp","heic","bmp","tiff"]
        if imageExts.contains(url.pathExtension.lowercased()) {
            if let img = NSImage(contentsOf: url) {
                img.size = size
                return img
            }
        }

        // For everything else use workspace icon
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func flashCard() {
        guard let layer = cardContent.layer else { return }
        let original = layer.backgroundColor
        let flashColor = NSColor.white.withAlphaComponent(0.15).cgColor

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            cardContent.layer?.backgroundColor = flashColor
        }, completionHandler: { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                self.cardContent.layer?.backgroundColor = original
            })
        })
    }

    // MARK: - Drag helpers

    private func startSingleFileDrag(mouseEvent: NSEvent) {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let dragImage: NSImage = generateSyncThumbnail(for: url, size: CGSize(width: 48, height: 48))
            ?? NSWorkspace.shared.icon(forFile: url.path)

        let localPoint = convert(mouseEvent.locationInWindow, from: nil)
        let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        draggingItem.setDraggingFrame(
            NSRect(x: localPoint.x - 24, y: localPoint.y - 24, width: 48, height: 48),
            contents: dragImage)

        alphaValue = 0.7
        let session = beginDraggingSession(with: [draggingItem], event: mouseEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private func startMultiFileDrag(mouseEvent: NSEvent,
                                    storage: FileDropStorage,
                                    selectedIDs: Set<String>) {
        let selected = storage.files.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { startSingleFileDrag(mouseEvent: mouseEvent); return }

        var draggingItems: [NSDraggingItem] = []
        let localPoint = convert(mouseEvent.locationInWindow, from: nil)

        for (i, file) in selected.enumerated() {
            let url = storage.fileURL(for: file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 48, height: 48)
            let offset = CGFloat(i) * 2
            let di = NSDraggingItem(pasteboardWriter: url as NSURL)
            di.setDraggingFrame(
                NSRect(x: localPoint.x - 24 + offset, y: localPoint.y - 24 - offset, width: 48, height: 48),
                contents: icon)
            draggingItems.append(di)
        }

        guard !draggingItems.isEmpty else { return }
        multiDragItems = selected
        alphaValue = 0.7
        let session = beginDraggingSession(with: draggingItems, event: mouseEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    // MARK: Right-click context menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu(title: "")

        let openItem = NSMenuItem(title: "Open", action: #selector(menuOpen), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let revealItem = NSMenuItem(title: "Show in Finder", action: #selector(menuReveal), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)

        let copyItem = NSMenuItem(title: "Copy to Clipboard", action: #selector(menuCopy), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let removeItem = NSMenuItem(title: "Remove from Shelf", action: #selector(menuRemove), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuOpen() {
        let url = resolvedDragFileURL() ?? fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func menuReveal() {
        let url = resolvedDragFileURL() ?? fileURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func menuCopy() {
        let url = resolvedDragFileURL() ?? fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    @objc private func menuRemove() {
        let alert = NSAlert()
        alert.messageText     = "Remove from shelf?"
        alert.informativeText = "This deletes \"\(item.fileName)\" from your Stash shelf."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        fileDropStorage?.removeFile(item)
    }

    // MARK: Drag session

    private func resolvedDragFileURL() -> URL? {
        guard let storage = fileDropStorage else { return fileURL }
        guard let live = storage.files.first(where: { $0.id == item.id }) else { return nil }
        return storage.fileURL(for: live)
    }

    private func refreshCardIfFileMissing() {
        guard let storage = fileDropStorage,
              let live = storage.files.first(where: { $0.id == item.id }) else { return }
        let url   = storage.fileURL(for: live)
        let onDisk = FileManager.default.fileExists(atPath: url.path)
        fileExists = onDisk
        fileURL    = url
        cardContent.updateContent(
            item: live, fileURL: url, exists: onDisk,
            relativeTime: fileDropRelativeTime(since: live.dateDropped))
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .every
    }

    func draggingSession(_ session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint) {
        (window as? KeyablePanel)?.panelController?.isDraggingIntoPanel = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        alphaValue = 1.0
        defer {
            multiDragItems = []
            (window as? KeyablePanel)?.panelController?.isDraggingIntoPanel = false
        }

        // Cancelled or dropped inside our own panel — keep file.
        if operation.isEmpty { return }
        if let frame = self.window?.frame, frame.contains(screenPoint) { return }

        // Only remove from panel when dropped on Finder (window or desktop).
        // Browsers, Mail, Slack, Notes etc. just read/copy — file stays on shelf.
        guard droppedOnFinderOrDesktop(screenPoint: screenPoint) else { return }

        if multiDragItems.isEmpty {
            onDragSessionEnded?(operation)
        } else {
            for file in multiDragItems {
                fileDropStorage?.handleDragOutSessionEnded(item: file, operation: operation)
            }
            selection?.clear()
        }
    }

    /// Returns true if the screen point sits over a Finder window or the desktop (no app window).
    private func droppedOnFinderOrDesktop(screenPoint: NSPoint) -> Bool {
        // CGWindowList uses a top-left origin; AppKit uses bottom-left — flip Y.
        let screenHeight = NSScreen.screens.first?.frame.height ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        let cgPoint = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)

        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []


        // Find the frontmost normal-layer window that contains the drop point.
        for window in windowList {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let owner  = window[kCGWindowOwnerName as String] as? String,
                  let layer  = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }

            let rect = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard rect.contains(cgPoint) else { continue }

            // Finder window — remove from shelf.
            if owner == "Finder" { return true }
            // Any other app window (browser, Slack, Mail…) — keep on shelf.
            return false
        }

        // No app window at drop point → empty desktop (also Finder territory).
        return true
    }
}

// MARK: - Representable

final class FileDropCardCoordinator {
    var contentSignature: String = ""
}

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

    private static func fileId(fromContentSignature sig: String) -> String? {
        guard !sig.isEmpty else { return nil }
        guard let idx = sig.firstIndex(of: "|") else { return sig }
        return String(sig[..<idx])
    }

    func makeCoordinator() -> FileDropCardCoordinator {
        FileDropCardCoordinator()
    }

    func makeNSView(context: Context) -> DraggableFileView {
        let v = DraggableFileView(item: item, fileURL: fileURL, exists: exists, relativeTime: relativeTime)
        v.fileDropStorage    = storage
        v.selection          = selection
        v.gridHoverState     = hoverState
        v.onTap              = onTap
        v.onPlainSelect      = onPlainSelect
        v.onRequestDelete    = onRequestDelete
        v.onDragSessionEnded = onDragSessionEnded
        v.cardContent.onDelete = { [weak v] in v?.onRequestDelete?() }
        if isNewlyAdded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                v.cardContent.flashGreen()
                storage.clearNewlyAddedID(item.id)
            }
        }
        context.coordinator.contentSignature = "\(item.id)|\(fileURL.path)|\(exists)"
        return v
    }

    func updateNSView(_ nsView: DraggableFileView, context: Context) {
        nsView.fileDropStorage    = storage
        nsView.selection          = selection
        nsView.gridHoverState     = hoverState
        nsView.onTap              = onTap
        nsView.onPlainSelect      = onPlainSelect
        nsView.onRequestDelete    = onRequestDelete
        nsView.onDragSessionEnded = onDragSessionEnded
        nsView.cardContent.onDelete = { [weak nsView] in nsView?.onRequestDelete?() }

        let sig = "\(item.id)|\(fileURL.path)|\(exists)"
        if context.coordinator.contentSignature != sig {
            let oldSig = context.coordinator.contentSignature
            if !oldSig.isEmpty,
               let oldId = Self.fileId(fromContentSignature: oldSig),
               hoverState.hoveredFileID == oldId {
                hoverState.hoveredFileID = nil
            }
            context.coordinator.contentSignature = sig
            nsView.updateCard(item: item, fileURL: fileURL, exists: exists, relativeTime: relativeTime)
        }

        nsView.cardContent.setSelected(isSelected)
        nsView.cardContent.setQuickLookSelected(isQuickLookSelected)
        nsView.cardContent.setCardHover(hoverState.hoveredFileID == item.id)
    }

    static func dismantleNSView(_ nsView: DraggableFileView, coordinator: FileDropCardCoordinator) {
        nsView.onTap = nil
        nsView.onPlainSelect = nil
        nsView.selection = nil
        nsView.gridHoverState = nil
        nsView.onRequestDelete = nil
        nsView.onDragSessionEnded = nil
        nsView.cardContent.onDelete = nil
    }
}

// MARK: - Container (drop target + visual state: black border, upload icon, content fade)

final class FileDropContainerView: NSView {
    var onDrop: (([URL]) -> Void)?
    weak var contentHostingView: NSView?

    private let borderLayer    = CALayer()
    private let uploadIconView = NSImageView()
    private let hintLabel: NSTextField = {
        let t = NSTextField(labelWithString: ProminentExternalFileDragChrome.hint)
        t.font = ProminentExternalFileDragChrome.hintFont
        t.textColor = NSColor.white
        t.alignment = .center
        t.alphaValue = 0
        t.isHidden = true
        t.drawsBackground = false
        t.isBordered = false
        t.maximumNumberOfLines = 2
        t.lineBreakMode = .byWordWrapping
        t.preferredMaxLayoutWidth = 280
        return t
    }()

    private var showingDragUI  = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        borderLayer.frame        = bounds
        borderLayer.borderWidth  = 0
        borderLayer.cornerRadius = ProminentExternalFileDragChrome.cornerRadius
        borderLayer.borderColor  = NSColor.clear.cgColor
        borderLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        layer?.addSublayer(borderLayer)

        if let sym = NSImage(systemSymbolName: ProminentExternalFileDragChrome.symbolName,
                             accessibilityDescription: nil) {
            uploadIconView.image = sym
        }
        uploadIconView.contentTintColor = NSColor.white
            .withAlphaComponent(ProminentExternalFileDragChrome.iconTintAlpha)
        uploadIconView.imageScaling     = .scaleProportionallyUpOrDown
        uploadIconView.alphaValue       = 0
        uploadIconView.isHidden         = true
        uploadIconView.wantsLayer       = true

        registerForDraggedTypes(StashFileDragPasteboard.types)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Called by makeNSView after the hosting view is added — ensures chrome sits above SwiftUI.
    func liftOverlay() {
        addSubview(uploadIconView)
        addSubview(hintLabel)
        layer?.addSublayer(borderLayer)
    }

    // MARK: Drop-state visual

    func showDropState(_ active: Bool) {
        guard showingDragUI != active else { return }
        showingDragUI = active

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.borderColor = active
            ? NSColor.black.withAlphaComponent(ProminentExternalFileDragChrome.borderBlackAlpha).cgColor
            : NSColor.clear.cgColor
        borderLayer.borderWidth = active ? ProminentExternalFileDragChrome.borderWidth : 0
        CATransaction.commit()

        if active {
            // Unhide before fade-in so the animation is visible
            uploadIconView.isHidden = false
            hintLabel.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                contentHostingView?.animator().alphaValue =
                    ProminentExternalFileDragChrome.filesColumnContentFade
                uploadIconView.animator().alphaValue = 1.0
                hintLabel.animator().alphaValue      = 1.0
            }
        } else {
            // Fade out, then set isHidden so they are fully removed from hit testing
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                contentHostingView?.animator().alphaValue = 1.0
                uploadIconView.animator().alphaValue = 0.0
                hintLabel.animator().alphaValue      = 0.0
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.uploadIconView.isHidden = true
                self.hintLabel.isHidden = true
            })
        }
    }

    override func layout() {
        super.layout()
        borderLayer.frame = bounds
        let s = ProminentExternalFileDragChrome.iconSide
        let midY = bounds.midY - 6
        uploadIconView.frame = CGRect(
            x: (bounds.width  - s) / 2,
            y: midY - s / 2,
            width: s,
            height: s
        )
        let lw = min(bounds.width - 24, 280)
        hintLabel.preferredMaxLayoutWidth = lw
        hintLabel.sizeToFit()
        let lh = hintLabel.fittingSize.height
        hintLabel.frame = CGRect(
            x: (bounds.width - lw) / 2,
            y: midY + s / 2 + 10,
            width: lw,
            height: max(lh, 22)
        )
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource is DraggableFileView { return [] }
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }
        (window as? KeyablePanel)?.panelController?.cancelDeferredClose()
        (window as? KeyablePanel)?.panelController?.isDraggingIntoPanel = true
        window?.level = .normal
        window?.orderFrontRegardless()
        showDropState(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        (window as? KeyablePanel)?.panelController?.isDraggingIntoPanel = false
        window?.level = .floating
        showDropState(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo?) {
        (window as? KeyablePanel)?.panelController?.isDraggingIntoPanel = false
        window?.level = .floating
        showDropState(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (window as? KeyablePanel)?.panelController?.isDraggingIntoPanel = false
        showDropState(false)
        if sender.draggingSource is DraggableFileView { return false }
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else { return false }

        let panelFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/QuickPanel")
            .standardizedFileURL

        let filtered = urls.filter { !$0.path.hasPrefix(panelFolder.path) }
        guard !filtered.isEmpty else { return false }

        onDrop?(filtered)
        return true
    }
}

// MARK: - NSViewRepresentable wrapper

struct FileDropZoneRepresentable: NSViewRepresentable {
    let content: AnyView
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> FileDropContainerView {
        let container = FileDropContainerView()

        let hosting = NSHostingView(rootView: content)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // Add hosting first, then lift overlay views above it.
        container.addSubview(hosting, positioned: .below, relativeTo: nil)
        container.contentHostingView = hosting
        container.onDrop = onDrop
        container.liftOverlay()

        return container
    }

    func updateNSView(_ container: FileDropContainerView, context: Context) {
        container.onDrop = onDrop
        // Push fresh bindings into the hosted SwiftUI view every time the parent re-renders.
        // Without this, @Binding changes (editingNoteId, showTranscriptionPage, etc.) never
        // reach SharedNotesColumn — the NSHostingView stays frozen on its initial state.
        if let hosting = container.contentHostingView as? NSHostingView<AnyView> {
            hosting.rootView = content
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { }
}
