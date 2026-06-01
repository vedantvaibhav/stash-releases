import Testing
import Foundation
@testable import Stash

@Suite("Spring solver")
struct SpringTests {
    @Test func startsAtFromAndEndsAtTo() {
        let s = Spring(response: 0.3, dampingRatio: 0.8)
        let start = s.value(at: 0, from: 0, to: 100, initialVelocity: 0)
        #expect(abs(start.position - 0) < 0.001)
        let end = s.value(at: 2.0, from: 0, to: 100, initialVelocity: 0)
        #expect(abs(end.position - 100) < 0.5) // settled near target
        #expect(abs(end.velocity) < 1.0)
    }

    @Test func underdampedOvershootsTarget() {
        let s = Spring(response: 0.3, dampingRatio: 0.5) // bouncy
        var maxPos = 0.0
        var t = 0.0
        while t < 1.0 {
            maxPos = max(maxPos, s.value(at: t, from: 0, to: 100, initialVelocity: 0).position)
            t += 0.005
        }
        #expect(maxPos > 100) // overshoot proves bounce
    }

    @Test func criticallyDampedDoesNotOvershoot() {
        let s = Spring(response: 0.3, dampingRatio: 1.0)
        var t = 0.0
        while t < 1.0 {
            #expect(s.value(at: t, from: 0, to: 100, initialVelocity: 0).position <= 100.5)
            t += 0.01
        }
    }

    @Test func settledReportsTrueOnlyNearRest() {
        let s = Spring(response: 0.3, dampingRatio: 0.8)
        #expect(s.isSettled(at: 0, from: 0, to: 100, initialVelocity: 0) == false)
        #expect(s.isSettled(at: 1.5, from: 0, to: 100, initialVelocity: 0) == true)
    }
}
