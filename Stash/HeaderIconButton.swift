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
    var size: CGFloat = 32
    let action: () -> Void
    var isActive: Bool = false
    var activeBackgroundColor: Color = Color.clear

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            iconView
                .foregroundColor(iconColor)
                .frame(width: size - 4, height: size - 4)
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
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.44, weight: .medium))
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.5, height: size * 0.5)
        }
    }

    private var backgroundColor: Color {
        if isActive { return activeBackgroundColor }
        if isHovering { return DesignTokens.Icon.backgroundHover }
        return DesignTokens.Icon.backgroundRest
    }
}
