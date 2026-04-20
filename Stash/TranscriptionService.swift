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

    // MARK: - Start

    func startRecording() {
        errorMessage = nil
        completionMessage = nil
        print("[Transcription] Keys — whisperURL: \(whisperURL), model: \(whisperModel), authKey prefix: \(String(transcriptionAuthKey.prefix(8)))")
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
            AVEncoderBitRateKey: 96_000
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
        recorder?.stop()
        recorder = nil
        isRecording = false
        isProcessing = true
        audioLevel = 0

        guard let url = recordingURL,
              let audioData = try? Data(contentsOf: url),
              audioData.count > 1000 else {
            let fileSize = (try? Data(contentsOf: recordingURL ?? URL(fileURLWithPath: ""))).map { "\($0.count) bytes" } ?? "no file"
            print("[Transcription] Audio guard failed — \(fileSize)")
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

    private static let promptModeA = """
    You are cleaning a short voice note (under 3 minutes).

    Your job:
    - Clean up grammar and remove filler words (um, uh, like, you know)
    - Keep the tone CASUAL and conversational — the way a person actually talks
    - Use simple punctuation: periods and commas only
    - DO NOT use semicolons (;)
    - DO NOT use ellipses (...)
    - DO NOT use em-dashes (—) unless absolutely necessary
    - Short sentences are better than long ones
    - Keep original phrasing as much as possible — paste-ready

    Output format (exactly):

    [cleaned transcript in casual natural tone]

    ---

    [2-3 short casual sentences summarizing what was said]

    Rules:
    - No headers, no bullets (unless content is clearly a list)
    - No metadata, no timestamps
    - Never invent information
    - If unclear, keep it vague rather than guessing
    - Preserve original intent strictly
    - Do not over-summarize
    """

    private static let promptModeB = """
    You are processing a medium-length voice note (3–5 minutes).

    Your job:
    - Clean up and lightly structure the content
    - Convert to bullet points ONLY if:
      - the content clearly contains lists, steps, or multiple ideas
      - there are 3+ distinct ideas or named entities being introduced

    Output: a single clean Overview of the content.

    Style:
    - Conversational tone
    - Slightly structured for readability
    - Not overly formal

    Rules:
    - No metadata
    - No sections like "Transcript", "Duration", "Summary", etc.
    - No rigid headers
    - Avoid over-formatting
    - Keep it intuitive and easy to scan
    - Never invent information
    - Never add interpretations not present in the input
    - If something is unclear, keep it vague rather than guessing
    - Preserve original intent strictly
    - Do not over-summarize. Retain density of information.
    """

    private static let promptModeC_transcript = """
    You are cleaning a long meeting transcript.

    Your job:
    - Fix grammar
    - Remove filler words (um, uh, like, you know)
    - Keep speaker labels if identifiable in the raw transcript (Speaker 1, Speaker 2, or actual names if mentioned). Otherwise leave the text flowing.
    - Preserve ALL content — do not summarize, do not cut

    Punctuation: use only periods and commas. No semicolons. No ellipses. No em-dashes.

    Rules:
    - Output only the cleaned transcript, nothing else
    - Never invent content
    - Preserve original intent strictly
    """

    private static let promptModeC_overview = """
    You are taking notes from a long recording (over 5 minutes).

    Your job: produce a bullet-point Overview covering all points discussed.

    Format:
    - Every point as a bullet (start with "- ")
    - One idea per bullet
    - Short, scannable bullets — not paragraphs
    - Group related bullets together naturally but NO section headers
    - No "Summary", "Decisions", "Action Items", "Key Points" headers anywhere

    Style:
    - Neutral tone
    - Casual language, not corporate
    - Simple punctuation — periods and commas only
    - No semicolons, no ellipses, no em-dashes
    - Short sentences

    Rules:
    - Every bullet must come from the transcript
    - Never invent information or add interpretation
    - If something is unclear, keep it vague rather than guessing
    - Capture everything important — do not over-summarize
    - Preserve the original density of information
    """

    // MARK: - Unified pipeline

    private func processRecording(audioData: Data, durationSeconds: Int) async {
        // Mode A: < 180s. Modes B and C open panel — not short.
        lastRecordingWasShort = durationSeconds < 180
        do {
            let rawTranscript = try await Task(priority: .userInitiated) {
                try await self.callWhisper(audioData: audioData)
            }.value

            if durationSeconds < 180 {
                // Mode A: < 3 min — clean + summary, copy to clipboard, silent save
                let output = try await callChat(
                    systemPrompt: Self.promptModeA,
                    userMessage: rawTranscript,
                    maxTokens: 700,
                    model: APIConstants.chatModelForShortClean
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
                if let storage = notesStorage {
                    _ = storage.saveQuickNote(text: output, durationSeconds: durationSeconds)
                    storage.refreshNotes()
                }
                isProcessing = false
                showCompletion("Copied")

            } else if durationSeconds < 300 {
                // Mode B: 3–5 min — LLM overview, save as voice note, open panel
                let overview = try await callChat(
                    systemPrompt: Self.promptModeB,
                    userMessage: rawTranscript,
                    maxTokens: 800,
                    model: APIConstants.chatModelForShortClean
                )
                if let storage = notesStorage {
                    let id = storage.saveVoiceNote(overview: overview, durationSeconds: durationSeconds)
                    storage.refreshNotes()
                    onNoteCreated?(id)
                }
                isProcessing = false
                showCompletion("Note saved")

            } else {
                // Mode C: > 5 min — two parallel LLM calls (clean transcript + overview)
                async let cleanedTranscriptCall = callChat(
                    systemPrompt: Self.promptModeC_transcript,
                    userMessage: rawTranscript,
                    maxTokens: 3000,
                    model: APIConstants.chatModel
                )
                async let overviewCall = callChat(
                    systemPrompt: Self.promptModeC_overview,
                    userMessage: rawTranscript,
                    maxTokens: 1500,
                    model: APIConstants.chatModel
                )
                let (cleanedTranscript, overview) = try await (cleanedTranscriptCall, overviewCall)
                if let storage = notesStorage {
                    let id = storage.saveMeetingNote(transcript: cleanedTranscript, overview: overview, durationSeconds: durationSeconds)
                    storage.refreshNotes()
                    onNoteCreated?(id)
                }
                isProcessing = false
                showCompletion("Note saved")
            }
        } catch {
            isProcessing = false
            let desc = error.localizedDescription
            errorMessage = desc
            print("[Transcription] FAILED — \(desc)")
            print("[Transcription] Full error: \(error)")
            showCompletion("Failed")
            lastErrorForBanner = desc
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.lastErrorForBanner = nil
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

    // MARK: - Whisper API

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
                          userInfo: [NSLocalizedDescriptionKey: responseText])
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
                          userInfo: [NSLocalizedDescriptionKey: responseText])
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
