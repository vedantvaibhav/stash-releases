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
        win.setContentSize(NSSize(width: 500, height: 580))
        win.minSize = NSSize(width: 500, height: 580)
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
                let carbonMods = nsToCarbonModifiers(event.modifierFlags)
                guard carbonMods != 0 else { return event }
                self.onSave?(UInt32(event.keyCode), carbonMods)
                self.stop()
                return nil
            }

            if event.type == .flagsChanged {
                let curr = event.modifierFlags
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
                prevModFlags = curr
            }

            return event
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
            VStack(alignment: .leading, spacing: 24) {
                accountCard
                hotkeySection
                autoHideSection
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
            recorder.onSave = { code, mods in
                AppSettings.shared.hotKeyCode      = code
                AppSettings.shared.hotKeyModifiers = mods
                NotificationCenter.default.post(name: .quickPanelHotkeyChanged, object: nil)
            }
            quickRecorder.onSave = { code, mods in
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

    private func quickRecordBadge() -> String {
        let code = settings.quickRecordHotKeyCode
        let mods = settings.quickRecordHotKeyModifiers
        if code == 0     { return "Not set" }
        if code == 0xFFFE {
            if mods & UInt32(cmdKey)     != 0 { return "⌘⌘" }
            if mods & UInt32(optionKey)  != 0 { return "⌥⌥" }
            if mods & UInt32(controlKey) != 0 { return "⌃⌃" }
            if mods & UInt32(shiftKey)   != 0 { return "⇧⇧" }
            return "Double-tap"
        }
        return hotkeyBadgeString(keyCode: code, carbonModifiers: mods)
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hotkeys")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.45))

            VStack(spacing: 16) {
                settingsHotkeyRow(
                    label: "Open/Close Tray",
                    badgeString: hotkeyBadgeString(keyCode: settings.hotKeyCode,
                                                   carbonModifiers: settings.hotKeyModifiers),
                    recorder: recorder
                )

                settingsHotkeyRow(
                    label: "Quick Record",
                    badgeString: quickRecordBadge(),
                    recorder: quickRecorder
                )

            }
        }
    }

    private func settingsHotkeyRow(label: String, badgeString: String,
                                   recorder: HotkeyRecorder) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.75))

            Text(badgeString)
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
                    recorder.start()
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
