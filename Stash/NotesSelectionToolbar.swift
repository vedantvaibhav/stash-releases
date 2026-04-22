import SwiftUI

/// Pill-shaped floating toolbar matching Figma (Notion-style). The view holds
/// a weak-style `@ObservedObject` on `NotesSelectionToolbarState` owned by the
/// controller, so snapshot-level state changes trigger a re-render. Commands
/// flow out via the `onCommand` closure — the controller executes them on the
/// text view. (`ObservableObject` + `@Published` are used for macOS 13
/// compatibility; `@Observable` requires macOS 14.)
struct NotesSelectionToolbar: View {
    @ObservedObject var state: NotesSelectionToolbarState
    let onCommand: (ToolbarCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Row 1 — paragraph style + character formats
            HStack(spacing: DesignTokens.Spacing.toolbarItemSpacing) {
                styleMenu
                verticalSeparator
                iconButton("bold", command: .bold, format: .bold)
                iconButton("italic", command: .italic, format: .italic)
                iconButton("underline", command: .underline, format: .underline)
                iconButton("strikethrough", command: .strikethrough, format: .strikethrough)
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
            .frame(height: DesignTokens.Spacing.toolbarRowHeight)

            // Horizontal divider between rows
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            // Row 2 — link / code / stubs
            HStack(spacing: DesignTokens.Spacing.toolbarItemSpacing) {
                iconButton("link", command: .link, format: .link)
                iconButton("curlybraces", command: .inlineCode, format: .inlineCode)
                disabledIconButton("paintpalette", tooltip: "Coming soon")
                disabledIconButton("ellipsis", tooltip: "Coming soon")
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
            .frame(height: DesignTokens.Spacing.toolbarRowHeight)
        }
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.toolbarCornerRadius)
                .fill(DesignTokens.Toolbar.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.toolbarCornerRadius)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(symbol == "paintpalette" ? "Text color" : "More")
            .accessibilityValue(tooltip)
            .accessibilityAddTraits(.isButton)
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

    private var verticalSeparator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 18)
    }
}
