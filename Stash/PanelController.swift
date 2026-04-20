import AppKit
import SwiftUI
import Combine
import CoreGraphics

extension Notification.Name {
    static let quickPanelUserInteraction = Notification.Name("QuickPanelUserInteraction")
}

/// NSPanel subclass that can become key window so the notes text view accepts keyboard input.
/// Intercepts ⌘V for the file drop zone when no text field is active.
final class KeyablePanel: NSPanel {
    weak var fileDropStorage: FileDropStorage?
    weak var panelController: PanelController?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           isVisible,
           isKeyWindow,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.caseInsensitiveCompare("v") == .orderedSame,
           !isTextInputActive {
            if let storage = fileDropStorage, storage.tryPasteFromPasteboard() {
                panelController?.resetPanelIdleTimer()
                return
            }
        }
        if isVisible, Self.eventResetsPanelIdleTimer(event) {
            panelController?.resetPanelIdleTimer()
        }
        super.sendEvent(event)
    }

    private static func eventResetsPanelIdleTimer(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .mouseMoved, .scrollWheel, .keyDown, .keyUp, .cursorUpdate:
            return true
        default:
            return false
        }
    }

    var isTextInputActive: Bool {
        guard let fr = firstResponder else { return false }
        if fr is NSTextView { return true }
        if let tf = fr as? NSTextField, tf.isEditable { return true }
        return false
    }

}

// MARK: - Snap zones

enum PanelSnapZone: String, CaseIterable {
    case topLeft, topCenter, topRight
    case bottomLeft, bottomCenter, bottomRight

    static let `default` = PanelSnapZone.topCenter
    private static let userDefaultsKey = "PanelSnapZone"

    static func load() -> PanelSnapZone {
        PanelSnapZone(rawValue: UserDefaults.standard.string(forKey: userDefaultsKey) ?? "") ?? .default
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: PanelSnapZone.userDefaultsKey)
    }

    private static let margin: CGFloat = 20

    /// On-screen frame for this snap zone.
    func visibleFrame(size: CGSize, screen: NSRect) -> NSRect {
        let m = PanelSnapZone.margin
        let w = size.width, h = size.height
        switch self {
        case .topLeft:      return NSRect(x: screen.minX + m,     y: screen.maxY - h - m, width: w, height: h)
        case .topCenter:    return NSRect(x: screen.midX - w / 2, y: screen.maxY - h - m, width: w, height: h)
        case .topRight:     return NSRect(x: screen.maxX - w - m, y: screen.maxY - h - m, width: w, height: h)
        case .bottomLeft:   return NSRect(x: screen.minX + m,     y: screen.minY + m,     width: w, height: h)
        case .bottomCenter: return NSRect(x: screen.midX - w / 2, y: screen.minY + m,     width: w, height: h)
        case .bottomRight:  return NSRect(x: screen.maxX - w - m, y: screen.minY + m,     width: w, height: h)
        }
    }

    /// Off-screen starting / ending frame for slide-in / slide-out animation.
    func hiddenFrame(size: CGSize, screen: NSRect) -> NSRect {
        var f = visibleFrame(size: size, screen: screen)
        switch self {
        case .topLeft, .topCenter, .topRight:
            f.origin.y = screen.maxY                // slide up off top
        case .bottomLeft, .bottomCenter, .bottomRight:
            f.origin.y = screen.minY - f.height     // slide down off bottom
        }
        return f
    }

    var isTop: Bool {
        switch self {
        case .topLeft, .topCenter, .topRight: return true
        default: return false
        }
    }

    /// Find the snap zone whose on-screen center is nearest to `panelFrame`.
    static func nearest(to panelFrame: NSRect, size: CGSize, screen: NSRect) -> PanelSnapZone {
        let cx = panelFrame.midX, cy = panelFrame.midY
        return allCases.min {
            let a = $0.visibleFrame(size: size, screen: screen)
            let b = $1.visibleFrame(size: size, screen: screen)
            return hypot(a.midX - cx, a.midY - cy) < hypot(b.midX - cx, b.midY - cy)
        } ?? .default
    }
}

// MARK: - Mouse-tracking + panel-drag container

final class PanelMouseTrackingView: NSView {
    weak var panelController: PanelController?
    private var trackingArea: NSTrackingArea?

    // Panel-drag state
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isPanelDrag = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        if let trackingArea { addTrackingArea(trackingArea) }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        panelController?.pauseIdleTimer()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        panelController?.resumeIdleTimer()
    }

    // MARK: Drag-to-reposition

    override func mouseDown(with event: NSEvent) {
        dragStartMouse  = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
        isPanelDrag     = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouse, let origin = dragStartOrigin, let win = window else { return }
        let loc = NSEvent.mouseLocation
        let dx = loc.x - start.x, dy = loc.y - start.y
        if !isPanelDrag, hypot(dx, dy) < 4 { return }   // threshold before committing to a panel drag
        isPanelDrag = true
        win.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        panelController?.resetPanelIdleTimer()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            isPanelDrag     = false
            dragStartMouse  = nil
            dragStartOrigin = nil
        }
        if isPanelDrag {
            DispatchQueue.main.async { [weak self] in
                self?.panelController?.snapToNearestZone()
            }
            return
        }
        super.mouseUp(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Manages the sliding content panel.
@MainActor
final class PanelController: NSObject {

    static weak var shared: PanelController?

    private var panelWidth: CGFloat { AppSettings.shared.panelWidth }
    private var panelHeight: CGFloat { AppSettings.shared.panelHeight }

    /// Persisted snap zone — where the panel appears and returns to.
    private(set) var snapZone: PanelSnapZone = PanelSnapZone.load()

    private let animationDuration: TimeInterval = 0.5

    /// Above normal application windows (Chrome, Figma, etc.). Uses CoreGraphics floating level;
    /// if anything still stacks above, switch to `.assistiveTechHighWindow` here.
    private var contentPanelWindowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
    }

    private let fileDropStorage = FileDropStorage()
    let clipboardManager = ClipboardManager()
    let notesStorage = NotesStorage()
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
    private let transcriptionFloatingWidget = TranscriptionFloatingWidgetController()

    private var contentPanel: KeyablePanel?
    private var panelHostingController: NSHostingController<QuickPanelRootView>?
    private var cardsModeContainer: CardsModeContainerView?
    /// Latest measured cards stack height (including stack edge insets), lower bound 180.
    private var cardsStackHeightCached: CGFloat = 180
    private var idleTimer: Timer?
    private var mouseInsidePanel = false
    private var userInteractionObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    // Click-outside-to-close + drag-state monitoring (idle timer pauses while dragging)
    private var globalClickMonitor: Any?
    private var isDragInProgress = false
    var isDraggingIntoPanel = false
    private var closeWorkItem: DispatchWorkItem?
    private var dragMonitor: Any?
    private var localDragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var localMouseUpMonitor: Any?

    override init() {
        super.init()
        userInteractionObserver = NotificationCenter.default.addObserver(
            forName: .quickPanelUserInteraction,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetPanelIdleTimer()
        }
    }

    deinit {
        // `deinit` is nonisolated; hop back to the main actor for monitor cleanup.
        Task { @MainActor [weak self] in
            self?.stopClickOutsideMonitor()
            self?.idleTimer?.invalidate()
            self?.idleTimer = nil
        }
        if let obs = userInteractionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Idle timer

    func resetPanelIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil

        guard let panel = contentPanel, panel.isVisible else { return }
        guard !mouseInsidePanel else { return }
        guard !isDragInProgress else { return }

        let interval = AppSettings.shared.autoHideSeconds
        guard interval > 0 else { return }

        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.idleTimer = nil
            guard !self.mouseInsidePanel, !self.isDragInProgress else { return }
            self.hidePanel()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    func pauseIdleTimer() {
        mouseInsidePanel = true
        idleTimer?.invalidate()
        idleTimer = nil
    }

    func resumeIdleTimer() {
        mouseInsidePanel = false
        resetPanelIdleTimer()
    }

    // MARK: - Click-outside-to-close + drag monitoring

    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handleGlobalClick(event: event)
        }

        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            guard let self else { return }
            self.isDragInProgress = true
            self.idleTimer?.invalidate()
            self.idleTimer = nil
        }

        // Drags that start inside QuickPanel are not visible to the global monitor; track them locally.
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            self?.isDragInProgress = true
            self?.idleTimer?.invalidate()
            self?.idleTimer = nil
            return event
        }

        let scheduleDragEnded: () -> Void = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.isDragInProgress = false
                if !self.mouseInsidePanel {
                    self.resetPanelIdleTimer()
                }
            }
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            scheduleDragEnded()
        }

        // Mouse-up in our app isn't visible to the global monitor; clear drag state the same way.
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            scheduleDragEnded()
            return event
        }
    }

    private func stopClickOutsideMonitor() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
        if let m = localDragMonitor { NSEvent.removeMonitor(m); localDragMonitor = nil }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m); mouseUpMonitor = nil }
        if let m = localMouseUpMonitor { NSEvent.removeMonitor(m); localMouseUpMonitor = nil }
        isDragInProgress = false
        isDraggingIntoPanel = false
    }

    func scheduleDeferredClose() {
        cancelDeferredClose()
        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.hidePanel() }
        }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func cancelDeferredClose() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
    }

    private func handleGlobalClick(event: NSEvent) {
        guard let panel = contentPanel, panel.isVisible else { return }
        guard !isDraggingIntoPanel else { return }
        guard !isDragInProgress else { return }

        let screenPoint = NSEvent.mouseLocation

        // Ignore clicks inside the panel
        if panel.frame.contains(screenPoint) { return }

        // Convert to CGWindowList coordinate system
        // CGWindowList uses top-left origin of the menu bar screen
        let menuBarScreenHeight = NSScreen.screens.first?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let cgY = menuBarScreenHeight - screenPoint.y
        let cgPoint = CGPoint(x: screenPoint.x, y: cgY)

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            // Can't determine — use safe deferred path
            scheduleDeferredClose()
            return
        }

        for window in windowList {
            guard
                let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                let owner = window[kCGWindowOwnerName as String] as? String
            else { continue }

            let rect = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            guard rect.contains(cgPoint) else { continue }

            if owner == "Finder" {
                // Finder browser window — user may drag from it, stay open
                return
            } else {
                // Any other app (browser, Slack, Terminal etc) — close immediately
                DispatchQueue.main.async { [weak self] in self?.hidePanel() }
                return
            }
        }

        // No regular window found at click point = DESKTOP AREA
        // The user may be clicking a desktop file to drag it in.
        // Wait 500ms — if a drag arrives into the panel, cancelDeferredClose()
        // will be called from draggingEntered. If nothing arrives, we close.
        scheduleDeferredClose()
    }

    // MARK: - Screen geometry

    private var screen: NSScreen? { NSScreen.main }
    private var visibleFrame: NSRect { screen?.visibleFrame ?? .zero }

    private var isCardsLayout: Bool {
        AppSettings.shared.layoutStyle == .cards
    }

    /// Visible frame: panel mode uses snap zone; cards mode centres below menu bar.
    private var contentPanelVisibleFrame: NSRect {
        if isCardsLayout {
            let w: CGFloat = 420
            if let c = cardsModeContainer {
                c.layoutSubtreeIfNeeded()
                cardsStackHeightCached = max(180, c.totalStackHeight())
            }
            let h = cardsStackHeightCached
            let x = visibleFrame.midX - w / 2
            let y = visibleFrame.maxY - 8 - h
            return NSRect(x: x, y: y, width: w, height: h)
        }
        return snapZone.visibleFrame(size: CGSize(width: 700, height: panelHeight), screen: visibleFrame)
    }

    private var contentPanelHiddenFrame: NSRect {
        if isCardsLayout {
            var f = contentPanelVisibleFrame
            f.origin.y = visibleFrame.maxY
            return f
        }
        return snapZone.hiddenFrame(size: CGSize(width: 700, height: panelHeight), screen: visibleFrame)
    }

    // MARK: - Setup

    func setup() {
        PanelController.shared = self
        transcriptionService.notesStorage = notesStorage
        transcriptionService.makePanelKey = { [weak self] in
            self?.contentPanel?.makeKeyAndOrderFront(nil)
        }
        transcriptionFloatingWidget.attach(transcription: transcriptionService)
        transcriptionFloatingWidget.onOpenTranscription = { [weak self] in
            guard let self else { return }
            self.showPanel()
        }

        // Auto-hide the panel when recording starts so the pill takes over.
        transcriptionService.$isRecording
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.hidePanel() }
            .store(in: &cancellables)

        // Long (>= 5 min) meeting recordings are the only ones that fire
        // onNoteCreated now — short recordings only copy to clipboard and flash
        // the pill, so when this fires we always open the new note in the editor.
        transcriptionService.onNoteCreated = { [weak self] id in
            guard let self else { return }
            self.panelInteractionState.requestedTab = .notes
            self.panelInteractionState.editingNoteId = id
            self.showPanel()
        }

        createContentPanel()
        observeSettings()
    }

    private func createContentPanel() {
        let frame = contentPanelHiddenFrame

        let panel = KeyablePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.fileDropStorage = fileDropStorage
        panel.panelController = self
        panel.acceptsMouseMovedEvents = true
        panel.level = contentPanelWindowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

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
        let hosting = NSHostingController(rootView: root)

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
        cardsModeContainer = cardsView

        let container = PanelMouseTrackingView()
        container.frame = NSRect(origin: .zero, size: frame.size)
        container.autoresizingMask = [.width, .height]
        container.panelController = self

        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        cardsView.translatesAutoresizingMaskIntoConstraints = false
        // Cards below, SwiftUI hosting on top — avoids any compositing oddities when cards are hidden.
        container.addSubview(cardsView)
        container.addSubview(hosting.view)

        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            cardsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cardsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cardsView.topAnchor.constraint(equalTo: container.topAnchor),
            cardsView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        updateCardsVsPanelHostingVisibility()

        panel.contentView = container
        panelHostingController = hosting
        contentPanel = panel

        applyPanelChromeForLayoutStyle()
    }

    private func updateCardsVsPanelHostingVisibility() {
        let showAuthGate = !AuthService.shared.isSignedIn
        let cards = isCardsLayout && !showAuthGate
        panelHostingController?.view.isHidden = cards
        cardsModeContainer?.isHidden = !cards || showAuthGate
    }

    /// Recompute cards stack height and resize the panel (top fixed, grows downward only).
    func resizeCardsPanelToFitStack(animated: Bool) {
        guard isCardsLayout, let c = cardsModeContainer else { return }
        c.layoutSubtreeIfNeeded()
        cardsStackHeightCached = max(180, c.totalStackHeight())
        applyCardsPanelFrameFromStack(animated: animated, duration: 0.24)
    }

    func applyCardsPanelFrameFromStack(animated: Bool, duration: TimeInterval) {
        guard let panel = contentPanel, let contentView = panel.contentView, isCardsLayout else { return }
        if let c = cardsModeContainer {
            c.layoutSubtreeIfNeeded()
            cardsStackHeightCached = max(180, c.totalStackHeight())
        }
        let w: CGFloat = 420
        let h = cardsStackHeightCached
        let topY = visibleFrame.maxY - 8
        let y = topY - h
        let x = visibleFrame.midX - w / 2
        let newFrame = NSRect(x: x, y: y, width: w, height: h)
        let contentRect = NSRect(origin: .zero, size: NSSize(width: w, height: h))

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(newFrame, display: true)
                contentView.animator().frame = contentRect
            }
        } else {
            panel.setFrame(newFrame, display: true)
            contentView.frame = contentRect
        }
    }

    private func applyPanelChromeForLayoutStyle() {
        guard let panel = contentPanel, let contentView = panel.contentView else { return }
        updateCardsVsPanelHostingVisibility()
        contentView.wantsLayer = true

        let hostingView = panelHostingController?.view

        if isCardsLayout {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            contentView.layer?.backgroundColor = nil
            contentView.layer?.cornerRadius = 0
            contentView.layer?.cornerCurve = .circular
            contentView.layer?.borderWidth = 0
            contentView.layer?.borderColor = nil
            contentView.layer?.masksToBounds = false

            hostingView?.wantsLayer = true
            hostingView?.layer?.cornerRadius = 0
            hostingView?.layer?.masksToBounds = false
            hostingView?.layer?.borderWidth = 0
            hostingView?.layer?.borderColor = nil
            hostingView?.layer?.backgroundColor = nil
        } else {
            // Transparent window so rounded corners are see-through on any desktop background.
            // Only the hostingView carries the rounded black fill.
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false

            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.borderWidth = 0
            contentView.layer?.borderColor = nil
            contentView.layer?.cornerRadius = 0
            contentView.layer?.masksToBounds = false

            hostingView?.wantsLayer = true
            hostingView?.layer?.backgroundColor = NSColor.black.cgColor
            hostingView?.layer?.borderWidth = 0
            hostingView?.layer?.borderColor = nil
            hostingView?.layer?.cornerRadius = 24
            hostingView?.layer?.cornerCurve = .continuous
            hostingView?.layer?.masksToBounds = true

        }
    }

    // MARK: - Observe AppSettings

    private func observeSettings() {
        AppSettings.shared.$panelWidth
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isCardsLayout else { return }
                self.applyNewPanelFrame()
            }
            .store(in: &cancellables)

        AppSettings.shared.$panelHeight
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isCardsLayout else { return }
                self.applyNewPanelFrame()
            }
            .store(in: &cancellables)

        AppSettings.shared.$autoHideSeconds
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resetPanelIdleTimer() }
            .store(in: &cancellables)

        AppSettings.shared.$layoutStyle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyPanelChromeForLayoutStyle()
                if self.isCardsLayout {
                    self.resizeCardsPanelToFitStack(animated: false)
                }
                self.applyNewPanelFrame()
            }
            .store(in: &cancellables)
    }

    private func applyNewPanelFrame() {
        guard let panel = contentPanel, let contentView = panel.contentView else { return }
        let target = panel.isVisible ? contentPanelVisibleFrame : contentPanelHiddenFrame
        let contentRect = NSRect(origin: .zero, size: target.size)
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                contentView.animator().frame = contentRect
            }
        } else {
            panel.setFrame(target, display: false)
            contentView.frame = contentRect
        }
    }

    // MARK: - Show / hide

    func showPanel() {
        guard let panel = contentPanel else { return }
        NSApp.activate(ignoringOtherApps: true)
        cancelDeferredClose()

        transcriptionFloatingWidget.setPanelOpenForWidget(true)
        applyPanelChromeForLayoutStyle()

        isDragInProgress = false

        let targetFrame = contentPanelVisibleFrame
        mouseInsidePanel = targetFrame.contains(NSEvent.mouseLocation)

        panel.level = .floating
        panel.orderFrontRegardless()

        // Slide in from the screen edge nearest to the snap zone.
        let startFrame = contentPanelHiddenFrame
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        let contentRect = NSRect(origin: .zero, size: targetFrame.size)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.0, 0.0, 0.2, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
            panel.contentView?.animator().frame = contentRect
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.applyPanelChromeForLayoutStyle()
            }
        })

        // Don't start the click-outside monitor immediately; allow the opening click
        // to complete without accidentally closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            guard self.contentPanel?.isVisible ?? false else { return }
            self.startClickOutsideMonitor()
        }
        resetPanelIdleTimer()
    }

    func hidePanel() {
        guard let panel = contentPanel, panel.isVisible else { return }

        // Quick Look and the key monitor must go BEFORE the animation — otherwise
        // QL lingers on-screen for ~250ms after the slide-out starts, and a
        // spacebar press during that window can retrigger the monitor.
        fileQuickLook.closeQuickLookIfVisible()
        fileQuickLook.removeKeyMonitor()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
            panel.animator().setFrame(contentPanelHiddenFrame, display: true)
            panel.animator().alphaValue = 0
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

    func togglePanel() {
        guard let panel = contentPanel else { return }
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    /// Called by `PanelMouseTrackingView` after a drag ends.
    func snapToNearestZone() {
        guard let panel = contentPanel, !isCardsLayout else { return }
        let size = CGSize(width: 700, height: panelHeight)
        let zone = PanelSnapZone.nearest(to: panel.frame, size: size, screen: visibleFrame)
        snapZone = zone
        zone.save()
        let target = zone.visibleFrame(size: size, screen: visibleFrame)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.64, 1.0) // springy
            panel.animator().setFrame(target, display: true)
        }
    }
}

// MARK: - Root SwiftUI view (switches layout style)

struct AuthGateView: View {
    @ObservedObject private var auth = AuthService.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.white)
                Spacer().frame(height: 20)
                Text("Sign in to Stash")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white)
                Spacer().frame(height: 10)
                Text("A Stash account is required to use the app.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
                Spacer().frame(height: 32)
                Button {
                    Task { await AuthService.shared.signInWithGoogle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.black)
                        Text("Continue with Google")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.black)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .disabled(auth.isLoading)
                if let error = auth.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .onTapGesture { AuthService.shared.errorMessage = nil }
                }
                if auth.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.8)
                        Text("Opening Google sign in...")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.6))
                        Button("Cancel") { AuthService.shared.isLoading = false }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.top, 16)
                }
                Spacer()
            }
        }
    }
}

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

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var auth = AuthService.shared

    var body: some View {
        if !auth.isSignedIn {
            AuthGateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .preferredColorScheme(.dark)
        } else {
        Group {
            if settings.layoutStyle == .panel {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
            } else {
                // Cards mode: layout is driven by `CardsModeContainerView` (AppKit) in `PanelController`.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .id(settings.layoutStyle)
        } // end auth else
    }
}

// MARK: - Wide panel layout

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
    @Binding var editingNoteId: String?
    @Binding var noteToDelete: NoteItem?
    @Binding var fileToDelete: DroppedFileItem?
    var panelWidth: CGFloat

    @State private var selectedTab: PanelMainTab = .all

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 0) {
                TabBarView(
                    selectedTab: $selectedTab,
                    onMicTap: {
                        transcription.startRecording()
                        // Panel auto-hides via PanelController.$isRecording observer
                    },
                    onAddNote: {
                        let id = notesStorage.createNewNote()
                        notesStorage.createEmptyNoteFile(id: id)
                        editingNoteId = id
                        selectedTab = .notes
                        makePanelKey()
                    }
                )
                .padding(.bottom, DesignTokens.Spacing.cardGap)

                if transcription.isRecording || transcription.isProcessing || transcription.lastErrorForBanner != nil {
                    RecordingBanner(
                        isProcessing: transcription.isProcessing,
                        errorMessage: transcription.lastErrorForBanner,
                        onStop: { transcription.stopRecording() }
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                }

                /// Only the selected tab is in the hierarchy. Stacking every tab with opacity caused higher
                /// `NSHostingView`s (Clipboard / Files / Notes) to sit above the All/Files drop containers and
                /// block `NSDraggingDestination`, so upload chrome never appeared.
                ZStack {
                    Group {
                        switch selectedTab {
                        case .all:
                            FileDropZoneRepresentable(
                                content: AnyView(
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
                                ),
                                onDrop: { fileDropStorage.addFiles($0) }
                            )
                        case .clipboard:
                            FileDropZoneRepresentable(
                                content: AnyView(
                                    SharedClipboardColumn(clipboard: clipboard, forCardsMode: false)
                                ),
                                onDrop: { urls in
                                    fileDropStorage.addFiles(urls)
                                    selectedTab = .files
                                }
                            )
                        case .files:
                            SharedFilesColumn(
                                fileDropStorage: fileDropStorage,
                                fileToDelete: $fileToDelete,
                                forCardsMode: false,
                                fileSelection: fileSelection,
                                fileGridHover: fileGridHover,
                                fileQuickLook: fileQuickLook
                            )
                        case .notes:
                            FileDropZoneRepresentable(
                                content: AnyView(
                                    SharedNotesColumn(
                                        makePanelKey: makePanelKey,
                                        notesStorage: notesStorage,
                                        transcription: transcription,
                                        showTranscriptionPage: $showTranscriptionPage,
                                        editingNoteId: $editingNoteId,
                                        noteToDelete: $noteToDelete,
                                        forCardsMode: false
                                    )
                                ),
                                onDrop: { urls in
                                    fileDropStorage.addFiles(urls)
                                    selectedTab = .files
                                }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeInOut(duration: 0.15), value: selectedTab)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .frame(maxWidth: 700, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.25), value: transcription.isRecording)
            .animation(.easeOut(duration: 0.25), value: transcription.isProcessing)
            .onChange(of: panelInteraction.requestedTab) { tab in
                guard let tab else { return }
                selectedTab = tab
                panelInteraction.requestedTab = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            PanelToastOverlay(message: $clipboard.transientMessage)
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .alert("Delete note?", isPresented: Binding(
            get: { noteToDelete != nil },
            set: { if !$0 { noteToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { noteToDelete = nil }
            Button("Delete", role: .destructive) {
                if let note = noteToDelete {
                    notesStorage.deleteNote(id: note.id)
                    noteToDelete = nil
                }
            }
        } message: {
            Text("This note will be permanently deleted.")
        }
        .alert("Delete file?", isPresented: Binding(
            get: { fileToDelete != nil },
            set: { if !$0 { fileToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { fileToDelete = nil }
            Button("Delete", role: .destructive) {
                if let item = fileToDelete {
                    fileDropStorage.removeFile(item)
                    fileToDelete = nil
                }
            }
        } message: {
            Text("The file will be removed from the list and deleted from your Mac.")
        }
    }
}

// MARK: - Reusable panel toast overlay

struct PanelToastOverlay: View {
    @Binding var message: String?
    @State private var isVisible = false
    @State private var hideTask: DispatchWorkItem?

    var body: some View {
        ZStack {
            if isVisible, let text = message {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(DesignTokens.Icon.backgroundActive)
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isVisible)
        .onChange(of: message) { newValue in
            hideTask?.cancel()
            if newValue != nil {
                withAnimation(.easeOut(duration: 0.2)) { isVisible = true }
                let task = DispatchWorkItem { [self] in
                    withAnimation(.easeOut(duration: 0.2)) { isVisible = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if self.message == newValue { self.message = nil }
                    }
                }
                hideTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: task)
            } else {
                withAnimation(.easeOut(duration: 0.2)) { isVisible = false }
            }
        }
    }
}

// MARK: - Recording banner

struct RecordingBanner: View {
    let isProcessing: Bool
    var errorMessage: String? = nil
    let onStop: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            if let err = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                Text(err)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange.opacity(0.90))
                    .lineLimit(2)
            } else {
                Circle()
                    .fill(DesignTokens.Icon.tintRecording)
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulse ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }

                Text(isProcessing ? "Creating notes..." : "Recording in progress")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.80))
            }

            Spacer()

            if !isProcessing && errorMessage == nil {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .overlay(Circle().stroke(Color.white.opacity(0.20), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(errorMessage != nil
                    ? Color.orange.opacity(0.12)
                    : DesignTokens.Icon.tintRecording.opacity(0.15))
        )
        .padding(.bottom, 8)
    }
}
