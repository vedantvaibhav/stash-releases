import SwiftUI
import AppKit
import Carbon.HIToolbox
import Sparkle

@main
struct QuickPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No WindowGroup — menu-bar-only app. Real settings UI (incl. Layout Style) lives here
        // so Cmd+, / System Settings entry shows the same content as the status-item menu.
        Settings {
            SettingsView()
                .frame(minWidth: 480, minHeight: 620)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: PanelController?
    private var globalHotKey: GlobalHotKey?
    private var quickRecordHotKey: GlobalHotKey?
    private var hotkeyObserver: NSObjectProtocol?
    private var quickRecordHotkeyObserver: NSObjectProtocol?
    private var doubleTapObserver: NSObjectProtocol?
    private var authObserver: NSObjectProtocol?
    private var doubleTapMonitor: Any?
    private var doubleTapLocalMonitor: Any?
    private var doubleTapPressTime: Date?
    private var doubleTapLastTapTime: Date?
    private let updaterManager = UpdaterManager()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register URL scheme handler before the app finishes launching so
        // the system delivers any pending quickpanel:// events correctly.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        let bid = Bundle.main.bundleIdentifier
        let runningInstances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bid
        }
        if runningInstances.count > 1 {
            NSApp.terminate(nil)
            return
        }
    }

    /// Primary URL-scheme entry point — macOS delivers auth callbacks here when
    /// the app is already running. `.onOpenURL` is unreliable for LSUIElement apps,
    /// so the callback is handled at the NSApplication level.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "stash" || url.scheme == "quickpanel" else { continue }
            Task { @MainActor in
                await AuthService.shared.handleOAuthCallback(url: url)
            }
        }
    }

    /// Receives the quickpanel://auth/callback redirect after Google OAuth.
    @objc func handleURL(_ event: NSAppleEventDescriptor,
                         withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        Task { await AuthService.shared.handleOAuthCallback(url: url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        APIKeys.validateKeys()

        setupStatusItem()

        panelController = PanelController()

        registerHotkeyFromSettings()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .quickPanelHotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerHotkeyFromSettings()
        }

        quickRecordHotkeyObserver = NotificationCenter.default.addObserver(
            forName: .quickRecordHotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerHotkeyFromSettings()
        }

        doubleTapObserver = NotificationCenter.default.addObserver(
            forName: .doubleTapQuickRecordChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.installDoubleTapMonitor() }

        authObserver = NotificationCenter.default.addObserver(
            forName: .authCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAuthReady()
        }

        panelController?.setup()

        installDoubleTapMonitor()

        Task {
            await AuthService.shared.checkSession()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKey?.unregister()
        quickRecordHotKey?.unregister()
        if let obs = hotkeyObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = quickRecordHotkeyObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = doubleTapObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = authObserver { NotificationCenter.default.removeObserver(obs) }
        if let m = doubleTapMonitor { NSEvent.removeMonitor(m); doubleTapMonitor = nil }
        if let m = doubleTapLocalMonitor { NSEvent.removeMonitor(m); doubleTapLocalMonitor = nil }
    }

    // MARK: - Auth routing (onboarding gate)

    /// Called on `.authCompleted`. Decides whether to present the onboarding
    /// window or do nothing. Panel auto-show on fresh sign-in is handled by
    /// AuthService's wrapped showPanel(); session-restore intentionally does
    /// not auto-show the panel.
    private func handleAuthReady() {
        if AppSettings.shared.hasCompletedOnboarding { return }
        // Signed in here = "advance past auth screen straight to hotkeys";
        // not signed in = "start at auth screen" (only reachable via the
        // status-item-click path, since handleAuthReady is fired by
        // .authCompleted which implies signed-in by the time we arrive).
        let start = AuthService.shared.isSignedIn ? 1 : 0
        presentOnboarding(startStep: start)
    }

    private func presentOnboarding(startStep: Int = 0) {
        OnboardingWindowController.shared.present(startStep: startStep) { [weak self] in
            AppSettings.shared.hasCompletedOnboarding = true
            self?.panelController?.togglePanel()
        }
    }

    // MARK: - Hotkey registration

    private func registerHotkeyFromSettings() {
        globalHotKey?.unregister()
        let s = AppSettings.shared
        // Main panel toggle — signature 'QPHK'
        globalHotKey = GlobalHotKey(keyCode: s.hotKeyCode, modifiers: s.hotKeyModifiers,
                                    signature: 0x51_50_48_4B) { [weak self] in
            self?.panelController?.togglePanel()
        }
        _ = globalHotKey?.register()

        // Quick record — 0xFFFE = double-tap sentinel (handled by installDoubleTapMonitor),
        // 0 = never configured. Neither needs a Carbon hotkey.
        quickRecordHotKey?.unregister()
        quickRecordHotKey = nil
        let qrCode = s.quickRecordHotKeyCode
        if qrCode != 0xFFFE && qrCode != 0 {
            let qrMods = s.quickRecordHotKeyModifiers
            quickRecordHotKey = GlobalHotKey(keyCode: qrCode,
                                             modifiers: qrMods,
                                             signature: 0x51_50_52_4B) { [weak self] in
                guard let ts = self?.panelController?.transcriptionService else { return }
                if ts.isRecording {
                    ts.stopRecording()
                } else {
                    guard AuthService.shared.isSignedIn else {
                        self?.panelController?.showPanel()
                        return
                    }
                    ts.startRecording()
                }
            }
            _ = quickRecordHotKey?.register()
        }
    }

    // MARK: - Double-tap monitor

    private func installDoubleTapMonitor() {
        if let m = doubleTapMonitor { NSEvent.removeMonitor(m); doubleTapMonitor = nil }
        if let m = doubleTapLocalMonitor { NSEvent.removeMonitor(m); doubleTapLocalMonitor = nil }
        doubleTapPressTime = nil
        doubleTapLastTapTime = nil

        let setting = AppSettings.shared.doubleTapQuickRecord
        guard setting != .off else { return }
        let targetFlag: NSEvent.ModifierFlags
        switch setting {
        case .command: targetFlag = .command
        case .option:  targetFlag = .option
        case .control: targetFlag = .control
        case .shift:   targetFlag = .shift
        case .off:     return
        }

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let isDown = event.modifierFlags.intersection(targetFlag) == targetFlag
            let now = Date()
            if isDown {
                self.doubleTapPressTime = now
            } else {
                guard let pressTime = self.doubleTapPressTime,
                      now.timeIntervalSince(pressTime) < 0.35 else {
                    self.doubleTapPressTime = nil
                    self.doubleTapLastTapTime = nil
                    return
                }
                self.doubleTapPressTime = nil
                if let lastTap = self.doubleTapLastTapTime,
                   now.timeIntervalSince(lastTap) < 0.45 {
                    self.doubleTapLastTapTime = nil
                    DispatchQueue.main.async { self.handleDoubleTapTrigger() }
                } else {
                    self.doubleTapLastTapTime = now
                }
            }
        }

        // Global monitor — fires when another app is frontmost.
        doubleTapMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)

        // Local monitor — global monitors are silent for the app's own events,
        // so this catches double-taps while Stash itself is key (e.g. right after login).
        doubleTapLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    @MainActor
    private func handleDoubleTapTrigger() {
        guard let ts = panelController?.transcriptionService else { return }
        if ts.isRecording {
            ts.stopRecording()
        } else {
            guard AuthService.shared.isSignedIn else {
                panelController?.showPanel()
                return
            }
            ts.startRecording()
        }
    }

    // MARK: - Status item setup

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(named: "menu-bar-icon")
        icon?.isTemplate = true
        icon?.size = NSSize(width: 15, height: 15)
        statusItem?.button?.image = icon
        statusItem?.button?.imagePosition = .imageLeading
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(statusItemClicked)
        // Listen for both left- and right-click on the icon.
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseDown])
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseDown {
            showStatusMenu()
            return
        }

        if !AppSettings.shared.hasCompletedOnboarding {
            let start = AuthService.shared.isSignedIn ? 1 : 0
            presentOnboarding(startStep: start)
            return
        }

        panelController?.togglePanel()
    }

    // MARK: - Right-click context menu

    private func showStatusMenu() {
        let menu = NSMenu()

        let updatesItem = NSMenuItem(title: "Check for Updates",
                                     action: #selector(checkForUpdates),
                                     keyEquivalent: "")
        updatesItem.target = self
        updatesItem.image = nil

        let settingsItem = NSMenuItem(title: "Settings",
                                      action: #selector(openSettingsWindow),
                                      keyEquivalent: "")
        settingsItem.target = self
        settingsItem.image = nil

        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(quitApp),
                                  keyEquivalent: "")
        quitItem.target = self
        quitItem.image = nil

        menu.addItem(updatesItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        #if DEBUG
        let resetItem = NSMenuItem(
            title: "Reset onboarding (debug)",
            action: #selector(resetOnboardingDebug),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(.separator())
        menu.addItem(resetItem)

        // Debug ▸ submenu — fires every toast variant for UI testing.
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let debugSubmenu = NSMenu(title: "Debug")
        for (title, selector) in debugMenuItems() {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            debugSubmenu.addItem(item)
        }
        debugItem.submenu = debugSubmenu
        menu.addItem(debugItem)
        #endif

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func togglePanelFromMenu() {
        panelController?.togglePanel()
    }

    @objc private func checkForUpdates() {
        updaterManager.checkForUpdates()
    }

    @objc private func openSettingsWindow() {
        SettingsWindowController.shared.showSettings()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    #if DEBUG
    @objc private func resetOnboardingDebug() {
        // Sign the user out too so the reset reproduces the full first-launch
        // path: onboarding lands at screen 1 (auth) every time. Without this,
        // hasCompletedOnboarding=false + isSignedIn=true would route to
        // screen 2 (hotkeys), skipping the auth screen we want to test.
        Task { @MainActor in
            await AuthService.shared.signOut()
            AppSettings.shared.hasCompletedOnboarding = false
            OnboardingWindowController.shared.reset()
            presentOnboarding(startStep: 0)
        }
    }

    /// Map of debug-submenu titles to their `@objc` selectors. Defined as a
    /// method (not a stored array) so the selectors resolve at call-site
    /// against `self` rather than at file load.
    private func debugMenuItems() -> [(String, Selector)] {
        return [
            ("Test toast: hallucination rejection",   #selector(debugTestToastRejection)),
            ("Test toast: cleanup failure",           #selector(debugTestToastCleanupFailure)),
            ("Test toast: network timeout",           #selector(debugTestToastNetworkTimeout)),
            ("Test toast: 85-min warning",            #selector(debugTestToast85MinWarning)),
            ("Test toast: 90-min hard-stop",          #selector(debugTestToast90MinHardStop)),
            ("Test toast: 20-MB warning",             #selector(debugTestToast20MBWarning)),
            ("Test toast: 24-MB hard-stop",           #selector(debugTestToast24MBHardStop)),
            ("Test toast: stacking (3 in a row)",     #selector(debugTestToastStacking))
        ]
    }

    private func debugFireToast(_ text: String, hold: TimeInterval) {
        guard let svc = panelController?.transcriptionService else { return }
        svc.debugShowToast(TranscriptionToastMessage(text: text, hold: hold))
    }

    @objc private func debugTestToastRejection() {
        debugFireToast("No audio — try speaking closer to the mic.",
                       hold: DesignTokens.Pill.toastDefaultHoldDuration)
    }
    @objc private func debugTestToastCleanupFailure() {
        debugFireToast("Couldn't clean the transcript — saved the raw version.",
                       hold: DesignTokens.Pill.toastDefaultHoldDuration)
    }
    @objc private func debugTestToastNetworkTimeout() {
        debugFireToast("Network timed out — try again.",
                       hold: DesignTokens.Pill.toastDefaultHoldDuration)
    }
    @objc private func debugTestToast85MinWarning() {
        debugFireToast("Recording will stop in 5 min — start a new session for more.",
                       hold: DesignTokens.Pill.toastWarningHoldDuration)
    }
    @objc private func debugTestToast90MinHardStop() {
        debugFireToast("Recording stopped at 90-min limit. Processing what was captured.",
                       hold: DesignTokens.Pill.toastDefaultHoldDuration)
    }
    @objc private func debugTestToast20MBWarning() {
        debugFireToast("Approaching upload limit — recording will stop soon. Start a new session for more.",
                       hold: DesignTokens.Pill.toastWarningHoldDuration)
    }
    @objc private func debugTestToast24MBHardStop() {
        debugFireToast("Recording stopped — file size limit reached. Processing what was captured.",
                       hold: DesignTokens.Pill.toastDefaultHoldDuration)
    }
    @objc private func debugTestToastStacking() {
        // Fire three toasts 300ms apart so the stack-swap animation is visible.
        debugFireToast("First toast", hold: DesignTokens.Pill.toastDefaultHoldDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.debugFireToast("Second toast", hold: DesignTokens.Pill.toastDefaultHoldDuration)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.debugFireToast("Third toast", hold: DesignTokens.Pill.toastDefaultHoldDuration)
        }
    }
    #endif
}
