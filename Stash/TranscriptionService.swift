import AppKit
import AVFoundation
import Foundation

/// Groq-only transcription + meeting notes. URLs and models are hardcoded strings (no APIConstants).
@MainActor
final class TranscriptionService: NSObject, ObservableObject {

    /// Set `STASH_GROQ_TRANSCRIPTION_KEY` or `GROQ_API_KEY` in the scheme environment; do not commit keys.
    private let groqKey: String = {
        let env = ProcessInfo.processInfo.environment
        let a = (env["STASH_GROQ_TRANSCRIPTION_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty { return a }
        return (env["GROQ_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    private let whisperURL = "https://api.groq.com/openai/v1/audio/transcriptions"
    private let chatURL = "https://api.groq.com/openai/v1/chat/completions"
    private let whisperModel = "whisper-large-v3-turbo"
    private let chatModel = "llama-3.3-70b-versatile"

    // — Published state
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var liveTranscript = ""
    @Published var duration = 0
    @Published var errorMessage: String?
    @Published var audioLevel: Float = 0

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
        makePanelKey?()
        errorMessage = nil
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
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
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

            print("[Transcription] Recording started at: \(tempURL.path)")

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
            print("[Transcription] Failed to start recorder: \(error)")
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

        guard audioData.count > 1000 else {
            print("[Transcription] Audio too small to send: \(audioData.count) bytes")
            return
        }

        print("[Transcription] Sending live chunk: \(audioData.count) bytes")

        Task { @MainActor in
            do {
                let text = try await callWhisper(audioData: audioData)
                self.liveTranscript = text
                print("[Transcription] Live transcript updated: \(text.prefix(100))")
            } catch {
                print("[Transcription] Live chunk failed: \(error)")
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

        print("[Transcription] Recording stopped — file size: \(getFileSize()) bytes")

        guard let url = recordingURL,
              let audioData = try? Data(contentsOf: url),
              audioData.count > 1000 else {
            print("[Transcription] Recording file missing or too small")
            errorMessage = "Recording failed — no audio captured"
            isProcessing = false
            return
        }

        Task { @MainActor in
            defer {
                if let r = self.recordingURL {
                    try? FileManager.default.removeItem(at: r)
                }
            }
            do {
                print("[Transcription] Sending final audio to Whisper: \(audioData.count) bytes")
                let transcript = try await callWhisper(audioData: audioData)
                print("[Transcription] Final transcript: \(transcript)")

                print("[Transcription] Sending transcript to Groq LLM")
                let notes = try await callGroqLLM(transcript: transcript)
                print("[Transcription] Notes generated: \(notes.prefix(200))")

                self.isProcessing = false
                self.createNote(notes: notes)
            } catch {
                print("[Transcription] Final processing failed: \(error)")
                self.isProcessing = false
                self.errorMessage = "Failed: \(error.localizedDescription)"
            }
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
        request.timeoutInterval = 60

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("Bearer \(groqKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(whisperModel)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        print("[Whisper] Calling: \(whisperURL)")
        print("[Whisper] Audio size: \(audioData.count) bytes")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseText = String(data: data, encoding: .utf8) ?? "unreadable"

        print("[Whisper] Status: \(status)")
        print("[Whisper] Response: \(responseText)")

        guard status == 200 else {
            throw NSError(
                domain: "Whisper",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: responseText]
            )
        }

        return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Groq LLM API

    private func callGroqLLM(transcript: String) async throws -> String {
        let url = URL(string: chatURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(groqKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
        You are a meeting notes assistant. Given a raw transcript produce clean structured notes:

        ## Summary
        2-3 sentence overview of what was discussed

        ## Key Points
        - Most important points as bullets

        ## Action Items
        - [ ] Action items with owner name if mentioned

        ## Decisions Made
        - Any decisions or conclusions

        Be concise. Use real names from the transcript. Mark unclear parts with [unclear].
        """

        let body: [String: Any] = [
            "model": chatModel,
            "max_tokens": 1000,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Here is the transcript:\n\n\(transcript)"]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[GroqLLM] Calling: \(chatURL)")
        print("[GroqLLM] Transcript length: \(transcript.count) chars")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseText = String(data: data, encoding: .utf8) ?? "unreadable"

        print("[GroqLLM] Status: \(status)")
        print("[GroqLLM] Response: \(responseText)")

        guard status == 200 else {
            throw NSError(
                domain: "GroqLLM",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: responseText]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "GroqLLM", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON shape"])
        }
        return content
    }

    // MARK: - Create note

    private func createNote(notes: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM h:mm a"
        let title = "\(NotesStorage.transcribedMeetingTitlePrefix)\(formatter.string(from: Date()))"

        if let storage = notesStorage {
            let id = storage.createNoteWithTitle(title, body: notes)
            storage.refreshNotes()
            print("[Transcription] Note saved via NotesStorage id=\(id)")
            NotificationCenter.default.post(name: .quickPanelShouldShow, object: nil)
            onNoteCreated?(id)
            return
        }

        let notesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuickPanel/notes")
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let fileURL = notesDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).txt")
        let content = title + "\n\n" + notes
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            print("[Transcription] Note saved (fallback): \(fileURL.path)")
            NotificationCenter.default.post(name: NSNotification.Name("NewNoteCreated"), object: fileURL)
        } catch {
            print("[Transcription] Failed to save note: \(error)")
            errorMessage = "Could not save note: \(error.localizedDescription)"
        }
    }

    // MARK: - Helper

    private func getFileSize() -> Int {
        guard let url = recordingURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return attrs[.size] as? Int ?? 0
    }
}
