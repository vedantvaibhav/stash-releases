import Foundation

/// Analytic spring solver (no AppKit). Parameterised the Apple way —
/// `response` (the natural period) and `dampingRatio` (1.0 = critically
/// damped, < 1.0 = bouncy). `value(at:)` returns position + velocity so a
/// driver can retarget mid-flight while preserving momentum (emil:
/// "springs maintain velocity when interrupted").
struct Spring {
    let response: Double
    let dampingRatio: Double

    /// Undamped natural frequency ω₀ = 2π / response.
    private var omega0: Double { (2 * Double.pi) / max(response, 0.0001) }

    /// Position + velocity of a spring released from `from` toward `to` with
    /// `initialVelocity`, evaluated `t` seconds after release.
    func value(at t: Double, from: Double, to: Double, initialVelocity v0: Double) -> (position: Double, velocity: Double) {
        let zeta = dampingRatio
        let w0 = omega0
        let x0 = from - to // displacement from target

        if zeta < 1 { // under-damped (can overshoot)
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            let a = x0
            let b = (v0 + zeta * w0 * x0) / wd
            let envelope = exp(-zeta * w0 * t)
            let pos = envelope * (a * cos(wd * t) + b * sin(wd * t))
            let vel = envelope * ((b * wd - zeta * w0 * a) * cos(wd * t)
                - (a * wd + zeta * w0 * b) * sin(wd * t))
            return (pos + to, vel)
        } else { // critically damped (zeta == 1)
            let a = x0
            let b = v0 + w0 * x0
            let envelope = exp(-w0 * t)
            let pos = envelope * (a + b * t)
            let vel = envelope * (b - w0 * (a + b * t))
            return (pos + to, vel)
        }
    }

    /// True once the spring is within 0.5pt of the target and nearly still.
    func isSettled(at t: Double, from: Double, to: Double, initialVelocity v0: Double) -> Bool {
        let r = value(at: t, from: from, to: to, initialVelocity: v0)
        return abs(r.position - to) < 0.5 && abs(r.velocity) < 1.0
    }
}
