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

        // Notes selection toolbar.
        static let toolbarHeight: CGFloat = 34
        static let toolbarIconSize: CGFloat = 14
        static let toolbarPadding: CGFloat = 8
        static let toolbarItemSpacing: CGFloat = 10
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
