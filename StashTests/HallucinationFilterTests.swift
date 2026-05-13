import Testing
@testable import Stash

/// Unit tests for `TranscriptionService.sanitiseWhisperOutput(_:)`.
///
/// **Wiring status:** The `StashTests/` directory already contains an
/// orphan test file (`NotesEditorView+SelectionToolbarTests.swift`); both
/// will run only once a unit-test target is added to `Stash.xcodeproj`.
/// Until then, this file documents the expected behaviour and is ready
/// to execute.
@MainActor
struct HallucinationFilterTests {

    private func service() -> TranscriptionService { TranscriptionService() }

    @Test func rejectsYouTubeOutroFamily() {
        let svc = service()
        let inputs = [
            "If you have any questions or comments, please post them in the comments.",
            "Please post them in the comments.",
            "Leave a comment below.",
            "See you in the next one.",
            "Thanks so much for watching!",
            "Catch you in the next one."
        ]
        for input in inputs {
            #expect(svc.testSanitiseWhisperOutput(input) == nil, "expected hallucination rejection for: \(input)")
        }
    }

    @Test func rejectsMultilingualOutros() {
        let svc = service()
        let inputs = [
            "Merci",
            "ご視聴ありがとうございました",
            "Спасибо за просмотр",
            "다음 영상에서 만나요",
            "Gracias por ver"
        ]
        for input in inputs {
            #expect(svc.testSanitiseWhisperOutput(input) == nil, "expected hallucination rejection for: \(input)")
        }
    }

    @Test func rejectsMultilingualOutrosWithNativePunctuation() {
        let svc = service()
        let inputs = [
            "ご視聴ありがとうございました。",
            "ご視聴ありがとうございました!",
            "Спасибо за просмотр.",
            "다음 영상에서 만나요!",
            "Merci d'avoir regardé.",
            "Gracias por ver."
        ]
        for input in inputs {
            #expect(svc.testSanitiseWhisperOutput(input) == nil, "expected rejection for native-punctuated: \(input)")
        }
    }

    @Test func acceptsLegitimateSpeech() {
        let svc = service()
        let inputs = [
            "Schedule the meeting for Tuesday at 3pm.",
            "Action item: send the contract to legal.",
            "The vendor confirmed delivery by Friday."
        ]
        for input in inputs {
            #expect(svc.testSanitiseWhisperOutput(input) != nil, "expected acceptance for: \(input)")
        }
    }

    @Test func rejectsBracketAndMusicalNoise() {
        let svc = service()
        let inputs = [
            "[Music]",
            "[BLANK_AUDIO]",
            "♪",
            "(music)",
            "(no audio)"
        ]
        for input in inputs {
            #expect(svc.testSanitiseWhisperOutput(input) == nil, "expected rejection for: \(input)")
        }
    }

    @Test func rejectsDescriptionLinksAndWatchNextFamilies() {
        let svc = service()
        let inputs = [
            "Be sure to check the description for links in the previous video description for more information.",
            "Be sure to check the description for links",
            "Link in the description below.",
            "As I mentioned in the previous video, here's what we covered.",
            "Watch the next episode for more.",
            "All the links are below in the description.",
            "Click the link in my bio."
        ]
        for input in inputs {
            #expect(svc.testSanitiseWhisperOutput(input) == nil, "expected rejection for description/watch-next: \(input)")
        }
    }

    @Test func rejectsShortRecordingWithMultipleOutroVocabHits() {
        let svc = service()
        // Short clip (10s) with ≥2 outro-vocab tokens — the real Whisper-
        // hallucinated-outro fingerprint. Pass 5 catches these.
        //
        // Inputs deliberately avoid phrases that would trigger Pass 3c
        // attributionPatterns (e.g., "previous video", "in the description",
        // "more videos") — those would short-circuit before Pass 5 fires
        // and the test would pass for the wrong reason.
        let inputs = [
            "Subscribe to the channel.",        // subscribe + channel = 2; no attribution substring
            "Subscribe and watch the channel.", // subscribe + watch + channel = 3
            "Watch the tutorial episode.",      // watch + tutorial + episode = 3
            "Comment on the stream."            // comment + stream = 2
        ]
        for input in inputs {
            #expect(svc.testSanitiseWhisperOutput(input, durationSeconds: 10) == nil,
                    "expected Pass-5 rejection for: \(input)")
        }
    }

    @Test func acceptsShortLegitimateDictationWithOneOutroToken() {
        let svc = service()
        // Single-vocab-hit short clips — the headline false-positive risk
        // the ≥2-hit rule was designed to prevent. Each input has exactly
        // ONE outro-vocab token in a legitimate context and MUST pass.
        // These inputs are also crafted to NOT trigger any other pass
        // (no attributionPatterns substring, no semanticHallucinations
        // whole-line equality).
        let inputs = [
            "Send the link to John.",       // link (1) only
            "Save the link for later.",     // link (1) only
            "Bob sent me the link.",        // link (1) only
            "I will watch tomorrow.",       // watch (1) only
            "The video is ready."           // video (1) only
        ]
        for input in inputs {
            #expect(svc.testSanitiseWhisperOutput(input, durationSeconds: 5) != nil,
                    "≥2-hit rule should not reject single-vocab-hit: \(input)")
        }
    }

    @Test func acceptsLongerRecordingEvenWithOutroVocab() {
        let svc = service()
        // Same outro-vocab tokens, but in recordings >= 20s — Pass 5 does not apply.
        // (The longer recording is more likely to be legitimate; if it's still
        // hallucinated, the line-match / full-output / attribution passes catch it.)
        let longLegit = "I want to follow up on what we discussed last week regarding the marketing channel and the campaign performance numbers, particularly around the description copy on the landing page and the link tracking."
        #expect(svc.testSanitiseWhisperOutput(longLegit, durationSeconds: 60) != nil,
                "expected acceptance for legitimate long content with outro vocab")
    }
}
