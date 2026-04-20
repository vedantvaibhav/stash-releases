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

        // Register hotkey immediately (pressing it during onboarding is a no-op since the
        // panel isn't set up yet, but recording a new hotkey on slide 2 still updates prefs).
        registerHotkeyFromSettings()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .quickPanelHotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerHotkeyFromSettings()
        }

        // Check for a stored Supabase session; if found and onboarding was already
        // completed, skip onboarding and open the panel directly.
        Task {
            await AuthService.shared.checkSession()
            if AuthService.shared.isSignedIn &&
               UserDefaults.standard.bool(forKey: "onboardingCompleted") {
                panelController?.setup()
            } else {
                // Show onboarding on first launch; set up the panel only after it
                // completes so the main QuickPanel never opens during onboarding.
                OnboardingManager.shared.showIfNeeded { [weak self] in
                    self?.panelController?.setup()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKey?.unregister()
        quickRecordHotKey?.unregister()
        if let obs = hotkeyObserver {
            NotificationCenter.default.removeObserver(obs)
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

        // ⌘⇧R — quick record without opening the panel — signature 'QPRK'
        quickRecordHotKey?.unregister()
        quickRecordHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_R),
                                         modifiers: UInt32(cmdKey | shiftKey),
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
                // Panel stays hidden — pill appears automatically
            }
        }
        _ = quickRecordHotKey?.register()
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
        } else {
            panelController?.togglePanel()
        }
    }

    // MARK: - Right-click context menu

    private func showStatusMenu() {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "Open / Close QuickPanel",
                                    action: #selector(togglePanelFromMenu),
                                    keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let updatesItem = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(checkForUpdates),
                                     keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit QuickPanel",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        // Temporarily assign the menu so the system shows it, then clear so
        // future left-clicks still toggle the panel.
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

    @objc private func openSettings() {
        SettingsWindowController.shared.showSettings()
    }
}
