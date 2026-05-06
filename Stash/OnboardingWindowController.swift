import AppKit
import SwiftUI

/// Owns the lifecycle of the onboarding NSWindow. Rounded corners, transparent
/// background with OS drop shadow, traffic-lights hidden. Content is a SwiftUI
/// `OnboardingView` hosted via `NSHostingView`.
///
/// `.titled` + `.closable` stay in the styleMask so ⌘W still routes through the
/// system's standard close path. The title bar is made invisible via
/// `titlebarAppearsTransparent` + `titleVisibility = .hidden` and all three
/// standard buttons are hidden — the rounded contentView paints over the area.
/// `.miniaturizable` and `.resizable` are deliberately absent so ⌘M and ⌘+
/// no-op.
///
/// State lives on `OnboardingViewModel`, owned by this controller, so the user
/// can ⌘W mid-flow and re-open via the menu-bar status item without losing
/// their place. App-quit + relaunch resets state because the singleton is
/// recreated.
///
/// Required to be a custom NSWindow (not SwiftUI WindowGroup) because Stash is
/// `LSUIElement = true` — accessory apps don't get a proper SwiftUI window scene.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    static let shared = OnboardingWindowController()

    let viewModel = OnboardingViewModel()

    private var onCompletion: (() -> Void)?
    private var didFireCompletion = false
    private var hasInstalledHosting = false

    private init() {
        let size = DesignTokens.Onboarding.windowSize
        let rect = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Remove the 1pt separator line macOS draws under the title bar by
        // default — without this the rounded panel reads as having a subtle
        // top border. macOS 11+; deployment target is 13+ so unconditional.
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        // Close (red) stays visible as the user's escape hatch. miniaturize
        // and zoom are absent from the styleMask so they grey out automatically.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        // Transparent window so the rounded content layer's edge is the visible
        // boundary; `hasShadow = true` makes the OS render a drop shadow that
        // follows the rounded shape.
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .normal

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OnboardingWindowController is not loadable from a nib")
    }

    /// Show the onboarding window. The first call installs the hosting view at
    /// `startStep`; subsequent calls just bring the window forward, preserving
    /// the view model's step. `completion` runs exactly once when the user
    /// reaches the done CTA (or the window is dismissed through any other path).
    func present(startStep: Int = 0, completion: @escaping () -> Void) {
        onCompletion = completion
        didFireCompletion = false

        if !hasInstalledHosting {
            viewModel.setInitialStep(startStep)
            let view = OnboardingView(model: viewModel) { [weak self] in
                self?.finish()
            }
            let hosting = NSHostingView(rootView: view)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            // Round the content view's corners. Clipping happens at the layer
            // level so child SwiftUI content paints inside the rounded shape.
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = DesignTokens.Onboarding.windowCornerRadius
            hosting.layer?.masksToBounds = true
            window?.contentView = hosting
            hasInstalledHosting = true
        }

        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    /// Tear down the hosting view and step state. The next `present(...)` call
    /// reinstalls fresh content. Used by the DEBUG reset menu item.
    func reset() {
        hasInstalledHosting = false
        window?.contentView = nil
        viewModel.step = 0
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
        // Fires only when the user reaches the done CTA (which calls finish() →
        // close()). User-initiated ⌘W or red-button dismissal is intentionally
        // NOT treated as completion — viewModel state is preserved so the
        // status-item-click reopen lands on the same screen.
        if didFireCompletion { return }
        // Drop the completion handle so a stale closure doesn't fire on the next
        // present(...). The view model stays intact.
        onCompletion = nil
    }
}
