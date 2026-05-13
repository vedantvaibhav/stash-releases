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
}
