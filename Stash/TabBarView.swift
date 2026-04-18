import SwiftUI

// TabBarView.swift
// Tabs: All, Clipboard, Notes, Files (+ mic). Active tab: filled capsule; no bar/track behind the row.

/// Tab labels — SF Pro 14 / 400 / 16px line-height / center (design spec).
private enum TabBarTypography {
    static let fontSize: CGFloat = 14
    static let lineHeight: CGFloat = 16

    /// `Font.system` uses SF Pro on macOS; weight 400 = regular.
    static var labelFont: Font {
        .system(size: fontSize, weight: .regular)
    }
}

enum PanelMainTab: Int, CaseIterable, Identifiable, Hashable {
    case all
    case clipboard
    case notes
    case files

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .clipboard: return "Clipboard"
        case .notes: return "Notes"
        case .files: return "Files"
        }
    }
}

struct TabBarView: View {
    @Binding var selectedTab: PanelMainTab
    /// Same behaviour as notes "Transcribe" — caller sets showTranscription + startRecording if needed.
    var onMicTap: () -> Void
    var onAddNote: () -> Void

    @State private var hoveredTab: PanelMainTab?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 12) {
                ForEach(PanelMainTab.allCases) { tab in
                    tabPill(tab)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                HeaderIconButton(
                    icon: .asset("plus-icon"),
                    iconColor: DesignTokens.Icon.tintPlusButton,
                    action: onAddNote
                )

                HeaderIconButton(
                    icon: .system("waveform"),
                    iconColor: DesignTokens.Icon.tintRecording,
                    action: onMicTap,
                    activeBackgroundColor: DesignTokens.Icon.backgroundActive
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }

    private func tabPill(_ tab: PanelMainTab) -> some View {
        let isSelected = selectedTab == tab
        let isHovered = hoveredTab == tab

        return Button {
            selectedTab = tab
        } label: {
            Text(tab.title)
                .font(TabBarTypography.labelFont)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .frame(height: TabBarTypography.lineHeight, alignment: .center)
                .foregroundStyle(Color.white.opacity(textOpacity(selected: isSelected, hovered: isHovered)))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(isHovered ? 0.16 : 0.13))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { inside in
            if inside {
                hoveredTab = tab
            } else if hoveredTab == tab {
                hoveredTab = nil
            }
        }
    }

    /// Inactive: dim. Inactive + hover: brighter. Active: full white on filled pill.
    private func textOpacity(selected: Bool, hovered: Bool) -> Double {
        if selected { return 1 }
        if hovered { return 0.72 }
        return 0.35
    }
}
