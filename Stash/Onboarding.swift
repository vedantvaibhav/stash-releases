import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// MARK: - Public mic permission status

enum OnboardingMicStatus: Equatable {
    case unknown, granted, denied
}

// MARK: - Hotkey recorder (onboarding-local, mirrors SettingsView's private one)

final class OnboardingHotkeyRecorder: ObservableObject {
    @Published var isRecording = false
    private var monitor: Any?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                DispatchQueue.main.async { self.stop() }
                return nil
            }
            let mods = nsToCarbonModifiers(event.modifierFlags)
            guard mods != 0 else { return event }
            AppSettings.shared.hotKeyCode = UInt32(event.keyCode)
            AppSettings.shared.hotKeyModifiers = mods
            NotificationCenter.default.post(name: .quickPanelHotkeyChanged, object: nil)
            DispatchQueue.main.async { self.stop() }
            return nil
        }
    }

    func stop() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { stop() }
}

// MARK: - Panel subclass (accepts key/main so text fields work)

private final class OnboardingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Manager

@MainActor
final class OnboardingManager: NSObject, NSWindowDelegate {

    static let shared = OnboardingManager()

    private var panel: NSPanel?
    private var onComplete: (() -> Void)?

    private override init() { super.init() }

    // MARK: - UserDefaults keys

    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingCompleted") }
    }

    // MARK: - Public API

    /// Calls onComplete immediately if already finished; otherwise shows onboarding first.
    func showIfNeeded(onComplete: @escaping () -> Void) {
        if Self.isCompleted {
            onComplete()
            return
        }
        show(onComplete: onComplete)
    }

    /// Unconditionally shows onboarding. Safe to call from Settings (onComplete is a no-op there).
    func show(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        buildAndShowPanel()
    }

    /// Resets the completed flag and shows onboarding (replay from Settings).
    func resetAndReplay() {
        Self.isCompleted = false
        guard panel == nil else { return } // already showing
        show(onComplete: { /* panel already running */ })
    }

    // MARK: - Private

    private func buildAndShowPanel() {
        let rootView = OnboardingRootView(onComplete: { [weak self] in
            self?.finishOnboarding()
        })
        let hosting = NSHostingController(rootView: rootView)

        let p = OnboardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces]
        p.alphaValue = 0
        p.isMovableByWindowBackground = true
        p.delegate = self
        p.contentViewController = hosting
        p.center()

        NSApp.setActivationPolicy(.regular)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 1
        }

        panel = p
    }

    private func finishOnboarding() {
        Self.isCompleted = true
        let p = panel
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            p?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            p?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            self?.onComplete?()
            self?.onComplete = nil
        })
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            panel = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Blur background

private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Root onboarding view (slide pager + nav chrome)

struct OnboardingRootView: View {

    let onComplete: () -> Void

    @State private var currentSlide = 0
    @State private var goingForward = true

    @StateObject private var hotkeyRecorder = OnboardingHotkeyRecorder()
    @State private var micStatus: OnboardingMicStatus = .unknown
    @State private var launchAtLogin = true

    private let totalSlides = 5

    var body: some View {
        ZStack {
            // Layer 1 — frosted glass
            VisualEffectBlur()

            // Layer 2 — dark tint
            Color(NSColor(white: 0.09, alpha: 0.91))

            // Layer 3 — content
            VStack(spacing: 0) {

                // Back chevron (slides 2-5)
                HStack {
                    if currentSlide > 0 {
                        Button(action: goBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)

                // Slide area
                ZStack {
                    slideContent
                        .id(currentSlide)
                        .transition(.asymmetric(
                            insertion: .move(edge: goingForward ? .trailing : .leading),
                            removal: .move(edge: goingForward ? .leading : .trailing)
                        ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                // Progress dots
                HStack(spacing: 6) {
                    ForEach(0..<totalSlides, id: \.self) { i in
                        Capsule()
                            .fill(Color.white.opacity(i == currentSlide ? 1.0 : 0.3))
                            .frame(width: i == currentSlide ? 20 : 8, height: 6)
                            .animation(.easeInOut(duration: 0.25), value: currentSlide)
                    }
                }
                .padding(.vertical, 14)

                // CTA button — invisible + non-interactive on last slide (slide 5 has its own buttons)
                Button(action: advance) {
                    Text(ctaTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .opacity(currentSlide == totalSlides - 1 ? 0 : 1)
                .allowsHitTesting(currentSlide != totalSlides - 1)
            }

            // Layer 4 — border ring (non-interactive)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .frame(width: 480, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .colorScheme(.dark)
        .onAppear { refreshMicStatus() }
    }

    // MARK: - Slide dispatcher

    @ViewBuilder
    private var slideContent: some View {
        if currentSlide == 0 {
            OnboardingSlide1()
        } else if currentSlide == 1 {
            OnboardingSlide2(recorder: hotkeyRecorder)
        } else if currentSlide == 2 {
            OnboardingSlide3(micStatus: $micStatus)
        } else if currentSlide == 3 {
            OnboardingSlide4(launchAtLogin: $launchAtLogin)
        } else {
            OnboardingSlide5(launchAtLogin: launchAtLogin, onComplete: onComplete)
        }
    }

    // MARK: - CTA label

    private var ctaTitle: String {
        switch currentSlide {
        case 0: return "Get started →"
        case 1: return "Looks good →"
        case 2: return micStatus == .granted ? "Continue →" : "Skip for now →"
        default: return "Continue →"
        }
    }

    // MARK: - Navigation

    private func advance() {
        guard currentSlide < totalSlides - 1 else { return }
        goingForward = true
        withAnimation(.easeInOut(duration: 0.3)) {
            currentSlide += 1
        }
        if currentSlide == 2 { refreshMicStatus() }
    }

    private func goBack() {
        guard currentSlide > 0 else { return }
        hotkeyRecorder.stop()
        goingForward = false
        withAnimation(.easeInOut(duration: 0.3)) {
            currentSlide -= 1
        }
    }

    private func refreshMicStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:             micStatus = .granted
        case .denied, .restricted:   micStatus = .denied
        default:                     micStatus = .unknown
        }
    }
}

// MARK: - Slide 1: Welcome

private struct OnboardingSlide1: View {

    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Spacer().frame(height: 16)

            Text(appDisplayName)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.white)

            Spacer().frame(height: 10)

            Text("Your clipboard, notes and files — always one keystroke away")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)

            Spacer().frame(height: 36)

            VStack(spacing: 0) {
                featureRow("paperclip",  "Clipboard history — never lose a copy")
                featureRow("note.text",  "Smart notes — write or transcribe meetings")
                featureRow("folder",     "File shelf — drag in, drag out instantly")
            }
            .padding(.horizontal, 44)

            Spacer()
        }
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.2).delay(0.15)) { visible = true }
        }
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Stash"
    }

    private func featureRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 26, alignment: .center)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
        }
        .padding(.vertical, 16)
    }
}

// MARK: - Slide 2: Hotkey

private struct OnboardingSlide2: View {

    @ObservedObject var recorder: OnboardingHotkeyRecorder
    @ObservedObject private var settings = AppSettings.shared
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Set your hotkey")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white)

            Spacer().frame(height: 12)

            Text("Press any key combination to open Stash from anywhere")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 48)

            Spacer().frame(height: 36)

            // Badge
            Text(recorder.isRecording
                 ? "Press any keys..."
                 : hotkeyBadgeString(keyCode: settings.hotKeyCode,
                                     carbonModifiers: settings.hotKeyModifiers))
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(recorder.isRecording ? .white.opacity(0.45) : .white)
                .frame(width: 200, height: 56)
                .background(Color.white.opacity(0.08))
                .cornerRadius(14)

            Spacer().frame(height: 16)

            Text("or")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.4))

            Spacer().frame(height: 16)

            // Record button
            Button(action: {
                if recorder.isRecording { recorder.stop() } else { recorder.start() }
            }) {
                Text(recorder.isRecording ? "Cancel" : "Record new hotkey")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 160, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Spacer().frame(height: 20)

            Text("Default is ⌘⇧Space")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))

            Spacer()
        }
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.2).delay(0.15)) { visible = true }
        }
    }
}

// MARK: - Slide 3: Microphone

private struct OnboardingSlide3: View {

    @Binding var micStatus: OnboardingMicStatus
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 64))
                .foregroundColor(.white)

            Spacer().frame(height: 20)

            Text("Enable microphone")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white)

            Spacer().frame(height: 12)

            Text("Stash can transcribe your meetings and turn them into smart structured notes. This requires microphone access.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 48)

            Spacer().frame(height: 24)

            // Animated status badge
            statusBadge
                .animation(.easeInOut(duration: 0.3), value: micStatus)

            Spacer().frame(height: 16)

            // Action button (hidden once granted)
            if micStatus != .granted {
                Button(action: handleButton) {
                    Text(micStatus == .denied ? "Open System Settings" : "Enable microphone")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.2).delay(0.15)) { visible = true }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch micStatus {
        case .unknown:
            badgeRow(icon: "circle.fill",
                     iconColor: Color(NSColor.systemGray),
                     label: "Not enabled yet",
                     labelColor: .white.opacity(0.6),
                     bg: Color.white.opacity(0.08))

        case .granted:
            badgeRow(icon: "checkmark.circle.fill",
                     iconColor: .green,
                     label: "Microphone enabled ✓",
                     labelColor: .green,
                     bg: Color.green.opacity(0.12))

        case .denied:
            badgeRow(icon: "exclamationmark.triangle.fill",
                     iconColor: .orange,
                     label: "Access denied — tap to open Settings",
                     labelColor: .orange,
                     bg: Color.orange.opacity(0.12))
                .onTapGesture { openPrivacySettings() }
        }
    }

    private func badgeRow(icon: String, iconColor: Color, label: String,
                          labelColor: Color, bg: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(labelColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(bg)
        .cornerRadius(10)
    }

    private func handleButton() {
        if micStatus == .denied {
            openPrivacySettings()
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    micStatus = granted ? .granted : .denied
                }
            }
        }
    }

    private func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

// MARK: - Slide 4: Launch at login

private struct OnboardingSlide4: View {

    @Binding var launchAtLogin: Bool
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "bolt.fill")
                .font(.system(size: 64))
                .foregroundColor(.white)

            Spacer().frame(height: 20)

            Text("Always ready")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white)

            Spacer().frame(height: 12)

            Text("Launch Stash automatically when you log in so it is always there when you need it.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)

            Spacer().frame(height: 32)

            // Toggle card
            HStack {
                Text("Launch at login")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(Color.white.opacity(0.06))
            .cornerRadius(14)
            .padding(.horizontal, 20)

            Spacer().frame(height: 12)

            Text("You can change this later in Settings")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))

            Spacer()
        }
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.2).delay(0.15)) { visible = true }
        }
    }
}

// MARK: - Slide 5: Google Sign In (Supabase browser OAuth)

private struct OnboardingSlide5: View {

    let launchAtLogin: Bool
    let onComplete: () -> Void

    @ObservedObject private var auth = AuthService.shared
    @State private var visible = false

    var body: some View {
        ZStack {
            // Background content — dimmed while loading
            slideContent
                .opacity(auth.isLoading ? 0.5 : 1.0)

            // Loading overlay
            if auth.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.1)
                    Text("Opening Google sign in...")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                    Button("Cancel") {
                        AuthService.shared.isLoading = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.2).delay(0.15)) { visible = true }
            // If a previous session was already restored, skip straight through
            if AuthService.shared.isSignedIn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { completeOnboarding() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .authCompleted)) { _ in
            completeOnboarding()
        }
    }

    // MARK: - Slide content

    private var slideContent: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.white)

            Spacer().frame(height: 20)

            Text("Create your account")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white)

            Spacer().frame(height: 12)

            Text("Sign in to start your 30 day free trial.\nNo credit card required.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)

            Spacer().frame(height: 20)

            // Trial info card
            HStack(spacing: 16) {
                Image(systemName: "calendar")
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                VStack(alignment: .leading, spacing: 4) {
                    Text("30 days free")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                    Text("No credit card required")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 72)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.06))
            .cornerRadius(14)
            .padding(.horizontal, 20)

            Spacer().frame(height: 16)

            // Continue with Google
            Button {
                Task { await AuthService.shared.signInWithGoogle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.black)
                    Text("Continue with Google")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.black)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.white)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .disabled(auth.isLoading)

            // Error message
            if let error = auth.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .onTapGesture { AuthService.shared.errorMessage = nil }
            }

            Spacer().frame(height: 20)

            // Skip link
            Button(action: completeOnboarding) {
                Text("Skip for now →")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)

            Spacer().frame(height: 12)

            Text("Sign in will be required after your trial ends")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))

            Spacer()
        }
    }

    // MARK: - Complete

    private func completeOnboarding() {
        AppSettings.shared.launchAtLogin = launchAtLogin
        if launchAtLogin {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
        onComplete()
    }
}
