import AppKit
import AVFoundation
import Foundation

/// Transcription + meeting notes via OpenAI-compatible API (provider auto-detected from key prefix).
@MainActor
final class TranscriptionService: NSObject, ObservableObject {

    private var transcriptionAuthKey: String { APIConstants.transcriptionAuthKey }
    private var inferenceAuthKey: String { APIConstants.groqAPIKey }
    private var whisperURL: String { "\(APIConstants.transcriptionBaseURL)/audio/transcriptions" }
    private var chatURL: String { "\(APIConstants.inferenceBaseURL)/chat/completions" }
    private var whisperModel: String { APIConstants.whisperModel }
    private var chatModel: String { APIConstants.chatModel }

    // — Published state
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var liveTranscript = ""
    @Published var duration = 0
    @Published var errorMessage: String?
    @Published var audioLevel: Float = 0
    /// Set by the pipeline to drive pill status display. Cleared after 1.5 s by the service.
    @Published var completionMessage: String? = nil
    /// Shown inside the RecordingBanner so the user can actually read the failure
    /// message (the pill's "Failed ✗" alone disappears too fast). Auto-clears after 4 s.
    @Published var lastErrorForBanner: String? = nil
    /// Set by `processRecording` before branching so the onNoteCreated callback
    /// (in PanelController) knows whether to auto-open the editor (long) or show
    /// the list with the new quick-transcript pinned at the top (short).
    @Published var lastRecordingWasShort: Bool = false

    /// Set from the notes column so saves use the same storage as the rest of the app.
    weak var notesStorage: NotesStorage?
    var onNoteCreated: ((String) -> Void)?
    var makePanelKey: (() -> Void)?

    // — Private
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var durationTimer: Timer?
    private var transcriptTimer: Timer?
    private var levelTimer: Timer?
    private var maxDurationTimer: Timer?
    private var autoStoppedAtLimit = false

    // MARK: - Start

    func startRecording() {
        errorMessage = nil
        completionMessage = nil
        #if DEBUG
        print("[Transcription] Keys — whisperURL: \(whisperURL), model: \(whisperModel), authKey prefix: \(String(transcriptionAuthKey.prefix(8)))")
        #endif
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.beginRecording()
                } else {
                    self.errorMessage = "Microphone access denied. Enable in System Settings > Privacy > Microphone"
                }
            }
        }
    }

    private func beginRecording() {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qp_recording.m4a")
        recordingURL = tempURL

        try? FileManager.default.removeItem(at: tempURL)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 32_000
        ]

        do {
            recorder = try AVAudioRecorder(url: tempURL, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.record()
            isRecording = true
            isProcessing = false
            duration = 0
            liveTranscript = ""
            errorMessage = nil

            durationTimer?.invalidate()
            durationTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.duration += 1 }
            }
            if let t = durationTimer { RunLoop.main.add(t, forMode: .common) }

            levelTimer?.invalidate()
            levelTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.recorder?.updateMeters()
                    let level = self.recorder?.averagePower(forChannel: 0) ?? -60
                    self.audioLevel = max(0, (level + 60) / 60)
                }
            }
            if let t = levelTimer { RunLoop.main.add(t, forMode: .common) }

            transcriptTimer?.invalidate()
            transcriptTimer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sendLiveChunk() }
            }
            if let t = transcriptTimer { RunLoop.main.add(t, forMode: .common) }

            maxDurationTimer?.invalidate()
            autoStoppedAtLimit = false
            maxDurationTimer = Timer(timeInterval: 5400, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.autoStoppedAtLimit = true
                    self.stopRecording()
                }
            }
            if let t = maxDurationTimer { RunLoop.main.add(t, forMode: .common) }

        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    // MARK: - Live chunk every 10 seconds

    private func sendLiveChunk() {
        guard let url = recordingURL else { return }

        recorder?.pause()
        let audioData: Data
        do {
            audioData = try Data(contentsOf: url)
        } catch {
            recorder?.record()
            return
        }
        recorder?.record()

        guard audioData.count > 1000 else { return }

        Task { @MainActor in
            do {
                let text = try await callWhisper(audioData: audioData)
                self.liveTranscript = text
            } catch {
                // Live chunk failure is non-fatal — next tick retries.
            }
        }
    }

    // MARK: - Stop

    func stopRecording() {
        durationTimer?.invalidate()
        durationTimer = nil
        transcriptTimer?.invalidate()
        transcriptTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        isProcessing = true
        audioLevel = 0

        guard let url = recordingURL,
              let audioData = try? Data(contentsOf: url),
              audioData.count > 1000 else {
            #if DEBUG
            let fileSize = (try? Data(contentsOf: recordingURL ?? URL(fileURLWithPath: ""))).map { "\($0.count) bytes" } ?? "no file"
            print("[Transcription] Audio guard failed — \(fileSize)")
            #endif
            errorMessage = "Recording failed — no audio captured"
            isProcessing = false
            showCompletion("Failed")
            return
        }

        let recordedDuration = duration

        Task { @MainActor in
            defer {
                if let r = self.recordingURL {
                    try? FileManager.default.removeItem(at: r)
                }
            }
            await self.processRecording(audioData: audioData, durationSeconds: recordedDuration)
        }
    }

    // MARK: - LLM prompts

    private static let promptShortClean = """
    You are a transcript cleaner. Your only job is to make the speaker's words clean and paste-ready.

    SELF-CORRECTIONS (highest priority rule):
    When the speaker corrects themselves mid-sentence, keep ONLY the final intended version — delete everything before the correction including the correction signal.
    Examples (follow these exactly):
    - "the meeting is at seven, no five" → "the meeting is at five"
    - "on Monday, I mean Tuesday" → "on Tuesday"
    - "we'll use React, or wait, Vue" → "we'll use Vue"
    - "the deadline is... hmm... Friday" → "the deadline is Friday"
    - "call John, aarah" → "call Sarah"
    - "let's do this Thursday, no wait, next Monday" → "let's do this next Monday"

    Do NOT treat these as self-corrections (keep the meaning, just clean filler):
    - "No, I don't think that works" → "I don't think that works"
    - "That's not right" → "That's not right"

    FILLER WORDS — silently remove all of these:
    um, uh, er, ah, like (when not comparative), you know, so (as opener), basically, literally, right (as filler), kind of, sort of, just (as filler), I mean (when not correcting), honestly, actually (when used as throat-clearing filler)

    OUTPUT RULES:
    - Output ONLY the cleaned text — no headers, no labels, no summary, no explanation
    - Preserve the speaker's vocabulary and tone exactly
    - Keep first-person voice
    - Fix punctuation naturally — periods and commas only
    - Shorter sentences over run-ons
    - Never add information not in the original
    - If something is genuinely unclear after cleaning, keep it rather than guessing
    """

    private static let promptLongTranscript = """
    You are cleaning a meeting transcript for a permanent record.

    SELF-CORRECTIONS — same rule as above, keep ONLY the corrected version:
    - "the call is at seven, no five" → "the call is at five"
    - "by Monday, I mean Wednesday" → "by Wednesday"
    - "we decided on X, actually let's go with Y" → "we decided on Y"

    FILLER WORDS — remove: um, uh, er, ah, like (non-comparative), you know, so (opener), basically, literally, right (filler), kind of, sort of

    RULES:
    - Preserve ALL content — do not summarize, do not cut any topic or idea
    - Keep speaker labels if identifiable (Speaker 1, Speaker 2, or real names if said)
    - Fix grammar lightly — do not rewrite
    - Output ONLY the cleaned transcript, nothing else
    - Periods and commas only — no semicolons, ellipses, or em-dashes
    - Never invent or add content
    """

    private static let promptLongOverview = """
    You are creating a structured overview from a meeting transcript.

    FORMAT — strict:
    - Bullet points only, every bullet starts with "- "
    - One idea per bullet
    - Group related — absolutely no section headers of any kind
    - Short scannable bullets, not paragraphs

    STYLE:
    - Casual, neutral tone — not corporate or formal
    - Periods and commas only — no em-dashes, semicolons, ellipses

    RULES:
    - Every bullet must come directly from the transcript
    - Never invent information or add interpretation
    - Capture everything discussed — do not over-summarize or drop topics
    - If something is unclear, keep it vague rather than guessing
    - Do not start with any label like "Overview:", "Summary:", "Key Points:", etc.
    """

    // MARK: - Unified pipeline

    private func processRecording(audioData: Data, durationSeconds: Int) async {
        let isShort = durationSeconds < 300
        lastRecordingWasShort = isShort

        if autoStoppedAtLimit {
            autoStoppedAtLimit = false
            lastErrorForBanner = "90-minute limit reached — processing what was captured. Start a new session for the rest."
            clearBannerAfterDelay(6.0)
        }

        // MARK: Whisper — with one auto-retry on transient errors
        let rawWhisperOutput: String
        do {
            rawWhisperOutput = try await Task(priority: .userInitiated) {
                try await self.callWhisper(audioData: audioData)
            }.value
        } catch let firstError as NSError {
            if isTransientWhisperError(status: firstError.code) {
                showCompletion("Retrying…")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    rawWhisperOutput = try await Task(priority: .userInitiated) {
                        try await self.callWhisper(audioData: audioData)
                    }.value
                } catch {
                    isProcessing = false
                    showCompletion("Failed")
                    lastErrorForBanner = error.localizedDescription
                    clearBannerAfterDelay()
                    return
                }
            } else {
                isProcessing = false
                showCompletion("Failed")
                lastErrorForBanner = firstError.localizedDescription
                clearBannerAfterDelay()
                return
            }
        } catch {
            isProcessing = false
            showCompletion("Failed")
            lastErrorForBanner = error.localizedDescription
            clearBannerAfterDelay()
            return
        }

        // MARK: Hallucination filter
        guard let rawTranscript = sanitiseWhisperOutput(rawWhisperOutput) else {
            isProcessing = false
            showCompletion("No audio")
            return
        }

        // MARK: LLM cleaning — failure saves raw transcript so nothing is lost
        if isShort {
            do {
                let cleaned = try await callChat(
                    systemPrompt: Self.promptShortClean,
                    userMessage: rawTranscript,
                    maxTokens: 400,
                    model: APIConstants.chatModelForShortClean
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cleaned, forType: .string)
                if let storage = notesStorage {
                    _ = storage.saveQuickNote(text: cleaned, durationSeconds: durationSeconds)
                    storage.refreshNotes()
                }
                isProcessing = false
                showCompletion("Copied")
            } catch {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rawTranscript, forType: .string)
                if let storage = notesStorage {
                    _ = storage.saveQuickNote(text: rawTranscript, durationSeconds: durationSeconds)
                    storage.refreshNotes()
                }
                isProcessing = false
                showCompletion("Copied (raw)")
                lastErrorForBanner = "Couldn't clean transcript — raw version copied and saved"
                clearBannerAfterDelay()
            }
        } else {
            do {
                async let transcriptCall = callChat(
                    systemPrompt: Self.promptLongTranscript,
                    userMessage: rawTranscript,
                    maxTokens: 3000,
                    model: APIConstants.chatModel
                )
                async let overviewCall = callChat(
                    systemPrompt: Self.promptLongOverview,
                    userMessage: rawTranscript,
                    maxTokens: 1500,
                    model: APIConstants.chatModel
                )
                let (cleanedTranscript, overview) = try await (transcriptCall, overviewCall)
                if let storage = notesStorage {
                    let id = storage.saveMeetingNote(
                        transcript: cleanedTranscript,
                        overview: overview,
                        durationSeconds: durationSeconds
                    )
                    storage.refreshNotes()
                    onNoteCreated?(id)
                }
                isProcessing = false
                showCompletion("Note saved")
            } catch {
                if let storage = notesStorage {
                    let id = storage.saveMeetingNote(
                        transcript: rawTranscript,
                        overview: "Overview unavailable — raw transcript saved below.",
                        durationSeconds: durationSeconds
                    )
                    storage.refreshNotes()
                    onNoteCreated?(id)
                }
                isProcessing = false
                showCompletion("Saved (raw)")
                lastErrorForBanner = "Couldn't clean transcript — raw version saved"
                clearBannerAfterDelay()
            }
        }
    }

    private func showCompletion(_ message: String) {
        completionMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.completionMessage = nil
        }
    }

    func openMicrophonePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Error helpers

    private func friendlyError(domain: String, status: Int, body: String) -> String {
        switch status {
        case 401:
            return "\(domain) API key not configured or invalid"
        case 429:
            return "\(domain) rate limit hit — try again in a moment"
        case 413:
            return "Recording too large to process"
        case 400:
            if body.lowercased().contains("context") || body.lowercased().contains("token") {
                return "Recording too long to clean in one pass"
            }
            return "\(domain) rejected the request"
        case 500, 502, 503:
            return "\(domain) service temporarily unavailable"
        default:
            if status < 0 { return "No internet connection" }
            return "\(domain) error (\(status))"
        }
    }

    private func isTransientWhisperError(status: Int) -> Bool {
        status == 429 || (500...503).contains(status)
    }

    private func clearBannerAfterDelay(_ delay: Double = 4.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.lastErrorForBanner = nil
        }
    }

    // MARK: - Whisper API

    private func sanitiseWhisperOutput(_ raw: String) -> String? {
        // PASS 1 — token hallucinations (bracket artefacts Whisper emits on silence)
        let tokenHallucinations = [
            "[BLANK_AUDIO]", "[blank_audio]", "[inaudible]", "[Inaudible]",
            "[music]", "[Music]", "[silence]", "[Silence]", "[noise]", "[Noise]",
            "[laughter]", "[Laughter]", "[applause]", "[Applause]",
            "(No transcript)", "(no transcript)", "(silence)", "(inaudible)"
        ]
        var text = raw
        for token in tokenHallucinations {
            text = text.replacingOccurrences(of: token, with: "")
        }

        // PASS 2 — semantic hallucinations Whisper generates on near-silent audio.
        // Match case-insensitively line-by-line so a single hallucination phrase
        // embedded in real speech is not over-stripped.
        let semanticHallucinations: [String] = [
            "thank you for watching",
            "thanks for watching",
            "please subscribe",
            "don't forget to subscribe",
            "like and subscribe",
            "hit the like button",
            "see you in the next video",
            "see you next time",
            "until next time",
            "thanks for listening",
            "thank you for listening",
            "thanks for tuning in",
            "thank you for tuning in",
            "that's all for today",
            "that's it for today",
            "that's it for this episode",
            "we'll see you next week",
            "you",
            "bye",
            "bye bye",
            "okay",
            "alright",
            "um",
            "uh",
            "hmm",
            "hm",
            "mm-hmm",
            "mm hmm",
            "...",
            "…"
        ]
        let lines = text.components(separatedBy: .newlines).filter { line in
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-.,!? "))
            guard !stripped.isEmpty else { return false }
            let normalised = stripped.lowercased()
            if semanticHallucinations.contains(where: { normalised == $0 }) { return false }
            let nonNoise = stripped.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
            return !nonNoise.isEmpty
        }
        let cleaned = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // PASS 3 — full-output semantic match (handles multi-word phrases that
        // survived line filtering because they were the only line).
        let fullNormalised = cleaned.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!? "))
        if semanticHallucinations.contains(where: { fullNormalised == $0 }) {
            return nil
        }

        // PASS 3b — URL / attribution detection.
        // Real speech almost never produces a URL. If Whisper outputs www., http,
        // or a bare domain suffix (.org, .com, .net, .io, .gov), it's a hallucination
        // from ambient audio (UN videos, podcast ads, YouTube end-cards, etc.).
        let urlPatterns = ["www.", "http://", "https://", ".com", ".org", ".net", ".io", ".gov", ".edu"]
        if urlPatterns.contains(where: { cleaned.lowercased().contains($0) }) {
            #if DEBUG
            print("[Transcription] sanitise: rejected (URL pattern) — \"\(cleaned)\"")
            #endif
            return nil
        }

        // PASS 3c — media attribution phrases not caught by exact-match above.
        let attributionPatterns = [
            "for more", "visit us at", "find us at", "follow us on",
            "subscribe to our", "check out our", "more videos", "our website",
            "our channel", "our podcast", "this video was", "this episode was",
            "produced by", "sponsored by", "brought to you by"
        ]
        if attributionPatterns.contains(where: { fullNormalised.contains($0) }) {
            #if DEBUG
            print("[Transcription] sanitise: rejected (attribution pattern) — \"\(cleaned)\"")
            #endif
            return nil
        }

        // PASS 4 — word-count gate. Fewer than 5 non-trivial words → almost
        // certainly hallucination or mic-bumped silence.
        let words = cleaned.components(separatedBy: .whitespaces).filter { word in
            let w = word.trimmingCharacters(in: .punctuationCharacters)
            return w.count >= 2
        }
        guard words.count >= 5 else {
            #if DEBUG
            print("[Transcription] sanitise: rejected (\(words.count) substantive words) — \"\(cleaned)\"")
            #endif
            return nil
        }

        #if DEBUG
        print("[Transcription] sanitise: accepted \(words.count) words")
        #endif
        return cleaned
    }

    private func callWhisper(audioData: Data) async throws -> String {
        let url = URL(string: whisperURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("Bearer \(transcriptionAuthKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(whisperModel)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("en\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n".data(using: .utf8)!)
        body.append("0\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
        body.append("Meeting notes, action items, decisions, follow-ups. Names, dates, and technical terms should be transcribed accurately.\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseText = String(data: data, encoding: .utf8) ?? "unreadable"

        guard status == 200 else {
            throw NSError(domain: "Whisper", code: status,
                          userInfo: [NSLocalizedDescriptionKey: friendlyError(domain: "Whisper", status: status, body: responseText)])
        }
        return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Generic chat call

    private func callChat(systemPrompt: String?, userMessage: String, maxTokens: Int, model: String? = nil) async throws -> String {
        let url = URL(string: chatURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(inferenceAuthKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: String]] = []
        if let sys = systemPrompt { messages.append(["role": "system", "content": sys]) }
        messages.append(["role": "user", "content": userMessage])

        let body: [String: Any] = [
            "model": model ?? chatModel,
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "messages": messages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseText = String(data: data, encoding: .utf8) ?? "unreadable"

        guard status == 200 else {
            throw NSError(domain: "LLM", code: status,
                          userInfo: [NSLocalizedDescriptionKey: friendlyError(domain: "LLM", status: status, body: responseText)])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "LLM", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid JSON shape"])
        }
        return content
    }
}
