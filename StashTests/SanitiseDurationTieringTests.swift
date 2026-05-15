import Testing
@testable import Stash

/// Unit tests for duration-tiered Whisper-output filtering.
///
/// The headline regression — the 2026-05-15 11:50 AM event where a 93s real
/// conversation was thrown away — is asserted first. If `regression_chatWithSai`
/// fails, the over-correction fix is not done. The remaining cases pin the
/// tier boundaries (short/moderate/conservative) so future threshold tuning
/// can't silently un-fix this without a red test.
@MainActor
struct SanitiseDurationTieringTests {

    private func service() -> TranscriptionService { TranscriptionService() }

    // MARK: - Headline regression

    /// 2026-05-15 11:50 AM Slack event: a 93s real conversation rejected by the
    /// confidence gate (NSP 0.68 OR-gated against the 0.6 threshold). Conservative
    /// tier (>30s) requires BOTH NSP > 0.85 AND ALP < -0.8 — this signal hits
    /// neither, so it must be accepted.
    @Test func regression_chatWithSai() {
        let svc = service()
        // Exact text from the 2026-05-15 11:50 AM Slack snippet. The trailing
        // word is truncated mid-character ("actio") as it appeared in Slack —
        // not a typo; the brief calls for the exact text.
        let raw = "I had a chat with Sai on the same so he told me that it is your idea that only the orchestrator would take all the actio"
        // Headline assertion #1: sanitise must accept the clean text at 93s.
        #expect(svc.testSanitiseWhisperOutput(raw, durationSeconds: 93) != nil)
        // Headline assertion #2: confidence-gate must NOT reject these signals
        // for a 93s recording. (NSP 0.68, ALP -0.33 — old OR-gate at 0.6/-1.0
        // rejected; new conservative gate at 0.85/-0.8 AND condition accepts.)
        #expect(svc.testConfidenceGateRejects(meanNSP: 0.68, meanALP: -0.33, durationSeconds: 93) == false)
        // Headline assertion #3: the conservative-tier sanitise advisory path
        // must hold even when the real transcript contains an attribution
        // substring. Without the tier-aware advisory mode, "in the description"
        // (a PASS 3c attributionPatterns entry) would reject the whole 93s
        // transcript. The fix only matters if real long transcripts that
        // happen to contain such phrases still pass — assert that here so a
        // future "tighten the substring filter" change cannot silently
        // re-break the regression.
        let rawWithSubstring = raw + " — please put it in the description of the doc and we'll review Friday."
        #expect(svc.testSanitiseWhisperOutput(rawWithSubstring, durationSeconds: 93) != nil)
        // Sanity check: the same text at 5s (short tier) is still rejected.
        // Pins that the advisory mode applies ONLY to conservative tier.
        #expect(svc.testSanitiseWhisperOutput("link in the description", durationSeconds: 5) == nil)
    }

    // MARK: - Confidence-gate tier transitions

    @Test func confidenceGate_shortBucket_rejectsAtOldThresholds() {
        let svc = service()
        // <8s: aggressive — original OR-gate at 0.6 / -1.0 still applies.
        #expect(svc.testConfidenceGateRejects(meanNSP: 0.65, meanALP: -0.5, durationSeconds: 5) == true)
        #expect(svc.testConfidenceGateRejects(meanNSP: 0.4, meanALP: -1.2, durationSeconds: 5) == true)
    }

    @Test func confidenceGate_moderateBucket_relaxedNSP() {
        let svc = service()
        // 8–30s: NSP threshold bumped to 0.80; logprob threshold unchanged.
        // 0.70 was rejected in short bucket; here it must pass.
        #expect(svc.testConfidenceGateRejects(meanNSP: 0.70, meanALP: -0.5, durationSeconds: 15) == false)
        // 0.85 still trips the relaxed NSP threshold (NSP > 0.80).
        #expect(svc.testConfidenceGateRejects(meanNSP: 0.85, meanALP: -0.5, durationSeconds: 15) == true)
        // Bad logprob alone still trips.
        #expect(svc.testConfidenceGateRejects(meanNSP: 0.5, meanALP: -1.3, durationSeconds: 15) == true)
    }

    @Test func confidenceGate_conservativeBucket_andConditioned() {
        let svc = service()
        // >30s: reject ONLY if BOTH NSP > 0.85 AND ALP < -0.8.
        // Either alone is insufficient — the 11:50 AM regression is the canonical case.
        #expect(svc.testConfidenceGateRejects(meanNSP: 0.95, meanALP: -0.5, durationSeconds: 90) == false)  // NSP only
        #expect(svc.testConfidenceGateRejects(meanNSP: 0.5,  meanALP: -1.5, durationSeconds: 90) == false)  // ALP only
        #expect(svc.testConfidenceGateRejects(meanNSP: 0.90, meanALP: -1.0, durationSeconds: 90) == true)   // both
    }

    // MARK: - Substring / outro-vocab tier behaviour

    @Test func conservativeBucket_substringPatternsAreAdvisoryOnly() {
        let svc = service()
        // Long recording containing an attribution substring ("link in the
        // description") must NOT be rejected in conservative tier — it's
        // advisory only. The user's actual speech surrounding it is the
        // signal that matters.
        let raw = """
        I want to follow up on yesterday's discussion. We agreed Sai would
        own the orchestrator workflow and Alok will draft the architecture
        diagram. Please put the link in the description of the doc when it's
        ready and we'll review it on Friday before pushing to staging.
        """
        #expect(svc.testSanitiseWhisperOutput(raw, durationSeconds: 60) != nil)
    }

    @Test func shortBucket_substringPatternsStillReject() {
        let svc = service()
        // Same substring in a <8s recording still rejects — aggressive tier.
        #expect(svc.testSanitiseWhisperOutput("Link in the description below.", durationSeconds: 5) == nil)
    }

    @Test func moderateBucket_substringPatternsStillReject() {
        let svc = service()
        // Moderate bucket still applies substring filters — they're only
        // demoted to advisory in the conservative tier.
        #expect(svc.testSanitiseWhisperOutput("Please subscribe to our channel and watch the next video.", durationSeconds: 20) == nil)
    }

    // MARK: - Empty-output gate is universal across tiers

    @Test func emptyOutputStillRejectsEverywhere() {
        let svc = service()
        for dur in [3, 15, 60, 120] {
            #expect(svc.testSanitiseWhisperOutput("", durationSeconds: dur) == nil)
            #expect(svc.testSanitiseWhisperOutput("   \n\n  ", durationSeconds: dur) == nil)
        }
    }
}
