import Testing
import Foundation
@testable import Stash

/// Transition behaviour for `NetworkReachability`. Tests drive
/// `updateState(nowOnline:)` directly (the internal test seam) instead of
/// waiting for real `NWPathMonitor` callbacks. The shared singleton is
/// used because `onSatisfied` and `isOnline` are only meaningful on a
/// MainActor-isolated instance — tests reset the callback in a defer so
/// they don't bleed across runs.
@Suite("NetworkReachability")
@MainActor
struct NetworkReachabilityTests {

    @Test func onSatisfiedFiresOnUnsatisfiedToSatisfiedTransition() async {
        let r = NetworkReachability.shared
        let prior = r.onSatisfied
        defer { r.onSatisfied = prior }

        var fired = 0
        r.onSatisfied = { fired += 1 }

        r.updateState(nowOnline: false)   // go offline first
        r.updateState(nowOnline: true)    // back online → fires

        #expect(fired == 1)
    }

    @Test func onSatisfiedDoesNotFireOnSatisfiedToSatisfied() async {
        let r = NetworkReachability.shared
        let prior = r.onSatisfied
        defer { r.onSatisfied = prior }

        var fired = 0
        r.onSatisfied = { fired += 1 }

        r.updateState(nowOnline: true)    // already online (default), idempotent
        r.updateState(nowOnline: true)

        #expect(fired == 0, "satisfied → satisfied is a no-op for the callback")
    }
}
