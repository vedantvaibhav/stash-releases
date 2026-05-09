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
        // Sized so the visible gap between the timer and the red stop dot
        // matches `contentSpacing` (the gap between iconDisc and timer):
        //   visible gap = pillWidth - trailingPadding - dotSize - leadingPadding
        //                 - iconDiscSize - contentSpacing - labelWidth
        // For a typical "MM:SS" label (~40pt at monospaced 14pt regular),
        // pillWidth = 104 + tapTargetSize=18 lands the visible gap at ~6-8pt
        // (close to contentSpacing). Hour-plus recordings ("1:23:45")
        // overflow slightly — known edge case worth living with for the
        // typical-case symmetry.
        static let width: CGFloat = 104
        static let height: CGFloat = 32
        static let iconDiscSize: CGFloat = 24
        static let iconGlyphSize: CGFloat = 14
        static let leadingPadding: CGFloat = 4
        static let trailingPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 4
        static let contentSpacing: CGFloat = 8
        static let recordingDotSize: CGFloat = 10
        // Stop button tap target. 18pt is the maximum that doesn't overlap
        // the timer label at the configured pillWidth — any larger and the
        // tap target's invisible left edge slides under the timer text.
        static let stopTapTargetSize: CGFloat = 18

        // Panel-frame animation — cubic-bezier(0.22, 1, 0.36, 1) over 400ms.
        // Used by the drag-to-snap reposition. Tuned to read as a deliberate
        // settle into the snap corner rather than a hard snap.
        static let frameAnimationDuration: TimeInterval = 0.40
        static let frameAnimationCurveCP1x: Double = 0.22
        static let frameAnimationCurveCP1y: Double = 1.0
        static let frameAnimationCurveCP2x: Double = 0.36
        static let frameAnimationCurveCP2y: Double = 1.0

        // Phase-change animation — used when the pill shrinks from the full
        // width to a 32×32 circle (recording → processing) and expands back
        // (processing → completion). Length is tuned to fit a staggered
        // SwiftUI cross-fade: fast removal of the prior layout, beat,
        // slow insertion of the new layout. The AppKit panel uses ease-
        // in-out timing over this same duration so its mid-motion lines
        // up with the SwiftUI "slows down" pause between fade-out and
        // fade-in.
        static let phaseAnimationDuration: TimeInterval = 0.55

        // SwiftUI transition timings used by TranscriptionPillView's
        // asymmetric branch transitions. Splitting these out so the pill
        // body and the AppKit panel are tuned together rather than each
        // branch hardcoding its own number.
        static let phaseRemovalDuration: TimeInterval = 0.15
        static let phaseInsertionDelay: TimeInterval = 0.18
        static let phaseInsertionDuration: TimeInterval = 0.40
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
        /// Open: fade 0 → 1 with a 12 pt downward settle. Ease-in-out so the
        /// motion has the same "smooth through the middle" feel as the
        /// transcription pill's processing-shrink.
        static let openDuration: CFTimeInterval = 0.32
        /// Close: fade 1 → 0 with a 10 pt upward lift. Ease-in-out, slightly
        /// faster than open so dismissal reads as deliberate but not sluggish.
        static let closeDuration: CFTimeInterval = 0.26
        /// Panel starts 12 pt above its final y on open.
        static let openSlideOffset: CGFloat = 12
        /// Panel ends 10 pt above its start y on close.
        static let closeSlideOffset: CGFloat = 10
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
