import Testing
@testable import Stash

/// Tests the 1-second sliding window voice-active counter.
///
/// The old per-tick approach (`if averagePower > -30 { active += 0.1 }`)
/// under-counted real speech because natural micro-pauses between words
/// drop the running average below -30 momentarily. The windowed version
/// uses *peak* power inside each 1s window — so a single syllable peak
/// at -22 dBFS marks the whole second as voice-active, matching how
/// humans hear speech.
struct VoiceActivityCounterTests {

    /// Helper: produce N ticks of constant power, 100ms each.
    private func ticks(power: Float, count: Int) -> [Float] {
        Array(repeating: power, count: count)
    }

    /// Helper: feed samples and return total voice-active seconds.
    private func run(_ samples: [Float], threshold: Float = -32) -> Double {
        var counter = VoiceActivityCounter(peakThresholdDBFS: threshold)
        for s in samples { counter.observe(power: s) }
        return counter.voiceActiveSeconds
    }

    @Test func silentRoomIsZero() {
        let samples = ticks(power: -50, count: 100) // 10s of -50 dBFS
        #expect(run(samples) == 0)
    }

    @Test func steadyConversationalSpeechCountsAllSeconds() {
        // 10s of -25 dBFS (conversational from arm's length) — well above the
        // -32 dBFS peak threshold. Old code would have caught this too; this
        // pins the obvious case.
        let samples = ticks(power: -25, count: 100)
        let active = run(samples)
        #expect(active >= 9.0 && active <= 10.0)
    }

    /// The headline regression for the windowed counter. Mixes 50ms peaks at
    /// -22 dBFS with 50ms valleys at -45 dBFS — natural speech rhythm. Old
    /// per-tick average code would only count peaks → ~50% miscount. Windowed
    /// peak should mark every second voice-active.
    @Test func windowedCounterMatchesRealSpeech() {
        // 10s @ 100ms/tick = 100 ticks. Alternate peak/valley.
        var samples: [Float] = []
        for i in 0..<100 {
            samples.append(i % 2 == 0 ? -22 : -45)
        }
        let active = run(samples)
        // Each 1s window contains peaks → every second is voice-active.
        #expect(active >= 9.0 && active <= 10.0)
    }

    @Test func sparsePeaksStillCount() {
        // Real speech can have 700ms gaps between phrases. One peak per
        // second still marks the whole second as voice-active.
        var samples = ticks(power: -50, count: 100)
        for second in 0..<10 {
            samples[second * 10 + 3] = -20 // single peak inside each second
        }
        let active = run(samples)
        #expect(active >= 9.0 && active <= 10.0)
    }

    @Test func windowDoesNotLeakAcrossSeconds() {
        // First 5s loud, last 5s silent. Counter must report ~5s active —
        // NOT 10s. (Naive implementations that update on every tick can
        // double-count if the window doesn't actually slide out.)
        var samples = ticks(power: -22, count: 50)
        samples.append(contentsOf: ticks(power: -50, count: 50))
        let active = run(samples)
        #expect(active >= 4.0 && active <= 6.0)
    }
}
