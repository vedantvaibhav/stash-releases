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

    // MARK: - Unified pipeline

    private func processRecording(audioData: Data, durationSeconds: Int) async {
        lastRecordingWasShort = durationSeconds < 300
        do {
            // Step 1 — Always transcribe with Whisper (userInitiated priority)
            let rawTranscript = try await Task(priority: .userInitiated) {
                try await self.callWhisper(audioData: audioData)
            }.value

            if durationSeconds < 300 {
                // SHORT — under 5 minutes: clean (fast model) and copy
                let cleanedText = try await Task(priority: .userInitiated) {
                    try await self.callCleanTranscript(rawTranscript)
                }.value

                // Copy to clipboard
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cleanedText, forType: .string)

                // Silent save — the Quick Transcript is kept in history, but the
                // pill's "Copied ✓" is the only feedback. Panel does NOT open for
                // short recordings; clipboard already has the text.
                if let storage = notesStorage {
                    _ = storage.saveQuickNote(text: cleanedText, durationSeconds: durationSeconds)
                    storage.refreshNotes()
                }

                isProcessing = false
                showCompletion("Copied")

            } else {
                // LONG — 5+ minutes: format as meeting notes (userInitiated priority)
                let overview = try await Task(priority: .userInitiated) {
                    try await self.callMeetingNotes(transcript: rawTranscript, durationSeconds: durationSeconds)
                }.value

                if let storage = notesStorage {
                    let id = storage.saveMeetingNote(transcript: rawTranscript, overview: overview, durationSeconds: durationSeconds)
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

    // MARK: - Short transcript cleaning

    private func callCleanTranscript(_ rawTranscript: String) async throws -> String {
        let prompt = """
        You are a precise transcription cleaner. The input is a raw English voice transcript.

        Your job:
        - Fix grammar and punctuation
        - Remove filler words: um, uh, like, you know, sort of, kind of, right
        - Fix self-corrections: if someone says "at 5, no wait, 7" write "at 7"
        - Fix run-on sentences by adding punctuation
        - Preserve the speaker's actual meaning — do not rephrase or summarise
        - Keep technical terms, names, and numbers exactly as spoken
        - Output plain text only — no headers, no bullets, no markdown
        - If it is a question, keep it as a question
        - If it is a list of items, format as a simple comma-separated list

        Output only the cleaned text. Nothing else.

        Transcript: \(rawTranscript)
        """
        return try await callChat(
            systemPrompt: nil,
            userMessage: prompt,
            maxTokens: 500,
            model: APIConstants.chatModelForShortClean
        )
    }

    // MARK: - Meeting notes formatting

    private func callMeetingNotes(transcript: String, durationSeconds: Int) async throws -> String {
        let prompt = meetingPrompt(transcript: transcript, durationSeconds: durationSeconds)
        return try await callChat(systemPrompt: nil, userMessage: prompt, maxTokens: 2000)
    }

    private func meetingPrompt(transcript: String, durationSeconds: Int) -> String {
        if durationSeconds < 600 {
            // 5–10 minutes — medium format
            return """
            You are a meeting notes assistant. The input is an English meeting transcript.

            Rules:
            - Only use information actually said in the transcript
            - Never invent names, numbers, or decisions not mentioned
            - If something is unclear write [unclear] — never guess
            - Use the speaker's actual words where possible

            Output this exact structure — no extra sections:

            ## Summary
            2–3 sentences. What was discussed and what was decided.

            ## Key Points
            - Bullet each main topic discussed
            - One clear sentence per bullet
            - Maximum 6 bullets

            Transcript: \(transcript)
            """
        } else {
            // Over 10 minutes — full format
            return """
            You are a meeting notes assistant. The input is an English meeting transcript.

            Rules:
            - Only use information actually said in the transcript
            - Never invent names, numbers, or decisions not mentioned
            - If something is unclear write [unclear] — never guess
            - Use real names if mentioned; otherwise use "Speaker"
            - Action items need an owner — if not mentioned write [owner TBD]

            Output this exact structure:

            ## Summary
            2–3 sentences capturing the meeting purpose and outcome.

            ## Key Points
            - Important topics discussed
            - One idea per bullet, max 8 bullets

            ## Decisions
            - Firm decisions made during the meeting
            - If none: "No decisions recorded"

            ## Action Items
            - [ ] What needs to be done — Owner — Due date if mentioned
            - If none: "No action items recorded"

            ## Open Questions
            - Unresolved questions needing follow-up
            - If none: "None"

            Transcript: \(transcript)
            """
        }
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
