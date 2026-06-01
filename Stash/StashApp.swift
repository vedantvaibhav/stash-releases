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

        NetworkReachability.shared.start()

        // PanelController must exist before the queue's uploadHandler closure
        // can resolve `transcriptionService`. The handler is invoked on
        // queue.drainNow() further down — initialize the controller first.
        panelController = PanelController()

        // Single launch Task orchestrates queue wiring → hotkey/observer
        // registration in a fixed order so a global-hotkey press in the
        // first ms of launch can't enqueue against a nil uploadHandler:
        //   1. bootstrap()     — load pending sessions from disk
        //   2. setUploadHandler — wire the queue's call back into the service
        //   3. drainNow()      — pick up orphans from a prior crash
        //   4. registerHotkeyFromSettings + observers + installDoubleTapMonitor
        // Any user-facing input surface is registered ONLY after step 2.
        Task { @MainActor [weak self] in
            await TranscriptionRetryQueue.shared.bootstrap()
            // Wire the upload handler before draining. The closure captures
            // [weak self] so it doesn't retain the AppDelegate; it reaches
            // through self?.panelController?.transcriptionService at call
            // time (which is when the queue attempts an upload).
            await TranscriptionRetryQueue.shared.setUploadHandler { [weak self] meta in
                guard let svc = self?.panelController?.transcriptionService else { return false }
                return try await svc.uploadSession(metadata: meta)
            }
            // Drain after bootstrap regardless of online state. If offline, attempts
            // fail and the queue's retry policy handles backoff + eventual recovery
            // via the onSatisfied transition. If online (the common case after a
            // crash-recover relaunch), this drains immediately — without it, sessions
            // would sit forever because onSatisfied never fires on the initial
            // satisfied state.
            await TranscriptionRetryQueue.shared.drainNow()

            // Hotkey + recording observers go up AFTER the queue is fully wired.
            // Before this point, a user pressing the global hotkey could trigger
            // recording → enqueue → drain attempt → no handler → silent failure.
            self?.registerHotkeyFromSettings()

            self?.hotkeyObserver = NotificationCenter.default.addObserver(
                forName: .quickPanelHotkeyChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.registerHotkeyFromSettings()
            }

            self?.quickRecordHotkeyObserver = NotificationCenter.default.addObserver(
                forName: .quickRecordHotkeyChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.registerHotkeyFromSettings()
            }

            self?.doubleTapObserver = NotificationCenter.default.addObserver(
                forName: .doubleTapQuickRecordChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.installDoubleTapMonitor() }

            self?.installDoubleTapMonitor()
        }
        NetworkReachability.shared.onSatisfied = {
            Task {
                await TranscriptionRetryQueue.shared.drainNow()
            }
        }

        // Auth is independent of the recording pipeline — observer + check
        // can wire up immediately. Signed-in state doesn't gate queue work.
        authObserver = NotificationCenter.default.addObserver(
            forName: .authCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAuthReady()
        }

        panelController?.setup()

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

        // Debug ▸ submenu — fires every pill completion variant for UI testing.
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
            ("Test pill: filter rejection",  #selector(debugTestPillRejection)),
            ("Test pill: cleanup failure",   #selector(debugTestPillCleanupFailure)),
            ("Test pill: network timeout",   #selector(debugTestPillNetworkTimeout)),
            ("Test pill: 5 min warning",     #selector(debugTestPill5MinWarning)),
            ("Test pill: 90-min hard stop",  #selector(debugTestPill90MinHardStop)),
            ("Test pill: 20-MB warning",     #selector(debugTestPill20MBWarning)),
            ("Test pill: 24-MB hard stop",   #selector(debugTestPill24MBHardStop)),
            ("Test pill: state stacking",    #selector(debugTestPillStacking)),
            ("Test: simulate network failure on next upload", #selector(debugSimulateNextUploadFailure)),
            ("Test: drain retry queue now",  #selector(debugDrainRetryQueue)),
            ("Test: list pending sessions",  #selector(debugListPendingSessions)),
            ("Test: show status notification", #selector(debugShowStatusNotification)),
        ]
    }

    private func debugFirePill(_ text: String, hold: TimeInterval = DesignTokens.Pill.completionDefaultHold) {
        guard let svc = panelController?.transcriptionService else { return }
        svc.debugShowCompletion(text, hold: hold)
    }

    @objc private func debugTestPillRejection()      { debugFirePill("No audio") }
    @objc private func debugTestPillCleanupFailure() { debugFirePill("Note saved") }
    @objc private func debugTestPillNetworkTimeout() { debugFirePill("Network timeout") }
    @objc private func debugTestPill5MinWarning()    { debugFirePill("5 min left", hold: DesignTokens.Pill.completionWarningHold) }
    @objc private func debugTestPill90MinHardStop()  { debugFirePill("90-min limit") }
    @objc private func debugTestPill20MBWarning()    { debugFirePill("Almost full", hold: DesignTokens.Pill.completionWarningHold) }
    @objc private func debugTestPill24MBHardStop()   { debugFirePill("Size limit") }
    @objc private func debugTestPillStacking() {
        // Fire three completions 300ms apart. Only one should be visible at a
        // time — the newer message replaces the older one without animating
        // through hide/show, since the pill stays in .completion phase and
        // only the SwiftUI body's mode prop updates.
        debugFirePill("First")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.debugFirePill("Second") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.debugFirePill("Third") }
    }

    @objc private func debugSimulateNextUploadFailure() {
        panelController?.transcriptionService.debugSimulateNextUploadFailure()
        debugFirePill("Next upload will fail", hold: DesignTokens.Pill.completionWarningHold)
    }

    @objc private func debugDrainRetryQueue() {
        Task {
            await TranscriptionRetryQueue.shared.drainNow()
        }
    }

    @objc private func debugListPendingSessions() {
        Task {
            let sessions = await TranscriptionRetryQueue.shared.pendingSnapshot()
            print("[Debug] Pending sessions: \(sessions.count)")
            for s in sessions {
                print("  - \(s.sessionUUID) | duration \(s.durationSeconds)s | attempts \(s.attemptCount) | error: \(s.lastError ?? "none") | note: \(s.createdNoteID ?? "nil")")
            }
        }
    }

    @objc private func debugShowStatusNotification() {
        // Toggle the real isWaitingOnRetry state so the floating pill morphs
        // into the notification card via its normal sync() path.
        guard let svc = panelController?.transcriptionService else { return }
        svc.isWaitingOnRetry.toggle()
    }
    #endif
}
