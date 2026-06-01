import SwiftUI

/// Subtle shimmer: the content sits at 0.55 opacity with a bright band that
/// sweeps left → right (1.4s loop, no autoreverse), momentarily lifting the
/// swept region to full opacity. Used by the inline "Waiting" indicator in
/// the notes filter bar.
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .opacity(0.55)
            .overlay(
                content
                    .mask(
                        GeometryReader { geo in
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .black, location: 0.5),
                                    .init(color: .clear, location: 1.0),
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: geo.size.width)
                            // phase 0 → band off-screen left; phase 1 → off-screen right.
                            .offset(x: (phase * 2 - 1) * geo.size.width)
                        }
                    )
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    /// Applies the subtle sweeping shimmer used by the "Waiting" indicator.
    func shimmer() -> some View { modifier(ShimmerModifier()) }
}
