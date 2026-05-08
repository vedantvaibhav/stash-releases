import SwiftUI
import AppKit

enum DesignTokens {
    enum Icon {
        // Background fill states
        static let backgroundRest   = Color.white.opacity(0.06)
        static let backgroundHover  = Color.white.opacity(0.10)

        // Icon tint states
        static let tintRecording    = Color(red: 0.863, green: 0.149, blue: 0.149) // #DC2626
        static let tintPlusButton   = Color.white.opacity(0.45)
        static let tintMuted        = Color.white.opacity(0.72)

        // Active background (mic while recording)
        static let backgroundActive = Color(red: 0.102, green: 0.102, blue: 0.102) // #1A1A1A
    }

    enum Spacing {
        static let panel: CGFloat = 20        // outer panel padding
        static let sectionGap: CGFloat = 20   // gap between sections
        static let itemGap: CGFloat = 4       // gap between list rows (where non-flush lists are used)
        static let cardGap: CGFloat = 8       // gap between cards

    }

    /// Geometry shared by every `StashListRow` caller — clipboard, notes, pinned.
    enum Row {
        static let height: CGFloat = 34
        static let horizontalPadding: CGFloat = 8
        static let spacing: CGFloat = 8
        static let cornerRadius: CGFloat = 8
    }

    /// Floating transcription pill (redesign 2026-04-21). Fixed dimensions so Recording,
    /// Processing and Copied states share identical width/height per Figma node 280-981.
    enum Pill {
        static let width: CGFloat = 130
        static let height: CGFloat = 32
        static let iconDiscSize: CGFloat = 24
        static let iconGlyphSize: CGFloat = 14
        static let leadingPadding: CGFloat = 4
        static let trailingPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 4
        static let contentSpacing: CGFloat = 8
        static let recordingDotSize: CGFloat = 10
        static let stopTapTargetSize: CGFloat = 32

        // Expanded form (short-transcript handoff). Capsule grows into a
        // rounded rectangle to host the cleaned text + Copy/Dismiss footer.
        static let expandedWidth: CGFloat = 520
        static let expandedMaxHeight: CGFloat = 280
        static let expandedCornerRadius: CGFloat = 16
        static let expandedPadding: CGFloat = 16
        static let expandedFooterGap: CGFloat = 12
        static let expandedEyebrowToTextGap: CGFloat = 10
        static let expandedTextToFooterGap: CGFloat = 14
        static let expandedButtonHeight: CGFloat = 32
        static let expandedButtonHorizontalPadding: CGFloat = 14
        static let expandedButtonCornerRadius: CGFloat = 8
        static let expandedButtonGap: CGFloat = 8

        // Animation — cubic-bezier(0.22, 1, 0.36, 1) over 280ms, matching
        // docs/auth/success.html's staggered fade for visual consistency.
        static let expandedAnimationDuration: TimeInterval = 0.28
        static let expandedAnimationCurveCP1x: Double = 0.22
        static let expandedAnimationCurveCP1y: Double = 1.0
        static let expandedAnimationCurveCP2x: Double = 0.36
        static let expandedAnimationCurveCP2y: Double = 1.0

        // Auto-dismiss while expanded.
        static let expandedAutoDismissSeconds: TimeInterval = 30

        // Copy-button success-flash duration before the pill collapses.
        static let expandedCopyFlashSeconds: TimeInterval = 1.2

        // Eyebrow + text styling.
        static let expandedEyebrowFont = Font.system(size: 11, weight: .semibold)
        static let expandedEyebrowColor = Color.white.opacity(0.55)
        static let expandedTextFont = Font.system(size: 14, weight: .regular)
        static let expandedTextColor = Color.white.opacity(0.92)
        static let expandedTextLineSpacing: CGFloat = 4

        // Filled (primary) Copy button.
        static let expandedFilledFont = Font.system(size: 13, weight: .medium)
        static let expandedFilledForeground = Color.white
        static let expandedFilledBackgroundRest = Color.white.opacity(0.18)
        static let expandedFilledBackgroundHover = Color.white.opacity(0.26)

        // Ghost (secondary) Dismiss button.
        static let expandedGhostFont = Font.system(size: 13, weight: .regular)
        static let expandedGhostForeground = Color.white.opacity(0.70)
        static let expandedGhostBackgroundRest = Color.clear
        static let expandedGhostBackgroundHover = Color.white.opacity(0.10)
    }

    enum Typography {
        // Primary list item text (clipboard rows, pinned cards, notes rows).
        // SF Pro weight 510 from Figma maps to the closest SwiftUI weight: .medium.
        static let itemFont = Font.system(size: 11.6, weight: .medium)
        static let itemColor = Color(hex: "#A3A3A3")
        static let itemLineHeight: CGFloat = 15.467

        // Section headers (Pinned, Recent Files, Recent Notes, date groups).
        static let sectionFont = Font.system(size: 11, weight: .semibold)
        static let sectionColor = Color(hex: "#525252")

        // Note editor — body text and heading levels.
        // Body: 15 pt regular, 20 pt line height (≈ 1.33 multiple).
        static let bodyFont = Font.system(size: 15, weight: .regular)
        static let bodyLineHeight: CGFloat = 20

        static let h1Font = Font.system(size: 24, weight: .semibold)
        static let h2Font = Font.system(size: 20, weight: .semibold)
        static let h3Font = Font.system(size: 17, weight: .semibold)

        // AppKit equivalents (NSTextView needs NSFont, not SwiftUI Font).
        // Keep both in lockstep with the SwiftUI sizes above.
        static let bodyNSFont: NSFont = .systemFont(ofSize: 15, weight: .regular)
        static let h1NSFont: NSFont = .systemFont(ofSize: 24, weight: .semibold)
        static let h2NSFont: NSFont = .systemFont(ofSize: 20, weight: .semibold)
        static let h3NSFont: NSFont = .systemFont(ofSize: 17, weight: .semibold)
        static let inlineCodeNSFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    enum PanelAnimation {
        /// Open: fade 0 → 1 with an 8 pt downward settle. Ease-out.
        static let openDuration: CFTimeInterval = 0.18
        /// Close: fade 1 → 0 with a 6 pt upward lift. Ease-in. Slightly faster than open.
        static let closeDuration: CFTimeInterval = 0.14
        /// Panel starts 8 pt above its final y on open.
        static let openSlideOffset: CGFloat = 8
        /// Panel ends 6 pt above its start y on close.
        static let closeSlideOffset: CGFloat = 6
    }

    enum Onboarding {
        // Window — rounded, transparent, OS drop shadow.
        static let windowSize = NSSize(width: 720, height: 560)
        static let windowCornerRadius: CGFloat = 16
        static let background = Color.black
        static let foreground = Color.white

        // Spacing
        static let outerPadding: CGFloat = 56
        static let stepGap: CGFloat = 24
        static let chipGap: CGFloat = 12
        static let hotkeyRowGap: CGFloat = 14
        static let hotkeyLabelWidth: CGFloat = 140
        static let bodyMaxWidthShort: CGFloat = 420
        static let bodyMaxWidthLong: CGFloat = 460
        static let progressDotSize: CGFloat = 6
        static let progressDotGap: CGFloat = 8

        // Hotkey chip
        static let chipPaddingH: CGFloat = 14
        static let chipPaddingV: CGFloat = 8
        static let chipCornerRadius: CGFloat = 10
        static let chipFont = Font.system(size: 17, weight: .medium, design: .rounded)
        static let chipBackground = Color.white.opacity(0.08)
        static let chipBorder = Color.white.opacity(0.16)

        // CTA button
        static let ctaPaddingH: CGFloat = 22
        static let ctaPaddingV: CGFloat = 12
        static let ctaCornerRadius: CGFloat = 12
        static let ctaFont = Font.system(size: 14, weight: .semibold)
        static let ctaBackgroundRest = Color.white.opacity(0.10)
        static let ctaBackgroundHover = Color.white.opacity(0.16)

        // Typography
        static let titleFont = Font.system(size: 28, weight: .semibold)
        static let bodyFont  = Font.system(size: 15, weight: .regular)
        static let bodyColor = Color.white.opacity(0.78)

        // Entrance animation — mirrors docs/auth/success.html
        static let entranceDuration: Double = 0.7
        static let entranceTranslate: CGFloat = 12
        static let entranceStaggerSeconds: Double = 0.15
        static let entranceCurve: Animation = .easeOut(duration: 0.7)

        // Media slot — fixed 16:9 placeholder for demo videos
        static let mediaSlotWidth: CGFloat = 480
        static let mediaSlotHeight: CGFloat = 270
        static let mediaSlotCornerRadius: CGFloat = 12
        static let mediaSlotBackground = Color.white.opacity(0.04)
        static let mediaSlotBorder = Color.white.opacity(0.08)

        // Recording step — bullet rows
        static let recordingBulletGap: CGFloat = 10
        static let recordingBulletInline: CGFloat = 6

        // Auth screen (screen 1) — full-bleed background with welcome card
        static let authIconSize: CGFloat = 64
        static let authContentTopPadding: CGFloat = 56
        static let authContentSpacing: CGFloat = 18
        static let authTitleSubtitleGap: CGFloat = 10
        static let authButtonTopGap: CGFloat = 32
        static let authButtonHeight: CGFloat = 56
        static let authButtonMaxWidth: CGFloat = 480
        static let authContentHorizontalPadding: CGFloat = 64
        static let authTitleFont = Font.custom("Inter-SemiBold", size: 32)
        static let authSubtitleFont = Font.custom("Inter-Regular", size: 18)
        static let authButtonFont = Font.custom("Inter-SemiBold", size: 16)
        static let authTitleColor = Color.black
        static let authSubtitleColor = Color.black.opacity(0.55)
        static let authButtonRest = Color.white
        static let authButtonHover = Color(white: 0.94)
        static let authStatusColor = Color.black.opacity(0.55)

        // Asset name for the full-bleed background image. Drop a matching
        // image set into Assets.xcassets to enable; until then the auth
        // screen renders a sky→grass gradient placeholder.
        static let authBackgroundAssetName = "OnboardingAuthBackground"
    }

    enum FileShelf {
        // Finder-style selection visual. Colors come from system NSColor at
        // render time so the user's accent setting + light/dark appearance
        // are honored automatically.
        static let iconBackdropInset: CGFloat = 4
        static let iconBackdropCornerRadius: CGFloat = 6
        static let labelBackdropCornerRadius: CGFloat = 4
        static let labelBackdropPaddingH: CGFloat = 4
        static let labelBackdropPaddingV: CGFloat = 2
    }
}

// MARK: - Color(hex:) helper

extension Color {
    /// Initialises a Color from a hex string like "#A3A3A3" or "A3A3A3".
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >>  8) & 0xFF) / 255
        let b = Double( v        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
