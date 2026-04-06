import AppKit
import SwiftUI
import Combine
import CoreGraphics

extension Notification.Name {
    static let quickPanelUserInteraction = Notification.Name("QuickPanelUserInteraction")
    static let quickPanelShouldShow = Notification.Name("QuickPanelShouldShow")
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
           !isPasteTargetedAtTextInput {
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

    private var isPasteTargetedAtTextInput: Bool {
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

    // Double-click-outside to close + drag-state monitoring (idle timer pauses while dragging)
    private var globalClickMonitor: Any?
    private var lastClickTime: Date?
    private var lastClickLocation: NSPoint?
    private var isDragInProgress = false
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
        NotificationCenter.default.addObserver(
            forName: .quickPanelShouldShow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !(self.contentPanel?.isVisible ?? false) else { return }
            self.showPanel()
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

    // MARK: - Double-click outside + drag monitoring

    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] _ in
            guard let self = self,
                  let panel = self.contentPanel,
                  panel.isVisible else { return }

            if self.isDragInProgress { return }

            let clickLocation = NSEvent.mouseLocation

            if panel.frame.insetBy(dx: -5, dy: -5).contains(clickLocation) {
                self.lastClickTime = nil
                self.lastClickLocation = nil
                return
            }

            let now = Date()

            if let lastTime = self.lastClickTime,
               let lastLoc = self.lastClickLocation,
               now.timeIntervalSince(lastTime) < 0.4,
               hypot(clickLocation.x - lastLoc.x, clickLocation.y - lastLoc.y) < 20 {
                self.lastClickTime = nil
                self.lastClickLocation = nil
                print("[Panel] Double click outside — hiding")
                DispatchQueue.main.async { self.hidePanel() }
            } else {
                self.lastClickTime = now
                self.lastClickLocation = clickLocation
                print("[Panel] Single click outside — ignoring")
            }
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
        lastClickTime = nil
        lastClickLocation = nil
        isDragInProgress = false
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
        transcriptionService.notesStorage = notesStorage
        transcriptionService.makePanelKey = { [weak self] in
            self?.contentPanel?.makeKeyAndOrderFront(nil)
        }
        transcriptionFloatingWidget.attach(transcription: transcriptionService)
        transcriptionFloatingWidget.onOpenTranscription = { [weak self] in
            guard let self else { return }
            self.panelInteractionState.showTranscriptionPage = true
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
            panelInteraction: panelInteractionState
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
            panelController: self
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
        let cards = isCardsLayout
        panelHostingController?.view.isHidden = cards
        cardsModeContainer?.isHidden = !cards
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

struct QuickPanelRootView: View {
    var makePanelKey: () -> Void
    @ObservedObject var fileDropStorage: FileDropStorage
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var notesStorage: NotesStorage
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var panelInteraction: PanelInteractionState

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            if settings.layoutStyle == .panel {
                PanelContentView(
                    makePanelKey: makePanelKey,
                    fileDropStorage: fileDropStorage,
                    clipboard: clipboard,
                    notesStorage: notesStorage,
                    transcription: transcription,
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
    }
}

// MARK: - Wide panel layout

struct PanelContentView: View {
    var makePanelKey: () -> Void
    @ObservedObject var fileDropStorage: FileDropStorage
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var notesStorage: NotesStorage
    @ObservedObject var transcription: TranscriptionService
    @Binding var showTranscriptionPage: Bool
    @Binding var editingNoteId: String?
    @Binding var noteToDelete: NoteItem?
    @Binding var fileToDelete: DroppedFileItem?
    var panelWidth: CGFloat

    @State private var selectedTab: PanelMainTab = .all

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 16) {
                TabBarView(
                    selectedTab: $selectedTab,
                    onMicTap: {
                        showTranscriptionPage = true
                        transcription.startRecording()
                    }
                )

                ZStack {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(selectedTab == .all ? 1 : 0)
                    .allowsHitTesting(selectedTab == .all)

                    SharedClipboardColumn(clipboard: clipboard, forCardsMode: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(selectedTab == .clipboard ? 1 : 0)
                        .allowsHitTesting(selectedTab == .clipboard)

                    SharedFilesColumn(
                        fileDropStorage: fileDropStorage,
                        fileToDelete: $fileToDelete,
                        forCardsMode: false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(selectedTab == .files ? 1 : 0)
                    .allowsHitTesting(selectedTab == .files)

                    SharedNotesColumn(
                        makePanelKey: makePanelKey,
                        notesStorage: notesStorage,
                        transcription: transcription,
                        showTranscriptionPage: $showTranscriptionPage,
                        editingNoteId: $editingNoteId,
                        noteToDelete: $noteToDelete,
                        forCardsMode: false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(selectedTab == .notes ? 1 : 0)
                    .allowsHitTesting(selectedTab == .notes)

                    // Redirects file drags on Clipboard/Notes tabs → switches to Files tab.
                    // Returns [] on All and Files tabs so those panels handle it themselves.
                    FileDragTabRedirectRepresentable(
                        isActive: selectedTab == .clipboard || selectedTab == .notes,
                        onFilesDragEntered: { selectedTab = .files },
                        onFilesDropped: { fileDropStorage.addFiles($0) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)

                    // Topmost drop zone — intercepts file drags on the All tab.
                    // Returns [] when another tab is active so SharedFilesColumn handles it.
                    AllTabDropZoneRepresentable(
                        isActive: selectedTab == .all,
                        onDrop: { fileDropStorage.addFiles($0) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.15), value: selectedTab)
            }
            .padding(20)
            .frame(maxWidth: 700, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
