import AppKit
import SwiftUI

/// Owns the lifecycle of the onboarding NSWindow. Opaque, centered, no
/// traffic-light buttons, non-resizable. Content is a SwiftUI `OnboardingView`
/// hosted via `NSHostingView`.
///
/// Required to be a custom NSWindow (not SwiftUI WindowGroup) because Stash is
/// `LSUIElement = true` — accessory apps don't get a proper SwiftUI window scene.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    static let shared = OnboardingWindowController()

    private var onCompletion: (() -> Void)?
    private var didFireCompletion = false

    private init() {
        let size = DesignTokens.Onboarding.windowSize
        let rect = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.black
        window.isOpaque = true
        window.level = .normal

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OnboardingWindowController is not loadable from a nib")
    }

    /// Show the onboarding window. `completion` runs exactly once when the user
    /// finishes the last step (or the window is closed through any other path).
    /// Caller is responsible for marking `hasCompletedOnboarding` and opening
    /// the panel.
    func present(completion: @escaping () -> Void) {
        onCompletion = completion
        didFireCompletion = false

        let view = OnboardingView { [weak self] in
            self?.finish()
        }
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = hosting

        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    private func finish() {
        guard !didFireCompletion else { return }
        didFireCompletion = true
        let cb = onCompletion
        onCompletion = nil
        close()
        cb?()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish()
    }
}
