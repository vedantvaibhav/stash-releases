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

    /// Active-state colors for the notes filter bar pill (icon + "F" letter).
    /// Bluish-white at bumped opacity reads "cool/glacial" without going full
    /// cyan — chromaticity collapses below ~0.25 opacity for near-white colors,
    /// so the opacities here are above that floor. If rendering still reads as
    /// neutral gray on dark glass, swap `activeBackground` to a more saturated
    /// cyan as a one-line follow-up.
    enum FilterPill {
        static let activeBackground = Color(red: 0.92, green: 0.95, blue: 1.0).opacity(0.28)
        static let activeBorder     = Color(red: 0.85, green: 0.92, blue: 1.0).opacity(0.42)
        static let activeForeground = Color(red: 0.88, green: 0.94, blue: 1.0)
    }

    /// Bottom-center status notification (long-running transcription block).
    enum Notification {
        /// Near-black capsule background.
        static let background  = Color(red: 0.10, green: 0.10, blue: 0.11)
        /// Warning triangle tint (amber).
        static let warningIcon = Color(red: 0.98, green: 0.74, blue: 0.18)
        /// Primary button — light fill, dark label.
        static let primaryButtonFill  = Color.white.opacity(0.92)
        static let primaryButtonLabel = Color(red: 0.10, green: 0.10, blue: 0.11)
        /// Secondary button — transparent fill, hairline outline, light label.
        static let secondaryButtonOutline = Color.white.opacity(0.18)
        static let secondaryButtonLabel   = Color.white.opacity(0.85)
        /// Title / body text.
        static let titleColor = Color.white
        static let bodyColor  = Color.white.opacity(0.70)
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
        // Asymmetric inner spacing. Layout (LTR):
        //   [4pt lead pad][24 iconDisc][6 icon→timer][label][11 timer→dot][10 dot][8pt trail pad]
        // Per design feedback: icon→timer slightly tighter (-2pt) than the
        // base contentSpacing, timer→dot slightly looser (+3pt) so the
        // pill doesn't read as cramped on the right. Trailing padding +4
        // gives the dot more breathing room from the pill's right edge.
        //
        // Pill width is now computed dynamically per displayed mode by the
        // controller's sizeForCurrentMode (using NSString.size on the label
        // text), so each state — recording timer, "Failed", "No audio",
        // "Pasted ✓", "Note saved", "Network timeout" — gets exactly the width
        // it needs. This `width` constant is the FALLBACK used by
        // restorePosition during the panel's initial buildPanel call,
        // before any mode is set; kept at the typical recording size so
        // first-show slide+fade lands at a sensible target.
        static let width: CGFloat = 105
        static let height: CGFloat = 32
        static let iconDiscSize: CGFloat = 24
        static let iconGlyphSize: CGFloat = 14
        // Asymmetric outer padding — more on the right.
        static let leadingPadding: CGFloat = 4
        static let trailingPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 4
        // Inner spacings — used as label's left/right padding inside the
        // HStack(spacing: 0). Splitting them lets the iconDisc→timer and
        // timer→dot gaps differ.
        static let iconToTimerSpacing: CGFloat = 6
        static let timerToDotSpacing: CGFloat = 11
        // Legacy generic content spacing — retained for any caller still
        // referring to it; new code uses iconToTimer/timerToDot.
        static let contentSpacing: CGFloat = 8
        static let recordingDotSize: CGFloat = 10
        static let stopTapTargetSize: CGFloat = 10

        // Panel-frame animation — cubic-bezier(0.22, 1, 0.36, 1) over 400ms.
        // Used by the drag-to-snap reposition. Tuned to read as a deliberate
        // settle into the snap corner rather than a hard snap.
        static let frameAnimationDuration: TimeInterval = 0.40
        static let frameAnimationCurveCP1x: Double = 0.22
        static let frameAnimationCurveCP1y: Double = 1.0
        static let frameAnimationCurveCP2x: Double = 0.36
        static let frameAnimationCurveCP2y: Double = 1.0

        // Phase-change animation — recording → processing (shrink to circle)
        // and back (expand). 0.27s easeInEaseOut. The pill content uses an
        // asymmetric transition so the capsule's geometry (rounded corners)
        // morphs first, then content fades in — see contentInsertionDelay /
        // contentInsertionDuration below.
        static let phaseAnimationDuration: TimeInterval = 0.27

        // Asymmetric content-swap transition timings. When mode changes,
        // the OLD content fades out fast (`contentRemovalDuration`) so the
        // capsule reads as "empty" while the AppKit panel resizes, then
        // the NEW content fades in (`contentInsertionDuration`) after a
        // small delay (`contentInsertionDelay`) so the rounded corners
        // reach their target shape before text appears.
        static let contentRemovalDuration: TimeInterval = 0.08
        static let contentInsertionDelay: TimeInterval = 0.16
        static let contentInsertionDuration: TimeInterval = 0.16

        // Completion hold durations — how long the pill displays a completion
        // message before hiding (or returning to recording for mid-recording
        // warnings). `completionDefaultHold` matches the historical 1.6s
        // behaviour for end-of-recording results ("Note saved", "Pasted ✓",
        // "No audio"). `completionWarningHold` is the longer hold used for
        // mid-recording warnings (85-min, 20-MB) so the user has time to
        // read them while the recording continues.
        static let completionDefaultHold: TimeInterval = 1.6
        static let completionWarningHold: TimeInterval = 3.5
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

        // Tab bar labels (All / Clipboard / Notes / Files) and the notes
        // filter bar title/count — SF Pro 14 / regular (design spec).
        static let tabLabelFont = Font.system(size: 14, weight: .regular)

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
        /// Open: fade 0 → 1 with a 10 pt downward settle. Ease-in-out, ~20%
        /// faster than the earlier 0.32s — the prior duration felt sluggish
        /// per test feedback.
        static let openDuration: CFTimeInterval = 0.26
        /// Close: fade 1 → 0 with an 8 pt upward lift. Ease-in-out, slightly
        /// faster than open so dismissal reads as quick.
        static let closeDuration: CFTimeInterval = 0.21
        /// Panel starts 10 pt above its final y on open.
        static let openSlideOffset: CGFloat = 10
        /// Panel ends 8 pt above its start y on close.
        static let closeSlideOffset: CGFloat = 8
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

        // Vertical gap between the 48×48 thumbnail and the filename label.
        // Sized so the selection-state accent fill behind the filename has
        // visible breathing room above it instead of kissing the thumbnail
        // bottom edge (the fill extends `labelBackdropPaddingV` above the
        // text baseline, so this gap should comfortably exceed that).
        static let mediaToFilenameGap: CGFloat = 10
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
