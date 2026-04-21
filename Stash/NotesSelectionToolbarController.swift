import AppKit
import Combine
import SwiftUI

/// Owns the floating `.nonactivatingPanel` that renders the selection toolbar
/// above the user's current selection in an `NSTextView`. The panel is hosted
/// via `NSHostingView<NotesSelectionToolbar>`; we reassign `rootView` on state
/// change (standalone `NSHostingView` pattern — safe to assign outside an
/// NSViewRepresentable update cycle).
///
/// `@MainActor`: every method touches AppKit (`NSPanel`, `NSTextView`,
/// `NSEvent` monitors, `NSHostingView.rootView` reassignment) — all of which
/// are main-thread-only. Explicit annotation mirrors the pattern used by
/// `TranscriptionFloatingWidgetController` in this codebase.
@MainActor
final class NotesSelectionToolbarController: NSObject {

    // Weak — the text view owns its window, the coordinator owns us.
    private weak var textView: NSTextView?

    private var panel: NotesSelectionToolbarPanel?
    private var hosting: NSHostingView<NotesSelectionToolbar>?
    private let state = NotesSelectionToolbarState()

    private var cancellables: Set<AnyCancellable> = []
    private var escapeMonitor: Any?
    private var didAttachWindowObservers = false
    private var didAttachScrollObserver = false
    private var linkPopover: NSPopover?
    private var linkPopoverEscapeMonitor: Any?

    var onCommand: ((ToolbarCommand) -> Void)?

    // MARK: Lifecycle

    func attach(to textView: NSTextView) {
        self.textView = textView
        // We cannot subscribe to the enclosing scroll view or window here —
        // during `makeNSView`, the text view has not been added to a window
        // hierarchy yet, so `textView.window` and `enclosingScrollView` are
        // both nil. Defer to `ensureObserversAttached`, called lazily from
        // the first `syncWithSelection` once the view is live.
    }

    func detach() {
        hide()
        cancellables.removeAll()
        textView = nil
        didAttachWindowObservers = false
        didAttachScrollObserver = false
    }

    /// Called from `syncWithSelection` once we know `textView` is in a window.
    private func ensureObserversAttached() {
        guard let textView else { return }

        if !didAttachScrollObserver, let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default
                .publisher(for: NSView.boundsDidChangeNotification, object: clipView)
                .sink { [weak self] _ in self?.repositionIfVisible() }
                .store(in: &cancellables)
            didAttachScrollObserver = true
        }

        if !didAttachWindowObservers, let window = textView.window {
            NotificationCenter.default
                .publisher(for: NSWindow.didMoveNotification, object: window)
                .sink { [weak self] _ in self?.repositionIfVisible() }
                .store(in: &cancellables)
            NotificationCenter.default
                .publisher(for: NSWindow.didResizeNotification, object: window)
                .sink { [weak self] _ in self?.repositionIfVisible() }
                .store(in: &cancellables)
            NotificationCenter.default
                .publisher(for: NSWindow.willCloseNotification, object: window)
                .sink { [weak self] _ in self?.hide() }
                .store(in: &cancellables)
            didAttachWindowObservers = true
        }
    }

    // MARK: Public API

    /// Called from the text view's delegate on every selection change.
    func syncWithSelection() {
        guard let textView else { hide(); return }
        ensureObserversAttached()
        guard textView.window?.firstResponder === textView else {
            hide()
            return
        }
        let selectedRange = textView.selectedRange()
        if selectedRange.length == 0 {
            hide()
            return
        }
        ensurePanel()
        repositionIfVisible()
        panel?.orderFrontRegardless()
        installEscapeMonitor()
    }

    func updateActiveState(_ newState: NotesSelectionToolbarState.Snapshot) {
        if state.snapshot == newState { return }
        state.apply(newState)
    }

    func hide() {
        panel?.orderOut(nil)
        removeEscapeMonitor()
    }

    func presentLinkPopover(initialURL: String?,
                            onApply: @escaping (String) -> Void) {
        guard let panel, let hostingView = panel.contentView else { return }

        let popover = NSPopover()
        popover.behavior = .transient   // dismisses on clicks outside
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: NotesLinkPopover(
            initialURL: initialURL,
            onApply: { [weak popover, weak self] url in
                onApply(url)
                popover?.performClose(nil)
                self?.removeLinkPopoverEscapeMonitor()
            }
        ))
        // Anchor to the full toolbar panel rect; minY edge so popover appears below the toolbar.
        popover.show(relativeTo: hostingView.bounds, of: hostingView, preferredEdge: .minY)
        linkPopover = popover

        // `.transient` dismisses on outside clicks but NOT on Escape; install a
        // local key monitor that closes the popover when Escape fires. Scope
        // the monitor to events landing on the popover's window so other
        // Escape handlers (e.g., the toolbar's own monitor) still fire
        // normally when the popover isn't shown.
        linkPopoverEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak popover] event in
            guard event.keyCode == 53 else { return event }
            guard let popover, popover.isShown else { return event }
            popover.performClose(nil)
            self?.removeLinkPopoverEscapeMonitor()
            return nil
        }

        // Catch outside-click dismissal too — `.transient` closes the popover
        // without calling our apply / escape paths, so without this the
        // escape monitor would leak until the next `presentLinkPopover`
        // overwrites it. Observing `didCloseNotification` covers all three
        // dismissal paths uniformly.
        NotificationCenter.default
            .publisher(for: NSPopover.didCloseNotification, object: popover)
            .sink { [weak self] _ in
                self?.removeLinkPopoverEscapeMonitor()
                self?.linkPopover = nil
            }
            .store(in: &cancellables)
    }

    private func removeLinkPopoverEscapeMonitor() {
        if let monitor = linkPopoverEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            linkPopoverEscapeMonitor = nil
        }
    }

    // MARK: Internals

    private func ensurePanel() {
        if panel != nil { return }

        let initial = NotesSelectionToolbar(state: state, onCommand: { [weak self] command in
            self?.onCommand?(command)
        })
        let host = NSHostingView(rootView: initial)
        // Fitting size drives the panel frame; SwiftUI `.fixedSize()` inside
        // the toolbar keeps the pill hug-width.
        host.translatesAutoresizingMaskIntoConstraints = false

        let contentSize = host.fittingSize
        let p = NotesSelectionToolbarPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        p.contentView = host
        panel = p
        hosting = host
    }

    /// Computes the anchor rect in screen coords: 8 pt above selection's minY,
    /// flipped below maxY + 8 when the panel would clip offscreen-top.
    private func repositionIfVisible() {
        guard let panel, let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let window = textView.window
        else { return }

        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0 else { hide(); return }

        // glyph range corresponds to the selected characters in the text container.
        let glyphRange = layoutManager.glyphRange(forCharacterRange: selectedRange, actualCharacterRange: nil)
        let selectionRectInContainer = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

        // Offset by the text container's inset so it's in textView coords, not container coords.
        let inset = textView.textContainerInset
        var selectionRectInView = selectionRectInContainer
        selectionRectInView.origin.x += inset.width
        selectionRectInView.origin.y += inset.height

        // Hide if the selection scrolls entirely out of the visible rect by
        // more than the toolbar's own height.
        if let scrollView = textView.enclosingScrollView {
            let visible = scrollView.documentVisibleRect
            let toolbarH = panel.frame.height
            if selectionRectInView.maxY < visible.minY - toolbarH ||
               selectionRectInView.minY > visible.maxY + toolbarH {
                panel.orderOut(nil)
                return
            }
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }

        // view → window → screen.
        let rectInWindow = textView.convert(selectionRectInView, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)

        let toolbarSize = panel.frame.size
        let gap: CGFloat = 8
        let centerX = rectOnScreen.midX - toolbarSize.width / 2

        // Prefer above, flip below if that puts us offscreen-top.
        var targetY = rectOnScreen.maxY + gap
        if let screen = window.screen {
            let screenMaxY = screen.visibleFrame.maxY
            if targetY + toolbarSize.height > screenMaxY {
                targetY = rectOnScreen.minY - gap - toolbarSize.height
            }
        }

        panel.setFrameOrigin(NSPoint(x: centerX, y: targetY))
    }

    // MARK: Escape monitor

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    // `NSEvent.removeMonitor(_:)` is `nonisolated`, so it's safe to call from
    // the @MainActor class's (implicitly nonisolated) deinit. Without this the
    // escape + link-popover monitors would leak when SwiftUI tears down the
    // NSViewRepresentable and the coordinator releases the controller.
    deinit {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = linkPopoverEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

/// Borderless, non-activating, never-key panel so clicks inside the toolbar
/// don't steal first-responder from the text view.
final class NotesSelectionToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Commands + state snapshot

enum ToolbarCommand {
    case bold
    case italic
    case underline
    case strikethrough
    case inlineCode
    case heading(HeadingLevel)
    case link
    case color   // stub — no-op for v1
    case more    // stub — no-op for v1
}

enum HeadingLevel: Equatable {
    case paragraph
    case h1
    case h2
    case h3
}

enum TextFormat: Hashable {
    case bold, italic, underline, strikethrough, inlineCode, link
}

final class NotesSelectionToolbarState: ObservableObject {
    struct Snapshot: Equatable {
        var activeFormats: Set<TextFormat> = []
        var heading: HeadingLevel = .paragraph
    }

    @Published private(set) var snapshot = Snapshot()

    func apply(_ next: Snapshot) {
        snapshot = next
    }
}
