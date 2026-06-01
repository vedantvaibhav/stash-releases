import AppKit
import QuartzCore

/// Drives `NSPanel.setFrame` along a `Spring` via a ~120 Hz timer. Interruptible
/// and retargetable: calling `animate(to:)` mid-flight reseeds from the current
/// position AND the live per-axis velocity, so a recording→processing→completion
/// burst morphs smoothly instead of restarting from zero (emil: springs keep
/// momentum when interrupted). Reduce-motion → instant frame set, no spring.
///
/// A timer (not CVDisplayLink) on purpose: CVDisplayLink is deprecated on
/// macOS 15+, and a 120 Hz common-mode timer is smooth enough for a small
/// capsule morph while keeping the deployment target clean.
@MainActor
final class PillMorphAnimator {
    private weak var panel: NSPanel?
    private var timer: Timer?
    private let spring: Spring

    private var startTime: CFTimeInterval = 0
    private var fromFrame: NSRect = .zero
    private var toFrame: NSRect = .zero
    // Initial per-axis velocity carried across retargets.
    private var velFrame: (w: Double, h: Double, x: Double, y: Double) = (0, 0, 0, 0)
    // Last per-axis velocity computed in tick() — read on retarget.
    private var liveVel: (w: Double, h: Double, x: Double, y: Double) = (0, 0, 0, 0)
    private var inFlight = false
    private var onSettle: (() -> Void)?

    init(panel: NSPanel) {
        self.panel = panel
        self.spring = Spring(response: DesignTokens.Motion.morphResponse,
                             dampingRatio: DesignTokens.Motion.morphDampingRatio)
    }

    /// Morph the panel to `target`. `onSettle` fires when motion completes.
    func animate(to target: NSRect, onSettle: (() -> Void)? = nil) {
        guard let panel else { return }
        if DesignTokens.Motion.reduceMotion {
            stop()
            panel.setFrame(target, display: true)
            onSettle?()
            return
        }
        // Reseed from the live frame; carry the live velocity if we were already
        // mid-morph so the spring retargets without losing momentum.
        fromFrame = panel.frame
        toFrame = target
        velFrame = inFlight ? liveVel : (0, 0, 0, 0)
        startTime = CACurrentMediaTime()
        inFlight = true
        self.onSettle = onSettle
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            // Scheduled on RunLoop.main, so it always fires on the main thread —
            // assume the isolation rather than allocating a Task per tick (~120/s).
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let panel, inFlight else { stop(); return }
        let t = CACurrentMediaTime() - startTime

        func axis(_ from: Double, _ to: Double, _ v0: Double) -> (Double, Double) {
            let r = spring.value(at: t, from: from, to: to, initialVelocity: v0)
            return (r.position, r.velocity)
        }
        let (w, vw) = axis(Double(fromFrame.width), Double(toFrame.width), velFrame.w)
        let (h, vh) = axis(Double(fromFrame.height), Double(toFrame.height), velFrame.h)
        let (x, vx) = axis(Double(fromFrame.minX), Double(toFrame.minX), velFrame.x)
        let (y, vy) = axis(Double(fromFrame.minY), Double(toFrame.minY), velFrame.y)
        liveVel = (vw, vh, vx, vy)

        panel.setFrame(NSRect(x: x, y: y, width: max(1, w), height: max(1, h)), display: true)

        let settled = spring.isSettled(at: t, from: Double(fromFrame.width), to: Double(toFrame.width), initialVelocity: velFrame.w)
        if settled || t > DesignTokens.Motion.morphSettleCap {
            panel.setFrame(toFrame, display: true)
            inFlight = false
            stop()
            onSettle?()
            onSettle = nil
        }
    }

    /// Stop the driver. Clears `inFlight` so the NEXT `animate(to:)` starts from
    /// rest (zero velocity) rather than carrying a stale velocity from a halted
    /// morph — entrance/exit call `stop()` first so they begin clean. A genuine
    /// mid-flight retarget (applyPanelFrame's morph path) does NOT call stop(),
    /// so it still preserves momentum.
    func stop() {
        timer?.invalidate()
        timer = nil
        inFlight = false
    }

    deinit { timer?.invalidate() }
}
