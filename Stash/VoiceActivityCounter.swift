import Foundation

/// Counts seconds of voice activity using a 1-second sliding window of
/// *peak* power, not per-tick average. Replaces the prior accumulator
/// that under-counted real speech because natural micro-pauses between
/// words drop the running average below the threshold momentarily.
///
/// Caller invariant: `observe(power:)` is called at a fixed cadence
/// (100ms in production). The counter assumes 10 observations equals
/// 1 second and emits one second of voice-active credit each time the
/// most-recently-completed window's peak exceeded `peakThresholdDBFS`.
struct VoiceActivityCounter {
    /// Peak power threshold (dBFS). A 1s window with at least one sample
    /// above this is counted as voice-active. Default -32 dBFS gives
    /// headroom for conversational speech (-20 to -25 dBFS at arm's
    /// length) while staying above typical ambient noise floors (-40 to
    /// -45 dBFS in quiet rooms).
    let peakThresholdDBFS: Float

    /// Samples per 1s window. With a 100ms tick this is 10.
    private let samplesPerSecond: Int

    /// Most recent N samples (ring-buffer semantics — wraps once full).
    private var window: [Float] = []

    /// Accumulated voice-active seconds.
    private(set) var voiceActiveSeconds: Double = 0

    init(peakThresholdDBFS: Float = -32, samplesPerSecond: Int = 10) {
        self.peakThresholdDBFS = peakThresholdDBFS
        self.samplesPerSecond = samplesPerSecond
        self.window.reserveCapacity(samplesPerSecond)
    }

    /// Record one power sample (dBFS). When the window completes a full
    /// second (`samplesPerSecond` observations), evaluate it: if the
    /// peak crossed the threshold, credit 1.0s of voice-active time.
    /// Then reset the window for the next second.
    mutating func observe(power: Float) {
        window.append(power)
        guard window.count >= samplesPerSecond else { return }
        let peak = window.max() ?? -.infinity
        if peak > peakThresholdDBFS {
            voiceActiveSeconds += 1
        }
        window.removeAll(keepingCapacity: true)
    }
}
