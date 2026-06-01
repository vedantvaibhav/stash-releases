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

    /// Animation curves, spring parameters, and the reduce-motion gate.
    /// Curves follow Emil Kowalski's "strong custom easing" guidance — the
    /// built-in SwiftUI/Core Animation easings are too weak. cubic-bezier
    /// control points below are the strong ease-out (0.23, 1, 0.32, 1) and
    /// strong ease-in-out (0.77, 0, 0.175, 1) from the design-engineering skill.
    enum Motion {
        // Strong ease-out — entrances/exits (starts fast, feels responsive).
        static let strongEaseOutCP: (Double, Double, Double, Double) = (0.23, 1.0, 0.32, 1.0)
        // Strong ease-in-out — on-screen movement that isn't a spring.
        static let strongEaseInOutCP: (Double, Double, Double, Double) = (0.77, 0.0, 0.175, 1.0)

        // ONE spring drives every pill frame change — entrance (descend from
        // top), state morphs (recording → dot → result), and exit (collapse to
        // a circle). Bouncy on purpose (≈0.36 bounce, dampingRatio 0.64): the
        // capsule overshoots and settles, so appearance/morph/disappearance all
        // read as the same springy material. 0.42s response = lively but not
        // frantic. Used by PillMorphAnimator + the content crossfade timing.
        static let morphResponse: Double = 0.42
        static let morphDampingRatio: Double = 0.64
        // Hard cap on how long the spring driver runs before snapping to the
        // target, so an under-damped (bouncy) tail can never leave it un-settled.
        static let morphSettleCap: TimeInterval = 0.7

        static func caEaseOut() -> CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints:
                Float(strongEaseOutCP.0), Float(strongEaseOutCP.1),
                Float(strongEaseOutCP.2), Float(strongEaseOutCP.3))
        }

        /// True when the user has asked the system to minimise motion. Springs
        /// and blur are dropped to plain opacity in that case (emil: reduced
        /// motion = fewer/gentler, not zero).
        static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
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

        // Fallback duration for the AppKit panel-frame animation on the rare
        // animated-while-hidden phase change (the common visible morph uses the
        // PillMorphAnimator spring, which ignores this). Strong ease-out comes
        // from DesignTokens.Motion.
        static let frameAnimationDuration: TimeInterval = 0.40

        // Phase-change frame duration for the NSAnimationContext fallback path
        // (visible morphs spring instead — see PillMorphAnimator).
        static let phaseAnimationDuration: TimeInterval = 0.27

        // Completion hold durations — how long the pill displays a completion
        // message before hiding (or returning to recording for mid-recording
        // warnings). `completionDefaultHold` matches the historical 1.6s
        // behaviour for end-of-recording results ("Note saved", "Pasted ✓",
        // "No audio"). `completionWarningHold` is the longer hold used for
        // mid-recording warnings (85-min, 20-MB) so the user has time to
        // read them while the recording continues.
        static let completionDefaultHold: TimeInterval = 1.6
        static let completionWarningHold: TimeInterval = 3.5

        // Masked crossfade for state→state text/glyph swaps. Old content
        // blurs+fades out fast; new content blurs in after a short delay so
        // the swap reads as one layer "melting" into the next rather than two
        // crisp layers crossing (emil: "use blur to mask imperfect
        // transitions"). Heavier blur = more liquid smear. Total < 300ms.
        static let crossfadeOutDuration: TimeInterval = 0.10
        static let crossfadeInDelay: TimeInterval = 0.12
        static let crossfadeInDuration: TimeInterval = 0.18
        static let crossfadeBlurRadius: CGFloat = 10
        // Content crossfade starts slightly shrunk + transparent (never
        // scale(0) — emil): a barely-there settle as the new content melts in.
        static let entranceScale: CGFloat = 0.96

        // Text-only completion states (errors + warnings: "No audio", "Failed",
        // "5 min left", "Almost full") drop the icon disc and render just the
        // message. These label paddings sit INSIDE the outer leading(4)/
        // trailing(8) so total inset is balanced at 14pt each side
        // (4+10 == 8+6). sizeForCurrentMode mirrors these exact values.
        static let textOnlyLabelLeadingPad: CGFloat = 10
        static let textOnlyLabelTrailingPad: CGFloat = 6

        // Processing/delivery longer than this flips the session into the
        // long-running "walk away" path (clipboard-only delivery + card).
        static let longRunningThresholdSeconds: TimeInterval = 6.0
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
        /// PILL entrance: descends FROM THE TOP — starts `entranceFromTopOffset`
        /// above its resting frame and the bouncy spring (DesignTokens.Motion)
        /// pulls it down into place; alpha fades in over `entranceFadeDuration`
        /// so it's visible as it springs.
        static let entranceFromTopOffset: CGFloat = 30
        static let entranceFadeDuration: CFTimeInterval = 0.22

        /// PILL exit: the spring collapses the frame into the 32×32 circle (both
        /// edges gather to center, with a little squash-bounce). The fade waits
        /// `exitFadeDelay` so the circle visibly FORMS first, then vanishes over
        /// `exitFadeDuration`. This is the "gather into a dot," not a cut.
        static let exitFadeDelay: CFTimeInterval = 0.20
        static let exitFadeDuration: CFTimeInterval = 0.16

        /// MAIN content panel open/close (PanelController) — distinct from the
        /// pill above. Unchanged.
        static let openDuration: CFTimeInterval = 0.26
        static let closeDuration: CFTimeInterval = 0.21
        static let openSlideOffset: CGFloat = 10
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
