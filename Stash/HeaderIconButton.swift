import SwiftUI

enum IconSource {
    case system(String)
    case asset(String)
}

/// Reusable icon button for the panel header bar.
/// Circular background, hover highlight, consistent sizing across all header CTAs.
struct HeaderIconButton: View {
    let icon: IconSource
    let iconColor: Color
    let action: () -> Void
    var isActive: Bool = false
    var activeBackgroundColor: Color = Color.clear

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            iconView
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(backgroundColor)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .frame(width: 32, height: 32)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        }
    }

    private var backgroundColor: Color {
        if isActive { return activeBackgroundColor }
        if isHovering { return DesignTokens.Icon.backgroundHover }
        return DesignTokens.Icon.backgroundRest
    }
}
