import SwiftUI
import AppKit
import AVKit

struct OnboardingView: View {

    @ObservedObject var model: OnboardingViewModel
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject private var settings = AppSettings.shared

    private static let totalSteps = 6

    var body: some View {
        ZStack {
            DesignTokens.Onboarding.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content
                    .id(model.step)
                    .transition(.opacity)
                Spacer(minLength: 0)
                if showsProgressDots {
                    progressDots
                        .padding(.bottom, DesignTokens.Onboarding.outerPadding)
                }
            }
            .padding(.horizontal, contentHorizontalPadding)
        }
        .foregroundStyle(DesignTokens.Onboarding.foreground)
        .frame(
            minWidth: DesignTokens.Onboarding.windowSize.width,
            minHeight: DesignTokens.Onboarding.windowSize.height
        )
    }

    /// Auth screen (step 0) takes over the full window with its own background
    /// image and visual style — so the standard parent black bg, horizontal
    /// padding, and progress-dot strip would all conflict with the design.
    private var isAuthStep: Bool { model.step == 0 }
    private var showsProgressDots: Bool { !isAuthStep }
    private var contentHorizontalPadding: CGFloat {
        isAuthStep ? 0 : DesignTokens.Onboarding.outerPadding
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case 0: authStep
        case 1: hotkeyStep
        case 2: recordingStep
        case 3: clipboardStep
        case 4: filesStep
        default: doneStep
        }
    }

    // MARK: - File shelf (screen 5)

    private var filesStep: some View {
        VStack(spacing: DesignTokens.Onboarding.stepGap) {
            staggered(index: 0) {
                Text("File shelf")
                    .font(DesignTokens.Onboarding.titleFont)
            }
            staggered(index: 1) {
                mediaSlot(OnboardingMedia.filesDemo)
            }
            staggered(index: 2) {
                Text("Drag any file in, drag it out into any app. Hit space for Quick Look. Your desktop stays clean.")
                    .font(DesignTokens.Onboarding.bodyFont)
                    .foregroundStyle(DesignTokens.Onboarding.bodyColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: DesignTokens.Onboarding.bodyMaxWidthLong)
            }
            staggered(index: 3) {
                backNextButtons()
            }
        }
    }

    // MARK: - Clipboard (screen 4)

    private var clipboardStep: some View {
        VStack(spacing: DesignTokens.Onboarding.stepGap) {
            staggered(index: 0) {
                Text("Clipboard history")
                    .font(DesignTokens.Onboarding.titleFont)
            }
            staggered(index: 1) {
                mediaSlot(OnboardingMedia.clipboardDemo)
            }
            staggered(index: 2) {
                Text("Everything you copy lives one hotkey away. Pin the snippets you keep coming back to so they don't fall off the bottom.")
                    .font(DesignTokens.Onboarding.bodyFont)
                    .foregroundStyle(DesignTokens.Onboarding.bodyColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: DesignTokens.Onboarding.bodyMaxWidthLong)
            }
            staggered(index: 3) {
                backNextButtons()
            }
        }
    }

    // MARK: - Media slot

    /// Renders the demo video if `url` is non-nil; otherwise a styled
    /// placeholder block (deliberate negative space, not a broken-state look).
    /// When assets ship, swap the URL in `OnboardingMedia` — autoplay/looping
    /// wiring lives at the call site of `VideoPlayer` once a real URL exists.
    @ViewBuilder
    private func mediaSlot(_ url: URL?) -> some View {
        if let url {
            VideoPlayer(player: AVPlayer(url: url))
                .frame(
                    width: DesignTokens.Onboarding.mediaSlotWidth,
                    height: DesignTokens.Onboarding.mediaSlotHeight
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Onboarding.mediaSlotCornerRadius))
        } else {
            RoundedRectangle(cornerRadius: DesignTokens.Onboarding.mediaSlotCornerRadius)
                .fill(DesignTokens.Onboarding.mediaSlotBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Onboarding.mediaSlotCornerRadius)
                        .strokeBorder(DesignTokens.Onboarding.mediaSlotBorder, lineWidth: 1)
                )
                .frame(
                    width: DesignTokens.Onboarding.mediaSlotWidth,
                    height: DesignTokens.Onboarding.mediaSlotHeight
                )
        }
    }

    // MARK: - Auth (screen 1)

    /// Onboarding's auth screen. Full-bleed background image with a centered
    /// icon + title + subtitle + Continue with Google button. Distinct from
    /// `AuthGateView` (PanelController.swift) which is reused for sign-out
    /// re-auth in the panel context — that one is small/dense and lives over
    /// the panel's black chrome; this one is the marketing-grade welcome
    /// surface for first-time users.
    private var authStep: some View {
        OnboardingAuthView(
            onSignIn: { Task { await AuthService.shared.signInWithGoogle() } }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(AuthService.shared.$isSignedIn) { signedIn in
            if signedIn && model.step == 0 {
                model.advance(totalSteps: Self.totalSteps)
            }
        }
    }

    // MARK: - Recording (screen 3 — combined voice + meeting)

    private var recordingStep: some View {
        VStack(spacing: DesignTokens.Onboarding.stepGap) {
            staggered(index: 0) {
                Text("Recording")
                    .font(DesignTokens.Onboarding.titleFont)
            }
            staggered(index: 1) {
                mediaSlot(OnboardingMedia.recordingDemo)
            }
            staggered(index: 2) {
                VStack(alignment: .leading, spacing: DesignTokens.Onboarding.recordingBulletGap) {
                    recordingBullet(
                        prefix: "Under 5 min →",
                        text: "cleaned text lands on your clipboard."
                    )
                    recordingBullet(
                        prefix: "Over 5 min →",
                        text: "Stash saves a transcript with a structured overview."
                    )
                }
                .frame(maxWidth: DesignTokens.Onboarding.bodyMaxWidthLong)
            }
            staggered(index: 3) {
                backNextButtons()
            }
        }
    }

    private func recordingBullet(prefix: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Onboarding.recordingBulletInline) {
            Text(prefix)
                .font(DesignTokens.Onboarding.bodyFont.weight(.semibold))
                .foregroundStyle(DesignTokens.Onboarding.foreground)
            Text(text)
                .font(DesignTokens.Onboarding.bodyFont)
                .foregroundStyle(DesignTokens.Onboarding.bodyColor)
        }
    }

    // MARK: - Hotkeys (screen 2)

    /// Reuses the shared `HotkeyRecorderRow` from SettingsView.swift so onboarding
    /// inherits Settings' double-tap badge rendering and persistence wiring.
    /// The visual style is Settings-ish (small chip + Record New button) — a
    /// deliberate aesthetic mismatch with the rest of onboarding, accepted for
    /// now. Visual polish lands in a later pass.
    private var hotkeyStep: some View {
        VStack(spacing: DesignTokens.Onboarding.stepGap) {
            staggered(index: 0) {
                Text("Your hotkeys")
                    .font(DesignTokens.Onboarding.titleFont)
            }
            staggered(index: 1) {
                VStack(alignment: .leading, spacing: DesignTokens.Onboarding.hotkeyRowGap) {
                    HotkeyRecorderRow(label: "Open Stash",   slot: .primaryPanelToggle)
                    HotkeyRecorderRow(label: "Quick record", slot: .quickRecord)
                }
                .frame(maxWidth: DesignTokens.Onboarding.bodyMaxWidthLong)
            }
            staggered(index: 2) {
                Text("These are the defaults. Click Record New to set your own, or hit Continue.")
                    .font(DesignTokens.Onboarding.bodyFont)
                    .foregroundStyle(DesignTokens.Onboarding.bodyColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: DesignTokens.Onboarding.bodyMaxWidthShort)
            }
            staggered(index: 3) {
                ctaButton(title: "Continue", action: advance)
            }
        }
    }

    private func chipView(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Onboarding.chipFont)
            .padding(.horizontal, DesignTokens.Onboarding.chipPaddingH)
            .padding(.vertical, DesignTokens.Onboarding.chipPaddingV)
            .background(DesignTokens.Onboarding.chipBackground)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Onboarding.chipCornerRadius)
                    .stroke(DesignTokens.Onboarding.chipBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Onboarding.chipCornerRadius))
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(spacing: DesignTokens.Onboarding.stepGap) {
            staggered(index: 0) {
                Text("You're set")
                    .font(DesignTokens.Onboarding.titleFont)
            }
            staggered(index: 1) {
                HStack(spacing: 8) {
                    Text("Hit")
                        .font(DesignTokens.Onboarding.bodyFont)
                        .foregroundStyle(DesignTokens.Onboarding.bodyColor)
                    chipView(primaryChipText)
                    Text("to open Stash.")
                        .font(DesignTokens.Onboarding.bodyFont)
                        .foregroundStyle(DesignTokens.Onboarding.bodyColor)
                }
            }
        }
        .modifier(DoneStepHotkeyListener(onFinish: onFinish))
    }

    // MARK: - CTA

    private func ctaButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DesignTokens.Onboarding.ctaFont)
                .padding(.horizontal, DesignTokens.Onboarding.ctaPaddingH)
                .padding(.vertical, DesignTokens.Onboarding.ctaPaddingV)
        }
        .buttonStyle(OnboardingCTAButtonStyle())
    }

    /// [Back] [Next] pair used on the feature-education screens. Back is the
    /// secondary action (lower visual weight via the plain button style); Next
    /// keeps the primary CTA styling so the forward path stays prominent.
    private func backNextButtons() -> some View {
        HStack(spacing: 12) {
            Button(action: { model.goBack() }) {
                Text("Back")
                    .font(DesignTokens.Onboarding.ctaFont)
                    .foregroundStyle(DesignTokens.Onboarding.bodyColor)
                    .padding(.horizontal, DesignTokens.Onboarding.ctaPaddingH)
                    .padding(.vertical, DesignTokens.Onboarding.ctaPaddingV)
            }
            .buttonStyle(.plain)

            ctaButton(title: "Next", action: advance)
        }
    }

    // MARK: - Progress dots

    private var progressDots: some View {
        HStack(spacing: DesignTokens.Onboarding.progressDotGap) {
            ForEach(0..<Self.totalSteps, id: \.self) { i in
                Circle()
                    .fill(i == model.step ? Color.white.opacity(0.85) : Color.white.opacity(0.18))
                    .frame(
                        width: DesignTokens.Onboarding.progressDotSize,
                        height: DesignTokens.Onboarding.progressDotSize
                    )
            }
        }
    }

    // MARK: - Staggered entrance

    @ViewBuilder
    private func staggered<Content: View>(index: Int, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        if reduceMotion {
            content()
        } else {
            StaggeredAppear(index: index, content: content)
        }
    }

    // MARK: - Hotkey strings (live-derived from AppSettings)

    private var primaryChipText: String {
        hotkeyBadgeString(keyCode: settings.hotKeyCode, carbonModifiers: settings.hotKeyModifiers)
    }

    private var quickRecordChipText: String {
        quickRecordBadgeString(
            code: settings.quickRecordHotKeyCode,
            modifiers: settings.quickRecordHotKeyModifiers
        )
    }

    // MARK: - Step advance

    private func advance() {
        if model.step < Self.totalSteps - 1 {
            model.advance(totalSteps: Self.totalSteps)
        } else {
            onFinish()
        }
    }
}

// MARK: - CTA button style

private struct OnboardingCTAButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                hovering || configuration.isPressed
                    ? DesignTokens.Onboarding.ctaBackgroundHover
                    : DesignTokens.Onboarding.ctaBackgroundRest
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Onboarding.ctaCornerRadius))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Auth screen view

/// Full-bleed welcome surface with the Continue with Google button. Used as
/// step 0 of onboarding only. The panel's sign-out re-auth path keeps using
/// the original `AuthGateView` from PanelController.swift.
private struct OnboardingAuthView: View {
    var onSignIn: () -> Void

    @ObservedObject private var auth = AuthService.shared
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .top) {
            backgroundView

            VStack(spacing: 0) {
                appIcon
                    .padding(.bottom, DesignTokens.Onboarding.authContentSpacing)

                Text("welcome to stash")
                    .font(DesignTokens.Onboarding.authTitleFont)
                    .foregroundStyle(DesignTokens.Onboarding.authTitleColor)

                Spacer().frame(height: DesignTokens.Onboarding.authTitleSubtitleGap)

                Text("Clipboard, Files & Notes, always available")
                    .font(DesignTokens.Onboarding.authSubtitleFont)
                    .foregroundStyle(DesignTokens.Onboarding.authSubtitleColor)
                    .multilineTextAlignment(.center)

                Spacer().frame(height: DesignTokens.Onboarding.authButtonTopGap)

                continueButton

                statusLine
                    .padding(.top, 12)
            }
            .padding(.top, DesignTokens.Onboarding.authContentTopPadding)
            .padding(.horizontal, DesignTokens.Onboarding.authContentHorizontalPadding)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var backgroundView: some View {
        if let nsImage = NSImage(named: DesignTokens.Onboarding.authBackgroundAssetName) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()
        } else {
            // Sky → grass placeholder until the asset ships. Approximates the
            // photographic background visually so dev builds aren't broken.
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(red: 0.55, green: 0.78, blue: 0.95), location: 0.00),
                    .init(color: Color(red: 0.65, green: 0.85, blue: 0.97), location: 0.45),
                    .init(color: Color(red: 0.60, green: 0.83, blue: 0.62), location: 0.78),
                    .init(color: Color(red: 0.32, green: 0.66, blue: 0.34), location: 1.00)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(
                width: DesignTokens.Onboarding.authIconSize,
                height: DesignTokens.Onboarding.authIconSize
            )
    }

    private var continueButton: some View {
        Button(action: onSignIn) {
            HStack(spacing: 12) {
                Image("Social Icons")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                Text("Continue with Google")
                    .font(DesignTokens.Onboarding.authButtonFont)
                    .foregroundStyle(DesignTokens.Onboarding.authTitleColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: DesignTokens.Onboarding.authButtonHeight)
            .background(hovering ? DesignTokens.Onboarding.authButtonHover
                                 : DesignTokens.Onboarding.authButtonRest)
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .frame(maxWidth: DesignTokens.Onboarding.authButtonMaxWidth)
    }

    /// Inline status: sign-in error (tap to dismiss) takes precedence; otherwise
    /// "Waiting for browser to complete sign-in…" while in-flight. Inherits the
    /// pattern shipped in the OAuth abandoned-flow PR.
    @ViewBuilder
    private var statusLine: some View {
        if let error = auth.errorMessage {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(Color.orange.opacity(0.95))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .onTapGesture { AuthService.shared.errorMessage = nil }
        } else if auth.isLoading {
            Text("Waiting for browser to complete sign-in…")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Onboarding.authStatusColor)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Done-step hotkey listener

/// Local NSEvent monitor active only while the done step is visible. When the
/// user presses the configured primary hotkey, fires `onFinish` (same path
/// the old "Open Stash" CTA used to take). Local monitor only fires when the
/// onboarding window has focus — if focus is elsewhere, the global Carbon
/// hotkey path takes over and shows the panel as usual.
private struct DoneStepHotkeyListener: ViewModifier {
    var onFinish: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let s = AppSettings.shared
            let carbonMods = nsToCarbonModifiers(event.modifierFlags)
            if UInt32(event.keyCode) == s.hotKeyCode && carbonMods == s.hotKeyModifiers {
                onFinish()
                return nil
            }
            return event
        }
    }

    private func remove() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - Staggered appear wrapper

private struct StaggeredAppear<Content: View>: View {
    let index: Int
    @ViewBuilder let content: () -> Content

    @State private var visible = false

    var body: some View {
        content()
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : DesignTokens.Onboarding.entranceTranslate)
            .onAppear {
                let delay = Double(index) * DesignTokens.Onboarding.entranceStaggerSeconds
                withAnimation(DesignTokens.Onboarding.entranceCurve.delay(delay)) {
                    visible = true
                }
            }
    }
}
