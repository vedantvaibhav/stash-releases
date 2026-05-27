import AppKit
import SwiftUI

/// Bottom-center floating panel hosting a `TranscriptionStatusNotification`.
/// Mirrors the `PillPanel` pattern from the floating widget: borderless,
/// non-activating, floating window level, content-sized so clicks outside
/// its bounds pass straight through to whatever is behind it.
final class TranscriptionStatusPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Copy + actions for the status notification. Mutable so the presenter can
/// morph the copy in place (e.g., "Taking longer than usual" → "Still trying")
/// without tearing the panel down.
struct StatusNotificationModel {
    var title: String
    var message: String
    var primaryLabel: String
    var primaryAction: () -> Void
    var secondaryLabel: String
    var secondaryAction: () -> Void
    var onDismiss: () -> Void
}

/// Presents / morphs / dismisses the bottom-center status panel with a
/// slide-up entrance and slide-down + fade exit. MainActor-bound: all AppKit
/// work happens on the main thread.
@MainActor
final class StatusNotificationPresenter {
    private var panel: TranscriptionStatusPanel?
    private var hosting: NSHostingView<TranscriptionStatusNotification>?

    private let panelWidth: CGFloat = 340
    private let bottomInset: CGFloat = 32   // ~32pt above the dock / visible bottom

    var isVisible: Bool { panel != nil }

    /// Show the notification, or morph the copy if it's already visible.
    func show(_ model: StatusNotificationModel) {
        if panel == nil {
            build(model)
            animateIn()
        } else {
            update(model)
        }
    }

    /// Swap the hosted content in place (copy morph) and re-anchor the frame
    /// in case the new copy changed the intrinsic height.
    func update(_ model: StatusNotificationModel) {
        guard let panel, let hosting else { return }
        hosting.rootView = makeView(model)
        let size = NSSize(width: panelWidth, height: hosting.fittingSize.height)
        let screen = panel.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(frame(for: size, in: visible), display: true)
    }

    /// Slide down + fade out, then tear the panel down.
    func hide() {
        guard let panel else { return }
        let end = panel.frame.offsetBy(dx: 0, dy: -16)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
            self?.hosting = nil
        })
    }

    // MARK: - Private

    private func makeView(_ model: StatusNotificationModel) -> TranscriptionStatusNotification {
        TranscriptionStatusNotification(
            title: model.title,
            message: model.message,
            primaryLabel: model.primaryLabel,
            primaryAction: model.primaryAction,
            secondaryLabel: model.secondaryLabel,
            secondaryAction: model.secondaryAction,
            onDismiss: model.onDismiss
        )
    }

    private func build(_ model: StatusNotificationModel) {
        let host = NSHostingView(rootView: makeView(model))
        let height = host.fittingSize.height
        let size = NSSize(width: panelWidth, height: height)

        let p = TranscriptionStatusPanel(contentRect: NSRect(origin: .zero, size: size))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        hosting = host
        panel = p
    }

    private func animateIn() {
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let target = frame(for: size, in: visible)
        // Start 16pt lower + transparent, then slide up + fade in.
        panel.setFrame(target.offsetBy(dx: 0, dy: -16), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func frame(for size: NSSize, in visible: NSRect) -> NSRect {
        let x = visible.midX - size.width / 2
        let y = visible.minY + bottomInset
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
