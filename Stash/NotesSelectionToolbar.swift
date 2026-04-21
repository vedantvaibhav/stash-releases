import SwiftUI

/// Pill-shaped floating toolbar matching Figma (Notion-style). Stateless —
/// the controller owns `NotesSelectionToolbarState` and dispatches commands.
struct NotesSelectionToolbar: View {
    @ObservedObject var state: NotesSelectionToolbarState
    let onCommand: (ToolbarCommand) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Group 1 — paragraph style
            styleMenu
            divider

            // Group 2 — inline character formats
            HStack(spacing: DesignTokens.Spacing.toolbarItemSpacing) {
                iconButton("bold", command: .bold, format: .bold)
                iconButton("italic", command: .italic, format: .italic)
                iconButton("underline", command: .underline, format: .underline)
                iconButton("strikethrough", command: .strikethrough, format: .strikethrough)
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
            divider

            // Group 3 — link / code
            HStack(spacing: DesignTokens.Spacing.toolbarItemSpacing) {
                iconButton("curlybraces", command: .inlineCode, format: .inlineCode)
                iconButton("link", command: .link, format: .link)
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
            divider

            // Group 4 — color (stub) + more (stub)
            HStack(spacing: DesignTokens.Spacing.toolbarItemSpacing) {
                disabledIconButton("paintpalette", tooltip: "Coming soon")
                disabledIconButton("ellipsis", tooltip: "Coming soon")
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
        }
        .frame(height: DesignTokens.Spacing.toolbarHeight)
        .background(
            Capsule().fill(PanelCardChromeStyle.bgDefault)
        )
        .fixedSize()
    }

    // MARK: Buttons

    private func iconButton(_ symbol: String, command: ToolbarCommand, format: TextFormat) -> some View {
        let isActive = state.snapshot.activeFormats.contains(format)
        return Button(action: { onCommand(command) }) {
            Image(systemName: symbol)
                .font(.system(size: DesignTokens.Spacing.toolbarIconSize, weight: .regular))
                .foregroundStyle(isActive ? Color.white : DesignTokens.Icon.tintMuted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func disabledIconButton(_ symbol: String, tooltip: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: DesignTokens.Spacing.toolbarIconSize, weight: .regular))
            .foregroundStyle(DesignTokens.Icon.tintMuted.opacity(0.4))
            .frame(width: 20, height: 20)
            .help(tooltip)
    }

    // MARK: Heading menu

    private var styleMenu: some View {
        Menu {
            Button("Paragraph") { onCommand(.heading(.paragraph)) }
            Button("Heading 1") { onCommand(.heading(.h1)) }
            Button("Heading 2") { onCommand(.heading(.h2)) }
            Button("Heading 3") { onCommand(.heading(.h3)) }
        } label: {
            HStack(spacing: 4) {
                Text(currentHeadingLabel)
                    .font(.system(size: DesignTokens.Spacing.toolbarIconSize, weight: .regular))
                    .foregroundStyle(DesignTokens.Icon.tintMuted)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(DesignTokens.Icon.tintMuted)
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var currentHeadingLabel: String {
        switch state.snapshot.heading {
        case .paragraph: return "Paragraph"
        case .h1:        return "Heading 1"
        case .h2:        return "Heading 2"
        case .h3:        return "Heading 3"
        }
    }

    // MARK: Dividers

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 18)
    }
}
