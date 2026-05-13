import SwiftUI
import AppKit
import Combine

/// One toast payload — text + how long to hold once shown. Lives separately
/// from the pill's `PillMode` because toasts are independent of phase
/// transitions and stack via replacement rather than mode mutation.
struct TranscriptionToastMessage: Equatable {
    let text: String
    let hold: TimeInterval

    init(text: String, hold: TimeInterval = DesignTokens.Pill.toastDefaultHoldDuration) {
        self.text = text
        self.hold = hold
    }
}

/// Drives the toast SwiftUI body. The controller swaps `current` to render
/// a new toast (or nil to render nothing while no toast is showing).
final class TranscriptionToastDisplayState: ObservableObject {
    @Published var current: TranscriptionToastMessage?
}

/// SwiftUI body for the toast. Capsule background, single line of text, same
/// height as the pill. Width is driven by the AppKit panel frame (set by the
/// controller from NSString-measured text), so this view fills its hosting
/// panel exactly.
struct TranscriptionToastView: View {
    @ObservedObject var state: TranscriptionToastDisplayState

    // Pre-computed so the body's `.padding(.horizontal:)` argument is a
    // simple `CGFloat` lookup rather than an inline arithmetic expression
    // — the inline form was a contributor to SourceKit's type-check
    // timeout on the body chain.
    private var horizontalPadding: CGFloat {
        DesignTokens.Pill.leadingPadding + DesignTokens.Pill.iconDiscSize / 2
    }

    @ViewBuilder
    private var messageBody: some View {
        if let message = state.current {
            Text(message.text)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black, in: Capsule())
                .transition(.opacity)
        } else {
            Color.clear
        }
    }

    var body: some View {
        messageBody
            .animation(.easeInOut(duration: DesignTokens.Pill.toastEnterDuration),
                       value: state.current)
    }
}

/// SwiftUI root for the toast NSHostingView. Mirrors PillRootView's shape so
/// the panel/host setup is structurally identical to the pill's.
struct TranscriptionToastRootView: View {
    @ObservedObject var state: TranscriptionToastDisplayState
    var body: some View { TranscriptionToastView(state: state) }
}
