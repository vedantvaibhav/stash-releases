import AppKit
import SwiftUI
import Carbon.HIToolbox

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
        win.setContentSize(NSSize(width: 480, height: 400))
        win.minSize = NSSize(width: 480, height: 400)
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
/// Takes a save callback so the same class can record for any hotkey slot.
private final class HotkeyRecorder: ObservableObject {
    @Published var isRecording = false
    private var monitor: Any?

    /// Called with (keyCode, carbonModifiers) when a valid combo is pressed.
    var onSave: ((UInt32, UInt32) -> Void)?

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
            // Require at least one modifier -- bare keys can't be hotkeys.
            guard carbonMods != 0 else { return event }

            self.onSave?(UInt32(event.keyCode), carbonMods)
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
    @StateObject private var recorder      = HotkeyRecorder()
    @StateObject private var quickRecorder = HotkeyRecorder()

    // Data section alert state
    @State private var showClearClipboardAlert = false
    @State private var showClearNotesAlert     = false
    @State private var showClearFilesAlert     = false

    @State private var isHoveringSignOut = false

    private let autoHideOptions: [(label: String, value: Double)] = [
        ("5s", 5), ("7s", 7), ("10s", 10), ("15s", 15), ("30s", 30), ("Never", 0)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                accountSection
                sectionDivider
                hotkeySection
                sectionDivider
                autoHideSection
                sectionDivider
                dataSection

                // Replay onboarding link — outside any section
                HStack {
                    Spacer()
                    Button {
                        OnboardingManager.shared.resetAndReplay()
                    } label: {
                        Text("Replay onboarding")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.white.opacity(0.30))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .frame(minHeight: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            recorder.onSave = { code, mods in
                AppSettings.shared.hotKeyCode      = code
                AppSettings.shared.hotKeyModifiers = mods
                NotificationCenter.default.post(name: .quickPanelHotkeyChanged, object: nil)
            }
            quickRecorder.onSave = { code, mods in
                AppSettings.shared.quickRecordHotKeyCode      = code
                AppSettings.shared.quickRecordHotKeyModifiers = mods
                NotificationCenter.default.post(name: .quickRecordHotkeyChanged, object: nil)
            }
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

                    Divider().padding(.horizontal, 0)

                    Button {
                        Task { await AuthService.shared.signOut() }
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.60))
                            Text("Sign Out")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white.opacity(0.85))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(isHoveringSignOut ? Color.white.opacity(0.06) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringSignOut = hovering
                    }
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

    // MARK: - Hotkeys section

    private var hotkeySection: some View {
        SettingsSection(title: "HOTKEYS") {
            VStack(spacing: 0) {
                hotkeyRow(
                    label: "Open / Close panel",
                    badgeString: hotkeyBadgeString(keyCode: settings.hotKeyCode,
                                                    carbonModifiers: settings.hotKeyModifiers),
                    recorder: recorder
                )

                Divider().padding(.horizontal, 16)

                hotkeyRow(
                    label: "Quick record",
                    badgeString: settings.quickRecordHotKeyCode == 0
                        ? "Not set"
                        : hotkeyBadgeString(keyCode: settings.quickRecordHotKeyCode,
                                            carbonModifiers: settings.quickRecordHotKeyModifiers),
                    recorder: quickRecorder
                )
            }
        }
    }

    private func hotkeyRow(label: String, badgeString: String, recorder: HotkeyRecorder) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 140, alignment: .leading)

            Text(badgeString)
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
                    Text("Recording...")
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

    // MARK: - Auto-hide section

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

    // MARK: - Data section (was Danger Zone)

    private var dataSection: some View {
        SettingsSection(title: "DATA") {
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
