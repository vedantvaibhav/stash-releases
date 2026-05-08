import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import AVFoundation
import ApplicationServices

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
        win.setContentSize(NSSize(width: 500, height: 580))
        win.minSize = NSSize(width: 500, height: 580)
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        self.window = win

        // Show the dock icon while the settings window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Return to background-only mode when settings are closed.
        NSApp.setActivationPolicy(.accessory)
    }

}

// MARK: - Hotkey recorder

/// Recorder behavior per slot. Panel toggle uses Carbon hotkeys which require
/// a non-modifier key + at least one modifier; quick record additionally
/// supports a double-tap-modifier sentinel (`0xFFFE`) for the floating-pill
/// gesture.
enum HotkeyRecordingMode {
    case keyComboOnly
    case keyComboOrDoubleTap
}

/// Manages key-event monitoring during hotkey recording.
/// Takes a save callback so the same class can record for any hotkey slot.
/// Internal access (was `private`) — reused by OnboardingView's hotkey screen.
final class HotkeyRecorder: ObservableObject {
    @Published var isRecording = false

    /// Held modifier flags during recording. Drives the in-progress display
    /// in the row so the user sees what they're about to commit. Cleared on
    /// stop().
    @Published var liveModifiers: NSEvent.ModifierFlags = []

    private var mode: HotkeyRecordingMode = .keyComboOrDoubleTap
    private var monitor: Any?

    /// Called with (keyCode, carbonModifiers) when a valid combo is pressed.
    var onSave: ((UInt32, UInt32) -> Void)?

    func start(mode: HotkeyRecordingMode = .keyComboOrDoubleTap) {
        guard !isRecording else { return }
        self.mode = mode
        isRecording = true
        liveModifiers = []

        var prevModFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags
        var lastModReleaseTime: [UInt32: Date] = [:]

        let modMap: [(flag: NSEvent.ModifierFlags, carbon: UInt32)] = [
            (.command, UInt32(cmdKey)),
            (.option,  UInt32(optionKey)),
            (.control, UInt32(controlKey)),
            (.shift,   UInt32(shiftKey))
        ]

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown {
                if event.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
                if Self.isModifierKeyCode(UInt32(event.keyCode)) {
                    // Bare modifier press fires a keyDown on some keyboards; ignore
                    // and let flagsChanged drive the display update.
                    return nil
                }
                let carbonMods = nsToCarbonModifiers(event.modifierFlags)
                guard carbonMods != 0 else { return event }
                self.onSave?(UInt32(event.keyCode), carbonMods)
                self.stop()
                return nil
            }

            if event.type == .flagsChanged {
                let curr = event.modifierFlags
                self.liveModifiers = curr.intersection([.command, .option, .control, .shift])

                if self.mode == .keyComboOrDoubleTap {
                    for pair in modMap {
                        let wasDown = prevModFlags.contains(pair.flag)
                        let isDown  = curr.contains(pair.flag)
                        if wasDown && !isDown {
                            let now = Date()
                            if let last = lastModReleaseTime[pair.carbon],
                               now.timeIntervalSince(last) < 0.45 {
                                self.onSave?(0xFFFE, pair.carbon)
                                self.stop()
                                return nil
                            }
                            lastModReleaseTime[pair.carbon] = now
                        }
                    }
                }

                prevModFlags = curr
            }

            return event
        }
    }

    func stop() {
        isRecording = false
        liveModifiers = []
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { stop() }

    /// Carbon keyCodes for the four common modifiers and their right-hand
    /// counterparts. Bare modifier presses sometimes fire `keyDown` on certain
    /// hardware (e.g. some Bluetooth keyboards) — treat them as no-op recording
    /// events so they don't end up in `event.keyCode → onSave`.
    private static func isModifierKeyCode(_ code: UInt32) -> Bool {
        switch Int(code) {
        case kVK_Command, kVK_RightCommand,
             kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl,
             kVK_Shift, kVK_RightShift,
             kVK_CapsLock, kVK_Function:
            return true
        default:
            return false
        }
    }
}

// MARK: - Hotkey recorder row (shared by SettingsView and OnboardingView)

/// Self-contained hotkey row: badge + Record/Cancel control. Owns its own
/// `HotkeyRecorder` and persists writes to AppSettings + posts the right
/// notifications based on the configured `slot`. Single source of truth so
/// onboarding inherits Settings' double-tap rendering for free.
struct HotkeyRecorderRow: View {
    let label: String
    let slot: HotkeySlot

    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var recorder = HotkeyRecorder()

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.75))

            Text(recorder.isRecording ? liveBadge : badgeString)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.10))
                .cornerRadius(6)

            Spacer()

            if recorder.isRecording {
                HStack(spacing: 6) {
                    PulsingDot()
                    Text("Recording...")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }
                Button("Cancel") { recorder.stop() }
                    .buttonStyle(HoverButtonStyle(hoverOpacity: 0.10))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                Button {
                    recorder.start(mode: recordingMode)
                } label: {
                    Text("Record New")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(RecordNewButtonStyle())
            }
        }
        .onAppear { wireRecorder() }
    }

    private var recordingMode: HotkeyRecordingMode {
        switch slot {
        case .primaryPanelToggle: return .keyComboOnly
        case .quickRecord:        return .keyComboOrDoubleTap
        }
    }

    private var badgeString: String {
        switch slot {
        case .primaryPanelToggle:
            return hotkeyBadgeString(keyCode: settings.hotKeyCode, carbonModifiers: settings.hotKeyModifiers)
        case .quickRecord:
            return quickRecordBadgeString(code: settings.quickRecordHotKeyCode, modifiers: settings.quickRecordHotKeyModifiers)
        }
    }

    /// In-progress capture: held modifier glyphs + `…` placeholder for the
    /// not-yet-pressed key. Avoids ever showing a raw integer.
    private var liveBadge: String {
        var s = ""
        let mods = recorder.liveModifiers
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option)  { s += "⌥" }
        if mods.contains(.shift)   { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        s += "…"
        return s
    }

    private func wireRecorder() {
        recorder.onSave = { code, mods in
            switch slot {
            case .primaryPanelToggle:
                AppSettings.shared.hotKeyCode      = code
                AppSettings.shared.hotKeyModifiers = mods
                NotificationCenter.default.post(name: .quickPanelHotkeyChanged, object: nil)
            case .quickRecord:
                AppSettings.shared.quickRecordHotKeyCode      = code
                AppSettings.shared.quickRecordHotKeyModifiers = mods
                if code == 0xFFFE {
                    if      mods & UInt32(cmdKey)     != 0 { AppSettings.shared.doubleTapQuickRecord = .command }
                    else if mods & UInt32(optionKey)  != 0 { AppSettings.shared.doubleTapQuickRecord = .option  }
                    else if mods & UInt32(controlKey) != 0 { AppSettings.shared.doubleTapQuickRecord = .control }
                    else if mods & UInt32(shiftKey)   != 0 { AppSettings.shared.doubleTapQuickRecord = .shift   }
                    else                                   { AppSettings.shared.doubleTapQuickRecord = .off     }
                    NotificationCenter.default.post(name: .doubleTapQuickRecordChanged, object: nil)
                } else {
                    AppSettings.shared.doubleTapQuickRecord = .off
                    NotificationCenter.default.post(name: .quickRecordHotkeyChanged, object: nil)
                    NotificationCenter.default.post(name: .doubleTapQuickRecordChanged, object: nil)
                }
            }
        }
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var auth     = AuthService.shared

    // Data section alert state
    @State private var showClearClipboardAlert = false
    @State private var showClearNotesAlert     = false
    @State private var showClearFilesAlert     = false

    @State private var isHoveringSignOut = false

    // Permission status. Refreshed on appear and when the app becomes active
    // (so toggling a permission in System Settings shows up when the user
    // returns to this window).
    @State private var micGranted: Bool = false
    @State private var accessibilityGranted: Bool = false

    private let autoHideOptions: [(label: String, value: Double)] = [
        ("5s", 5), ("7s", 7), ("10s", 10), ("15s", 15), ("30s", 30), ("Never", 0)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                accountCard
                hotkeySection
                autoHideSection
                permissionsSection
                launchAtLoginSection
                dangerZoneSection
            }
            .padding(20)
        }
        .frame(width: 500)
        .frame(minHeight: 580)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            refreshPermissionStatus()
            // Real-time accessibility-state polling. macOS doesn't expose
            // a notification for the trusted-list flip, so AutoPasteService
            // polls AXIsProcessTrusted at 1Hz while we're visible and posts
            // a notification on change. We stop the poll on disappear so
            // we don't burn CPU when the window is closed.
            AutoPasteService.shared.startPermissionPolling()
        }
        .onDisappear {
            AutoPasteService.shared.stopPermissionPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityStatusChanged)) { _ in
            refreshPermissionStatus()
        }
    }

    private func refreshPermissionStatus() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
    }

    // MARK: - Account card

    private var accountCard: some View {
        HStack(spacing: 16) {
            // Avatar — circular initials or placeholder
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 40, height: 40)
                if auth.isSignedIn, let user = auth.currentUser {
                    Text(String((user.name.isEmpty ? user.email : user.name).prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            // Name + email
            VStack(alignment: .leading, spacing: 2) {
                if auth.isSignedIn, let user = auth.currentUser {
                    Text(user.name.isEmpty ? user.email : user.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    Text(user.email)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                } else {
                    Text("Not signed in")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
            }

            Spacer()

            // Sign out / Sign in button
            if auth.isSignedIn {
                Button {
                    Task { await AuthService.shared.signOut() }
                } label: {
                    LogOutIcon(color: Color(red: 1, green: 0.27, blue: 0.23), size: 16)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(HoverButtonStyle(hoverOpacity: 0.09))
            } else {
                Button {
                    Task { await AuthService.shared.signInWithGoogle() }
                } label: {
                    Text("Sign in")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(8)
                }
                .buttonStyle(HoverButtonStyle(hoverOpacity: 0.12))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.07))
        .cornerRadius(12)
    }

    // MARK: - Hotkeys section

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hotkeys")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.45))

            VStack(spacing: 16) {
                HotkeyRecorderRow(label: "Open/Close Tray", slot: .primaryPanelToggle)
                HotkeyRecorderRow(label: "Quick Record",    slot: .quickRecord)
            }
        }
    }

    // MARK: - Auto hide section

    private var autoHideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto Hide")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.45))

            SettingsSegmentedPicker(
                options: autoHideOptions,
                selection: $settings.autoHideSeconds
            )
        }
    }

    // MARK: - Permissions section

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.45))

            VStack(spacing: 8) {
                PermissionRow(
                    title: "Microphone",
                    subtitle: "Required to record voice notes",
                    granted: micGranted,
                    primaryAction: { requestMicPermission() },
                    openSettingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
                PermissionRow(
                    title: "Accessibility",
                    subtitle: "Required to paste transcripts directly into the focused app",
                    granted: accessibilityGranted,
                    primaryAction: { requestAccessibilityPermission() },
                    openSettingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
            }

            // Diagnostic line — shows which bundle is currently running so
            // the user can verify it matches the entry they granted in
            // System Settings. macOS Accessibility is per-bundle-path; an
            // older Stash entry from a different path won't grant
            // permission to a newly-installed copy at /Applications.
            Text("Running: \(Bundle.main.bundlePath)")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.white.opacity(0.30))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 4)
                .textSelection(.enabled)
        }
    }

    private func requestMicPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            // Native prompt — only available the first time. After that it's
            // a no-op and the user has to go through System Settings.
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { refreshPermissionStatus() }
            }
        default:
            // Already determined (granted/denied/restricted) — open System
            // Settings so the user can flip it.
            openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    private func requestAccessibilityPermission() {
        if AXIsProcessTrusted() {
            // Already granted — opening System Settings here is just a way
            // for the user to revoke if they want to.
            openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            return
        }
        // Trigger the native prompt-with-options call. macOS shows the
        // permission prompt; user-toggling Stash on in System Settings
        // grants it. Refresh status when the app becomes active again.
        AutoPasteService.shared.requestAccessibilityPermission()
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Launch at login section

    private var launchAtLoginSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch at Login")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.75))
                Text("Start Stash automatically when you log in")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(0.35))
            }
            Spacer()
            Toggle("", isOn: $settings.launchAtLogin)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: settings.launchAtLogin) { enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // Registration can fail if the user denies permission in System Settings.
                        // Revert the toggle so state stays in sync with reality.
                        settings.launchAtLogin = !enabled
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.07))
        .cornerRadius(12)
    }

    // MARK: - Danger zone section

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Danger Zone")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.45))

            VStack(spacing: 8) {
                dangerButton(title: "Clear all clipboard history") {
                    showClearClipboardAlert = true
                }
                dangerButton(title: "Clear all notes") {
                    showClearNotesAlert = true
                }
                dangerButton(title: "Clear all files") {
                    showClearFilesAlert = true
                }
            }
        }
        .alert("Clear all clipboard history?", isPresented: $showClearClipboardAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                NotificationCenter.default.post(name: .quickPanelClearClipboard, object: nil)
            }
        } message: { Text("All clipboard entries will be permanently deleted.") }
        .alert("Clear all notes?", isPresented: $showClearNotesAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                NotificationCenter.default.post(name: .quickPanelClearNotes, object: nil)
            }
        } message: { Text("All notes will be permanently deleted.") }
        .alert("Clear all dropped files?", isPresented: $showClearFilesAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                NotificationCenter.default.post(name: .quickPanelClearDroppedFiles, object: nil)
            }
        } message: { Text("All files will be removed from the Stash shelf.") }
    }

    private func dangerButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(red: 1.0, green: 0.27, blue: 0.23))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.10))
                .cornerRadius(8)
        }
        .buttonStyle(HoverButtonStyle(hoverOpacity: 0.06))
    }
}

// MARK: - Reusable sub-views

private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let granted: Bool
    let primaryAction: () -> Void
    let openSettingsURL: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.85))
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            statusPill
            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.07))
        .cornerRadius(12)
    }

    private var statusPill: some View {
        Text(granted ? "Granted" : "Not granted")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(granted ? Color(red: 0.27, green: 0.85, blue: 0.42) : .white.opacity(0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                granted
                    ? Color(red: 0.27, green: 0.85, blue: 0.42).opacity(0.15)
                    : Color.white.opacity(0.10)
            )
            .cornerRadius(6)
    }

    @ViewBuilder
    private var actionButton: some View {
        if granted {
            Button {
                if let url = URL(string: openSettingsURL) { NSWorkspace.shared.open(url) }
            } label: {
                Text("Manage")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.10))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: primaryAction) {
                Text("Grant")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.20))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct SettingsSegmentedPicker: View {
    let options: [(label: String, value: Double)]
    @Binding var selection: Double
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: selection == option.value ? .semibold : .regular))
                        .foregroundColor(selection == option.value ? .white : .white.opacity(0.40))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            Group {
                                if selection == option.value {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color.white.opacity(0.14))
                                        .matchedGeometryEffect(id: "pill", in: ns)
                                }
                            }
                        )
                        .padding(.horizontal, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.07))
        .cornerRadius(10)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: selection)
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

private struct LogOutIcon: View {
    var color: Color = .primary
    var size: CGFloat = 16

    var body: some View {
        Canvas { ctx, _ in
            let s = size / 24
            let stroke = StrokeStyle(lineWidth: 2*s, lineCap: .round, lineJoin: .round)

            // Arrow head: m16 17 5-5-5-5
            var p1 = Path()
            p1.move(to:    CGPoint(x: 16*s, y: 17*s))
            p1.addLine(to: CGPoint(x: 21*s, y: 12*s))
            p1.addLine(to: CGPoint(x: 16*s, y:  7*s))
            ctx.stroke(p1, with: .foreground, style: stroke)

            // Arrow shaft: M21 12H9
            var p2 = Path()
            p2.move(to:    CGPoint(x: 21*s, y: 12*s))
            p2.addLine(to: CGPoint(x:  9*s, y: 12*s))
            ctx.stroke(p2, with: .foreground, style: stroke)

            // Door bracket: M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4
            // addArc(tangent1End:tangent2End:radius:) rounds the corner at
            // tangent1End — matches SVG arc-by-tangent semantics exactly.
            let cg = CGMutablePath()
            cg.move(to:    CGPoint(x:  9*s, y: 21*s))
            cg.addLine(to: CGPoint(x:  5*s, y: 21*s))
            cg.addArc(tangent1End: CGPoint(x: 3*s, y: 21*s),
                      tangent2End: CGPoint(x: 3*s, y: 19*s),
                      radius: 2*s)
            cg.addLine(to: CGPoint(x:  3*s, y:  5*s))
            cg.addArc(tangent1End: CGPoint(x: 3*s, y:  3*s),
                      tangent2End: CGPoint(x: 5*s, y:  3*s),
                      radius: 2*s)
            cg.addLine(to: CGPoint(x:  9*s, y:  3*s))
            ctx.stroke(Path(cg), with: .foreground, style: stroke)
        }
        .foregroundColor(color)
        .frame(width: size, height: size)
    }
}

private struct RecordNewButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                (isHovering || configuration.isPressed)
                    ? Color.white.opacity(0.18)
                    : Color.white.opacity(0.10)
            )
            .cornerRadius(8)
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

private struct HoverButtonStyle: ButtonStyle {
    var hoverOpacity: Double = 0.18

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isHovering || configuration.isPressed
                ? Color.white.opacity(hoverOpacity) : Color.clear)
            .cornerRadius(8)
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}
