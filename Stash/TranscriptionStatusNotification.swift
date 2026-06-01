import SwiftUI

/// Bottom-center status notification shown when a transcription upload stalls
/// (network down, repeated transient failures). Dark capsule with a warning
/// icon, title + body, an X close affordance, and two action buttons.
///
/// Fully parameterized — the view hardcodes no copy. The owning controller
/// (`StatusPanelController`) supplies title/body/labels/actions and morphs
/// them in place as the retry state evolves.
struct TranscriptionStatusNotification: View {
    let title: String
    /// Body copy. Named `message` (not `body`) to avoid colliding with the
    /// View protocol's required `var body`.
    let message: String
    let primaryLabel: String
    let primaryAction: () -> Void
    let secondaryLabel: String
    let secondaryAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.Notification.warningIcon)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.Notification.titleColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(DesignTokens.Notification.bodyColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button(action: secondaryAction) {
                    Text(secondaryLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignTokens.Notification.secondaryButtonLabel)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(DesignTokens.Notification.secondaryButtonOutline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: primaryAction) {
                    Text(primaryLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignTokens.Notification.primaryButtonLabel)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(DesignTokens.Notification.primaryButtonFill)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DesignTokens.Notification.background)
                .shadow(color: Color.black.opacity(0.35), radius: 18, y: 8)
        )
    }
}
