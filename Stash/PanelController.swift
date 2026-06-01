import AppKit
import SwiftUI
import Combine
import CoreGraphics

extension Notification.Name {
    static let quickPanelUserInteraction = Notification.Name("QuickPanelUserInteraction")
    static let stashPanelDidHide = Notification.Name("StashPanelDidHide")
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let subviews get the first shot (buttons, text fields, etc.).
        // Fall back to self so empty areas can initiate a panel drag.
        if let hit = super.hitTest(point), hit !== self {
            return hit
        }
        return self
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// NSHostingView is opaque by default, so mouseDownCanMoveWindow returns false
// and isMovableByWindowBackground never fires for it. Override to allow the OS
// to move the window when the user drags on non-interactive areas of the SwiftUI view.
private final class MovableHostingView: NSHostingView<QuickPanelRootView> {
    override var mouseDownCanMoveWindow: Bool { true }
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
    private var panelHostingView: MovableHostingView?
    private var snapDragMonitor: Any?
    private var snapDragStartOrigin: NSPoint?
    private var cardsModeContainer: CardsModeContainerView?
    /// Latest measured cards stack height (including stack edge insets), lower bound 180.
    private var cardsStackHeightCached: CGFloat = 180
    private var idleTimer: Timer?
    private var mouseInsidePanel = false
    private var userInteractionObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    /// Incremented before every show/hide animation; completion handlers capture the
    /// value they started with and bail if another animation has superseded them.
    /// Guards against rapid-toggle leaks (e.g. hide completion calling orderOut
    /// after a new show has already started).
    private var animationToken: Int = 0

    // Click-outside-to-close + drag-state monitoring (idle timer pauses while dragging)
    private var globalClickMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?
    private var isDragInProgress = false
    var isDraggingIntoPanel = false {
        didSet {
            if isDraggingIntoPanel { cancelDeferredClose() }
        }
    }
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

        // Right-click outside panel → close immediately.
        // Right-click never precedes a file drag, so no deferral needed.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.rightMouseDown]
        ) { [weak self] _ in
            guard let self, let panel = self.contentPanel, panel.isVisible else { return }
            guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.hidePanel()
        }

        // App-switch detection — the ONLY reliable close signal.
        //
        // NSWorkspace.didActivateApplicationNotification fires when macOS changes
        // the foreground app. It does NOT fire for desktop file clicks (Finder stays
        // background while selecting the file), so those clicks leave the panel open.
        //
        // • Finder bundle   → user clicked a file, folder, or Finder window → stay open
        // • Our bundle / "" → LSUIElement edge case or unknown               → stay open
        // • anything else   → Chrome, Slack, Terminal, etc.                  → close
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let panel = self.contentPanel, panel.isVisible else { return }
            guard !self.isDraggingIntoPanel else { return }

            let activated = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication

            let frontID = activated?.bundleIdentifier ?? ""

            switch frontID {
            case "com.apple.finder":
                self.cancelDeferredClose()
            case "", Bundle.main.bundleIdentifier ?? "–":
                break // stay open
            default:
                self.hidePanel()
            }
        }

        // Drag monitors: pause the idle timer while a drag is active.
        // These are unrelated to close-on-click and remain unchanged.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged]
        ) { [weak self] _ in
            guard let self else { return }
            self.isDragInProgress = true
            self.idleTimer?.invalidate()
            self.idleTimer = nil
        }

        localDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged]
        ) { [weak self] event in
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
                if !self.mouseInsidePanel { self.resetPanelIdleTimer() }
            }
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { _ in scheduleDragEnded() }

        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { event in scheduleDragEnded(); return event }
    }

    private func stopClickOutsideMonitor() {
        if let m = globalClickMonitor  { NSEvent.removeMonitor(m); globalClickMonitor  = nil }
        if let m = dragMonitor         { NSEvent.removeMonitor(m); dragMonitor         = nil }
        if let m = localDragMonitor    { NSEvent.removeMonitor(m); localDragMonitor    = nil }
        if let m = mouseUpMonitor      { NSEvent.removeMonitor(m); mouseUpMonitor      = nil }
        if let m = localMouseUpMonitor { NSEvent.removeMonitor(m); localMouseUpMonitor = nil }
        if let obs = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appActivationObserver = nil
        }
        isDragInProgress    = false
        isDraggingIntoPanel = false
    }

    func cancelDeferredClose() {
        // Called from isDraggingIntoPanel didSet and the activation observer
        // to abort any in-flight hidePanel that was already dispatched.
        // No-op now that scheduleDeferredClose is removed — kept as a call
        // site stub so draggingEntered callers compile unchanged.
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
        // Belt-and-suspenders "waiting on retry" tracking: subscribe to the
        // queue's backoff stream so every scheduled retry flips the flag.
        transcriptionService.startRetryObservation()
        transcriptionFloatingWidget.attach(transcription: transcriptionService)
        transcriptionFloatingWidget.onOpenTranscription = { [weak self] in
            guard let self else { return }
            self.showPanel()
        }
        // "Open Notes" on the long-running notification: open the panel on the
        // Notes tab with the Transcriptions filter applied.
        transcriptionFloatingWidget.onOpenNotes = { [weak self] in
            guard let self else { return }
            AppSettings.shared.notesActiveFilter = .transcriptions
            self.panelInteractionState.requestedTab = .notes
            self.showPanel()
        }

        // Auto-hide the panel when recording starts so the pill takes over.
        transcriptionService.$isRecording
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.hidePanel() }
            .store(in: &cancellables)

        // Mirror the signed-in user's email into TranscriptionService so Slack
        // error reports include it. Sets on login, clears on logout.
        AuthService.shared.$currentUser
            .map { $0?.email }
            .receive(on: RunLoop.main)
            .sink { [weak self] email in
                self?.transcriptionService.userEmail = email
            }
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

        // When a file is removed from storage, clear the QL focus if it was pointing there.
        fileDropStorage.$files
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.fileQuickLook.reconcileWithStorage()
            }
            .store(in: &cancellables)

        createContentPanel()
        observeSettings()

        snapDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            self?.handleSnapDrag(event)
            return event
        }
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
        let hostingView = MovableHostingView(rootView: root)

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

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        cardsView.translatesAutoresizingMaskIntoConstraints = false
        // Cards below, SwiftUI hosting on top — avoids any compositing oddities when cards are hidden.
        container.addSubview(cardsView)
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            cardsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cardsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cardsView.topAnchor.constraint(equalTo: container.topAnchor),
            cardsView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        updateCardsVsPanelHostingVisibility()

        panel.isMovableByWindowBackground = true
        panel.contentView = container
        panelHostingView = hostingView
        contentPanel = panel

        applyPanelChromeForLayoutStyle()
    }

    private func updateCardsVsPanelHostingVisibility() {
        let showAuthGate = !AuthService.shared.isSignedIn
        let cards = isCardsLayout && !showAuthGate
        panelHostingView?.isHidden = cards
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

        let hostingView = panelHostingView

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

        // Start 8 pt above final position, fade + settle down into place.
        let startFrame = targetFrame.offsetBy(dx: 0, dy: DesignTokens.PanelAnimation.openSlideOffset)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        animationToken &+= 1
        let token = animationToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DesignTokens.PanelAnimation.openDuration
            // easeInEaseOut paired with the longer duration matches the
            // pill processing animation feel — soft ease into motion,
            // slow settle at the end.
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self, self.animationToken == token else { return }
            DispatchQueue.main.async { [weak self] in
                self?.applyPanelChromeForLayoutStyle()
            }
        })

        // Don't start the click-outside monitor immediately; allow the opening click
        // to complete without accidentally closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.PanelAnimation.openDuration) { [weak self] in
            guard let self else { return }
            guard self.contentPanel?.isVisible ?? false else { return }
            self.startClickOutsideMonitor()
        }
        if let panel = contentPanel {
            fileQuickLook.installKeyMonitor(on: panel)
        }
        resetPanelIdleTimer()
    }

    func hidePanel() {
        guard let panel = contentPanel, panel.isVisible else { return }
        NotificationCenter.default.post(name: .stashPanelDidHide, object: nil)

        // Quick Look and the key monitor must go BEFORE the animation — otherwise
        // QL lingers on-screen for ~250ms after the slide-out starts, and a
        // spacebar press during that window can retrigger the monitor.
        fileQuickLook.closeQuickLookIfVisible()
        fileQuickLook.removeKeyMonitor()

        let endFrame = panel.frame.offsetBy(dx: 0, dy: DesignTokens.PanelAnimation.closeSlideOffset)
        let restoreFrame = contentPanelVisibleFrame

        animationToken &+= 1
        let token = animationToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DesignTokens.PanelAnimation.closeDuration
            // Match the open curve so dismissal has the same smoothness
            // as the appearance — symmetric motion vocabulary.
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            guard let self, let panel, self.animationToken == token else { return }
            panel.orderOut(nil)
            // Restore frame + alpha to the canonical visible target so the next
            // showPanel computes its start from the real target position, not the
            // translated close position.
            panel.setFrame(restoreFrame, display: false)
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

    private func handleSnapDrag(_ event: NSEvent) {
        guard let panel = contentPanel, event.window === panel else { return }
        switch event.type {
        case .leftMouseDown:
            snapDragStartOrigin = panel.frame.origin
        case .leftMouseUp:
            guard let start = snapDragStartOrigin else { return }
            snapDragStartOrigin = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.contentPanel else { return }
                let moved = hypot(
                    panel.frame.origin.x - start.x,
                    panel.frame.origin.y - start.y
                ) > 4
                if moved { self.snapToNearestZone() }
            }
        default:
            break
        }
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
    @State private var isHoveringCTA = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 36) {

                // MARK: Top — logo + headline
                VStack(spacing: 20) {

                    StashLogoView()
                        .frame(width: 48, height: 48)

                    (
                        Text("everything you copy, note, and record. ")
                            .foregroundColor(Color.white.opacity(0.40))
                        +
                        Text("always at hand.")
                            .foregroundColor(.white)
                    )
                    .font(.custom("Inter-SemiBold", size: 20))
                    .multilineTextAlignment(.center)
                    .textCase(.lowercase)
                    .lineSpacing(4)
                    .frame(width: 338)
                }

                // MARK: Bottom — Google button
                VStack(spacing: 0) {
                    Button {
                        Task { await AuthService.shared.signInWithGoogle() }
                    } label: {
                        HStack(spacing: 16) {
                            GoogleGIcon()
                                .frame(width: 18, height: 18)
                            Text("Continue with Google")
                                .font(.custom("Inter-Regular", size: 14))
                                .foregroundColor(Color(red: 0.04, green: 0.04, blue: 0.04))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(isHoveringCTA ? Color(white: 0.88) : Color.white)
                        .clipShape(Capsule())
                        .animation(.easeInOut(duration: 0.15), value: isHoveringCTA)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringCTA = $0 }
                    .frame(maxWidth: 500)
                    // Intentionally NOT disabled while isLoading: standard pattern
                    // (VS Code, Linear, Slack, Notion) keeps the OAuth CTA clickable
                    // throughout. If the user closes the browser tab without signing
                    // in, clicking again starts a fresh PKCE challenge — Supabase
                    // silently invalidates the prior code_verifier server-side, so
                    // there's no race. Disabling the button is what creates the
                    // dead-end recoverable only by quitting the app.

                    if let error = auth.errorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(Color.orange.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .frame(width: 300)
                            .padding(.top, 12)
                            .onTapGesture { AuthService.shared.errorMessage = nil }
                    } else if auth.isLoading {
                        Text("Waiting for browser to complete sign-in…")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .frame(width: 300)
                            .padding(.top, 12)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Stash logo (exact SVG paths — do not modify structure)

private struct StashLogoView: View {
    var body: some View {
        Image("logo")
            .resizable()
            .scaledToFit()
    }
}

// MARK: - Google G icon (official four-colour)

private struct GoogleGIcon: View {
    var body: some View {
        Image("Social Icons")
            .resizable()
            .scaledToFit()
    }
}

// MARK: - NSBezierPath SVG parser (M, L, C, Z — sufficient for Stash logo paths)

private extension NSBezierPath {
    convenience init?(svgPath: String) {
        self.init()
        let scanner = Scanner(string: svgPath)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: ", \t\n")
        var cmd: Character = "M"
        while !scanner.isAtEnd {
            if let c = scanner.scanCharacter(), c.isLetter { cmd = c }
            switch cmd {
            case "M":
                if let x = scanner.scanDouble(), let y = scanner.scanDouble() {
                    move(to: NSPoint(x: x, y: y))
                }
            case "L":
                if let x = scanner.scanDouble(), let y = scanner.scanDouble() {
                    line(to: NSPoint(x: x, y: y))
                }
            case "C":
                if let x1 = scanner.scanDouble(), let y1 = scanner.scanDouble(),
                   let x2 = scanner.scanDouble(), let y2 = scanner.scanDouble(),
                   let x  = scanner.scanDouble(), let y  = scanner.scanDouble() {
                    curve(to: NSPoint(x: x, y: y),
                          controlPoint1: NSPoint(x: x1, y: y1),
                          controlPoint2: NSPoint(x: x2, y: y2))
                }
            case "Z", "z": close()
            default: break
            }
        }
        if elementCount == 0 { return nil }
    }

    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo:    path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            case .lineTo:    path.addLine(to: CGPoint(x: points[0].x, y: points[0].y))
            case .curveTo:   path.addCurve(to: CGPoint(x: points[2].x, y: points[2].y),
                                           control1: CGPoint(x: points[0].x, y: points[0].y),
                                           control2: CGPoint(x: points[1].x, y: points[1].y))
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
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
    var panelWidth: CGFloat

    @State private var selectedTab: PanelMainTab = .all

    var body: some View {
        ZStack {
            Color.black
                .contentShape(Rectangle())
                .onTapGesture { fileQuickLook.clearSelection() }
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

                if transcription.isRecording || transcription.isProcessing {
                    RecordingBanner(
                        isProcessing: transcription.isProcessing,
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
                                onDrop: { fileDropStorage.addFiles($0) },
                                selection: fileSelection
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
            .padding(.top, 12)
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
            .onChange(of: selectedTab) { _ in
                fileQuickLook.clearSelection()
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.80))
            }

            Spacer()

            if !isProcessing && errorMessage == nil {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .overlay(Circle().stroke(Color.white.opacity(0.20), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        // Fixed 32pt pill height — kept constant across recording / processing
        // / error states (the stop button only shows while recording, so
        // without a fixed height the pill would shrink when it disappears in
        // the processing state).
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(errorMessage != nil
                    ? Color.orange.opacity(0.12)
                    : DesignTokens.Icon.tintRecording.opacity(0.15))
        )
        .padding(.bottom, 8)
    }
}
