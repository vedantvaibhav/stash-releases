import SwiftUI
import AppKit

struct OnboardingView: View {

    @ObservedObject var model: OnboardingViewModel
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject private var settings = AppSettings.shared

    private static let totalSteps = 5

    var body: some View {
        ZStack {
            DesignTokens.Onboarding.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content
                    .id(model.step)
                    .transition(.opacity)
                Spacer(minLength: 0)
                progressDots
                    .padding(.bottom, DesignTokens.Onboarding.outerPadding)
            }
            .padding(.horizontal, DesignTokens.Onboarding.outerPadding)
        }
        .foregroundStyle(DesignTokens.Onboarding.foreground)
        .frame(
            minWidth: DesignTokens.Onboarding.windowSize.width,
            minHeight: DesignTokens.Onboarding.windowSize.height
        )
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case 0: hotkeyStep
        case 1: featureCard(
            title: "Quick voice notes",
            body: "Press \(quickRecordChipText), talk for under 5 minutes. Stash transcribes, cleans up the filler, and drops the result on your clipboard.",
            glyph: "🎙️"
        )
        case 2: featureCard(
            title: "Meeting notes",
            body: "Press \(quickRecordChipText) for anything over 5 minutes. Stash records, transcribes, cleans, and saves a structured overview alongside the full transcript.",
            glyph: "📝"
        )
        case 3: featureCard(
            title: "Clipboard history",
            body: "Everything you copy lives one hotkey away. Pin the snippets you keep coming back to so they don't fall off the bottom.",
            glyph: "📋"
        )
        default: doneStep
        }
    }

    // MARK: - Welcome / hotkeys

    private var hotkeyStep: some View {
        VStack(spacing: DesignTokens.Onboarding.stepGap) {
            staggered(index: 0) {
                Text("Welcome to Stash")
                    .font(DesignTokens.Onboarding.titleFont)
            }
            staggered(index: 1) {
                VStack(alignment: .leading, spacing: DesignTokens.Onboarding.hotkeyRowGap) {
                    hotkeyRow(label: "Open Stash", chip: primaryChipText)
                    hotkeyRow(label: "Quick record", chip: quickRecordChipText)
                }
            }
            staggered(index: 2) {
                Text("These are your two hotkeys. You can change them anytime in Settings.")
                    .font(DesignTokens.Onboarding.bodyFont)
                    .foregroundStyle(DesignTokens.Onboarding.bodyColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: DesignTokens.Onboarding.bodyMaxWidthShort)
            }
            staggered(index: 3) {
                ctaButton(title: "Got it, next", action: advance)
            }
        }
    }

    private func hotkeyRow(label: String, chip: String) -> some View {
        HStack(spacing: DesignTokens.Onboarding.chipGap) {
            Text(label)
                .font(DesignTokens.Onboarding.bodyFont)
                .foregroundStyle(DesignTokens.Onboarding.bodyColor)
                .frame(width: DesignTokens.Onboarding.hotkeyLabelWidth, alignment: .leading)
            chipView(chip)
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

    // MARK: - Feature card

    private func featureCard(title: String, body: String, glyph: String) -> some View {
        VStack(spacing: DesignTokens.Onboarding.stepGap) {
            staggered(index: 0) {
                Text(glyph)
                    .font(.system(size: DesignTokens.Onboarding.cardArtSize))
            }
            staggered(index: 1) {
                Text(title)
                    .font(DesignTokens.Onboarding.titleFont)
            }
            staggered(index: 2) {
                Text(body)
                    .font(DesignTokens.Onboarding.bodyFont)
                    .foregroundStyle(DesignTokens.Onboarding.bodyColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: DesignTokens.Onboarding.bodyMaxWidthLong)
            }
            staggered(index: 3) {
                ctaButton(title: "Next", action: advance)
            }
        }
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
            staggered(index: 2) {
                ctaButton(title: "Open Stash", action: onFinish)
            }
        }
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
        let code = settings.quickRecordHotKeyCode
        if code == 0 || code == 0xFFFE {
            return "⌘⇧R"
        }
        return hotkeyBadgeString(keyCode: code, carbonModifiers: settings.quickRecordHotKeyModifiers)
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
