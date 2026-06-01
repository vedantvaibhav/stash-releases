import Testing
import Foundation
@testable import Stash

/// Unit tests for `TranscriptionService.sanitiseWhisperOutput(_:durationSeconds:)`.
///
/// As of the "trust Whisper" rewrite, this is a SILENCE-ONLY detector — it
/// strips Whisper's special-token markers ([BLANK_AUDIO], [Music], etc.) and
/// returns nil only when nothing real remains. There is no content-based
/// rejection: real speech (even single words, even YouTube-outro-shaped
/// phrases) passes through verbatim. The LLM cleanup pass refines fillers and
/// grammar downstream on the saved note.
///
/// The struct name and filename are kept (vs. renaming to e.g.
/// SilenceDetectionTests) to avoid pbxproj / file-system-synchronized-group
/// churn; the doc above is the source of truth for intent.
@MainActor
struct HallucinationFilterTests {

    private func service() -> TranscriptionService { TranscriptionService() }

    @Test func emptyInputReturnsNil() {
        // Whisper returned nothing → no audio.
        #expect(service().testSanitiseWhisperOutput("") == nil)
    }

    @Test func whitespaceOnlyInputReturnsNil() {
        // Whitespace-only → no audio.
        #expect(service().testSanitiseWhisperOutput("   \n\t  \n ") == nil)
    }

    @Test func bracketMarkerOnlyReturnsNil() {
        // Whisper signalled silence/music/etc. with a bare marker line.
        let svc = service()
        #expect(svc.testSanitiseWhisperOutput("[BLANK_AUDIO]") == nil)
        #expect(svc.testSanitiseWhisperOutput("[blank_audio]") == nil)
        #expect(svc.testSanitiseWhisperOutput("[Music]") == nil)
        #expect(svc.testSanitiseWhisperOutput("[Silence]") == nil)
        #expect(svc.testSanitiseWhisperOutput("(no transcript)") == nil)
        #expect(svc.testSanitiseWhisperOutput("(inaudible)") == nil)
        // Surrounding whitespace on the marker line still counts as a marker.
        #expect(svc.testSanitiseWhisperOutput("   [BLANK_AUDIO]   ") == nil)
    }

    @Test func realSpeechPassesVerbatim_singleWord() {
        let svc = service()
        #expect(svc.testSanitiseWhisperOutput("okay") == "okay")
        #expect(svc.testSanitiseWhisperOutput("alright") == "alright")
        #expect(svc.testSanitiseWhisperOutput("yes") == "yes")
        #expect(svc.testSanitiseWhisperOutput("no") == "no")
    }

    @Test func realSpeechPassesVerbatim_shortPhrase() {
        // We trust Whisper. Cleanup happens downstream — even phrases that
        // look like YouTube outros are accepted now.
        let svc = service()
        #expect(svc.testSanitiseWhisperOutput("let's do it") == "let's do it")
        #expect(svc.testSanitiseWhisperOutput("watch the next slide") == "watch the next slide")
        #expect(svc.testSanitiseWhisperOutput("subscribe to my channel") == "subscribe to my channel")
    }

    @Test func realSpeechPassesVerbatim_withFillers() {
        // Fillers pass through untouched here; the LLM cleanup pass removes
        // them when it runs on the saved note.
        let raw = "um okay so like let's do this"
        #expect(service().testSanitiseWhisperOutput(raw) == raw)
    }

    @Test func mixedBracketsAndRealSpeechKeepsRealSpeech() {
        // Bracket-marker lines are stripped; real lines are kept.
        let svc = service()
        #expect(svc.testSanitiseWhisperOutput("[Music]\nokay let's start") == "okay let's start")
        #expect(svc.testSanitiseWhisperOutput("okay let's start\n[BLANK_AUDIO]") == "okay let's start")
        #expect(svc.testSanitiseWhisperOutput("[Silence]\nhello\n[Music]") == "hello")
    }

    @Test func durationDoesNotAffectFiltering() {
        // The old <8s gate is gone — same input yields the same output at
        // every duration.
        let svc = service()
        let phrase = "subscribe to my channel"
        for duration in [0, 1, 5, 30, 600] {
            #expect(svc.testSanitiseWhisperOutput(phrase, durationSeconds: duration) == phrase)
        }
        // And a silence marker is nil at every duration too.
        for duration in [0, 1, 5, 30, 600] {
            #expect(svc.testSanitiseWhisperOutput("[BLANK_AUDIO]", durationSeconds: duration) == nil)
        }
    }

    @Test func whisperHallucinationOnSilenceStillPasses_byDesign() {
        // "Thanks for watching!" passes through. Accepted trade-off: false
        // rejections of real short speech are worse than the rare
        // hallucination slipping through. The LLM cleanup pass is the second
        // line of defence.
        let raw = "Thanks for watching!"
        #expect(service().testSanitiseWhisperOutput(raw) == raw)
    }
}
