import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Window controller

/// Singleton window controller for the Settings window.
/// Opens a regular (dock-visible) NSWindow while settings are showing.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    func showSettings() {
        // Rebuild content each open so stale cached windows cannot hide new sections.
        window?.close()
        window = nil

        let hosting = NSHostingController(rootView: SettingsView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "Stash Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 480, height: 620))
        win.minSize = NSSize(width: 480, height: 620)
        win.maxSize = NSSize(width: 480, height: 620)
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        self.window = win

        // Show the dock icon while the settings window is open.
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Return to background-only mode when settings are closed.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Closes the settings window then immediately shows onboarding from slide 1.
    func closeAndRunOnboarding() {
        window?.close()
        window = nil
        Task { @MainActor in
            OnboardingManager.shared.show(onComplete: { /* panel already running */ })
        }
    }
}

// MARK: - Hotkey recorder

/// Manages key-event monitoring during hotkey recording.
private final class HotkeyRecorder: ObservableObject {
    @Published var isRecording = false
    private var monitor: Any?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Escape cancels recording without changing the hotkey.
            if event.keyCode == UInt16(kVK_Escape) {
                self.stop()
                return nil
            }

            let carbonMods = nsToCarbonModifiers(event.modifierFlags)
            // Require at least one modifier — bare keys can't be hotkeys.
            guard carbonMods != 0 else { return event }

            AppSettings.shared.hotKeyCode      = UInt32(event.keyCode)
            AppSettings.shared.hotKeyModifiers = carbonMods
            NotificationCenter.default.post(name: .quickPanelHotkeyChanged, object: nil)
            self.stop()
            return nil
        }
    }

    func stop() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { stop() }
}

// MARK: - Settings view

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var auth     = AuthService.shared
    @StateObject private var recorder   = HotkeyRecorder()

    // Danger-zone alert state
    @State private var showClearClipboardAlert = false
    @State private var showClearNotesAlert     = false
    @State private var showClearFilesAlert     = false

    private let autoHideOptions: [(label: String, value: Double)] = [
        ("5s", 5), ("7s", 7), ("10s", 10), ("15s", 15), ("30s", 30), ("Never", 0)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned at top — never inside ScrollView so it can’t scroll off-screen or clip.
            layoutStyleSection
            sectionDivider
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    accountSection
                    sectionDivider
                    hotkeySection
                    sectionDivider
                    autoHideSection
                    sectionDivider
                    panelSizeSection
                    sectionDivider
                    launchAtLoginSection
                    sectionDivider
                    dangerZoneSection
                    sectionDivider
                    developerSection
                }
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 620)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Layout style (top of settings)

    private var layoutStyleSection: some View {
        SettingsSection(title: "LAYOUT STYLE") {
            HStack(alignment: .top, spacing: 8) {
                LayoutStyleOptionCard(
                    title: "Panel",
                    isSelected: settings.layoutStyle == .panel,
                    action: { settings.layoutStyle = .panel }
                ) {
                    PanelLayoutThumbnailView()
                }
                LayoutStyleOptionCard(
                    title: "Cards",
                    isSelected: settings.layoutStyle == .cards,
                    action: { settings.layoutStyle = .cards }
                ) {
                    CardsLayoutThumbnailView()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
    }

    // MARK: - Section 1: Hotkey

    private var hotkeySection: some View {
        SettingsSection(title: "OPEN / CLOSE HOTKEY") {
            HStack(spacing: 12) {
                Text("Hotkey")
                    .frame(width: 110, alignment: .leading)

                // Badge showing current hotkey
                Text(hotkeyBadgeString(keyCode: settings.hotKeyCode,
                                       carbonModifiers: settings.hotKeyModifiers))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))

                Spacer()

                if recorder.isRecording {
                    HStack(spacing: 6) {
                        PulsingDot()
                        Text("Recording…")
                            .foregroundColor(.secondary)
                            .font(.callout)
                    }
                    Button("Cancel") { recorder.stop() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Record") { recorder.start() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Section 2: Auto-hide timer

    private var autoHideSection: some View {
        SettingsSection(title: "AUTO HIDE") {
            HStack(spacing: 12) {
                Text("Auto hide after")
                    .frame(width: 110, alignment: .leading)
                Spacer()
                Picker("", selection: $settings.autoHideSeconds) {
                    ForEach(autoHideOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Section 3: Panel size

    private var panelSizeSection: some View {
        SettingsSection(title: "PANEL SIZE") {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Text("Panel width")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $settings.panelWidth, in: 500...900, step: 10)
                    Text("\(Int(settings.panelWidth)) pt")
                        .frame(width: 52, alignment: .trailing)
                        .foregroundColor(.secondary)
                        .font(.callout)
                }
                HStack(spacing: 12) {
                    Text("Panel height")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $settings.panelHeight, in: 300...600, step: 10)
                    Text("\(Int(settings.panelHeight)) pt")
                        .frame(width: 52, alignment: .trailing)
                        .foregroundColor(.secondary)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Section 4: Launch at login + Replay onboarding

    private var launchAtLoginSection: some View {
        SettingsSection(title: "GENERAL") {
            VStack(spacing: 0) {
                HStack {
                    Text("Launch at login")
                    Spacer()
                    Toggle("", isOn: $settings.launchAtLogin)
                        .toggleStyle(.switch)
                        .onChange(of: settings.launchAtLogin) { newValue in
                            if newValue {
                                try? SMAppService.mainApp.register()
                            } else {
                                try? SMAppService.mainApp.unregister()
                            }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider().padding(.horizontal, 16)

                Button(action: {
                    OnboardingManager.shared.resetAndReplay()
                }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Replay onboarding")
                    }
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Section 5: Danger zone

    private var dangerZoneSection: some View {
        SettingsSection(title: "DANGER ZONE") {
            VStack(spacing: 8) {
                DangerButton(title: "Clear all clipboard history") {
                    showClearClipboardAlert = true
                }
                DangerButton(title: "Clear all notes") {
                    showClearNotesAlert = true
                }
                DangerButton(title: "Clear all dropped files") {
                    showClearFilesAlert = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.red.opacity(0.04))
        // Clipboard alert
        .alert("Clear all clipboard history?", isPresented: $showClearClipboardAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                NotificationCenter.default.post(name: .quickPanelClearClipboard, object: nil)
            }
        } message: {
            Text("All clipboard entries will be permanently deleted.")
        }
        // Notes alert
        .alert("Clear all notes?", isPresented: $showClearNotesAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                NotificationCenter.default.post(name: .quickPanelClearNotes, object: nil)
            }
        } message: {
            Text("All notes will be permanently deleted.")
        }
        // Files alert
        .alert("Clear all dropped files?", isPresented: $showClearFilesAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                NotificationCenter.default.post(name: .quickPanelClearDroppedFiles, object: nil)
            }
        } message: {
            Text("All files will be removed from the Stash shelf and deleted from ~/Documents/QuickPanel/.")
        }
    }

    // MARK: - Account section

    private var accountSection: some View {
        SettingsSection(title: "ACCOUNT") {
            if auth.isSignedIn, let user = auth.currentUser {
                // Signed-in state
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        // Initials avatar
                        ZStack {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 36, height: 36)
                            Text(String(user.name.isEmpty ? user.email.prefix(1) : user.name.prefix(1)).uppercased())
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name.isEmpty ? user.email : user.name)
                                .font(.system(size: 14, weight: .medium))
                            if !user.name.isEmpty {
                                Text(user.email)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        // Trial badge
                        let days = auth.trialDaysRemaining
                        Text(days > 0 ? "\(days)d left" : "Trial ended")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(days > 7 ? .white : .orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(days > 7 ? Color.accentColor.opacity(0.85) : Color.orange.opacity(0.2))
                            .cornerRadius(6)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                    Button {
                        Task { await AuthService.shared.signOut() }
                    } label: {
                        Text("Sign out")
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            } else {
                // Signed-out state
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sign in to sync your notes and access your account.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    Button {
                        Task { await AuthService.shared.signInWithGoogle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .font(.system(size: 14))
                            Text("Continue with Google")
                                .font(.system(size: 13))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    // MARK: - Section 6: Developer

    private var developerSection: some View {
        SettingsSection(title: "DEVELOPER") {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: resetOnboarding) {
                    Text("Reset onboarding")
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)

                Text("Replays the first launch onboarding flow")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
            }
            .padding(.vertical, 10)
        }
    }

    private func resetOnboarding() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: "onboardingCompleted")
        ud.removeObject(forKey: "userName")
        ud.removeObject(forKey: "userEmail")
        SettingsWindowController.shared.closeAndRunOnboarding()
    }

    // MARK: - Helpers

    private var sectionDivider: some View {
        Divider().padding(.horizontal, 16)
    }
}

// MARK: - Reusable sub-views

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
            content()
        }
    }
}

private struct DangerButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .foregroundColor(.red)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Layout style radio cards

private struct LayoutStyleOptionCard<Thumbnail: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let thumbnail: () -> Thumbnail

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                thumbnail()
                    .frame(width: 158, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: isSelected ? 2 : 1)
                    )
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PanelLayoutThumbnailView: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor.opacity(0.25))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct CardsLayoutThumbnailView: View {
    var body: some View {
        VStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(height: 16)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .scaleEffect(pulse ? 1.4 : 1.0)
            .opacity(pulse ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
