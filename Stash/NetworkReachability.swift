import Foundation
import Network

/// Wraps `NWPathMonitor` to expose a simple `isOnline` flag plus a
/// transition callback (`onSatisfied`) that fires when the network becomes
/// satisfied AFTER being unsatisfied. The transcription retry queue uses
/// the transition signal to drain `pending/` sessions opportunistically.
///
/// Lifecycle: caller invokes `start()` once at app launch. The monitor
/// runs continuously; battery cost is negligible for menu-bar apps that
/// are already alive in the background. If field metrics ever show
/// measurable battery drain, switch to "start on first pending, stop on
/// empty" — but only after measuring, not preemptively (YAGNI).
///
/// Concurrency: the underlying `NWPathMonitor` calls back on its own
/// dispatch queue. We hop to `@MainActor` to update `isOnline` (a
/// `@Published` consumed by SwiftUI). The `onSatisfied` callback also
/// runs on `@MainActor`.
// TODO(@Observable): flip when min target bumps to macOS 14
@MainActor
final class NetworkReachability: ObservableObject {
    static let shared = NetworkReachability()

    @Published private(set) var isOnline: Bool = true   // optimistic default

    /// Fires when the path transitions from unsatisfied → satisfied.
    /// Does NOT fire on the initial satisfied state (we assume online
    /// at launch; the retry queue checks `pending/` separately).
    var onSatisfied: (() -> Void)?

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var hasStarted = false
    private var wasOnline: Bool = true

    private init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "app.stash.NetworkReachability", qos: .utility)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let nowOnline = (path.status == .satisfied)
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = nowOnline
                // Transition: unsatisfied → satisfied fires onSatisfied.
                if nowOnline, !self.wasOnline {
                    self.onSatisfied?()
                }
                self.wasOnline = nowOnline
            }
        }
        monitor.start(queue: queue)
    }

    #if DEBUG
    /// Test seam: lets tests drive transitions without hitting the network.
    /// Mirrors the inline logic in `pathUpdateHandler` above so test
    /// expectations match production behaviour exactly. DEBUG-only — release
    /// builds rely solely on the inline path-handler branch.
    func updateState(nowOnline: Bool) {
        isOnline = nowOnline
        if nowOnline, !wasOnline {
            onSatisfied?()
        }
        wasOnline = nowOnline
    }
    #endif
}
