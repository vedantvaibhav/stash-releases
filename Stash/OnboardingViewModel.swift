import Foundation

/// In-memory state for the onboarding window. Survives across menu-bar
/// re-presentations within the same app session; resets on relaunch
/// (controller singleton is recreated, no UserDefaults persistence).
final class OnboardingViewModel: ObservableObject {
    @Published var step: Int = 0

    func setInitialStep(_ s: Int) {
        step = s
    }

    func advance(totalSteps: Int) {
        guard step < totalSteps - 1 else { return }
        step += 1
    }

    func goBack() {
        guard step > 0 else { return }
        step -= 1
    }
}
