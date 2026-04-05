import Foundation

/// `groqAPIKey` is the **primary** key (chat + speech when a single provider handles both).
/// The **host** is picked from its shape:
/// - `gsk_…` → **Groq** (Whisper + Llama)
/// - `xai-…` → **xAI** for **chat**; speech uses `speechTranscriptionAPIKey` if set, otherwise attempts xAI (may not support file transcription).
/// - `sk-…` / `sk-proj-…` → **OpenAI** (Whisper + GPT)
enum APIConstants {
    /// Set `STASH_INFERENCE_API_KEY` in the Xcode scheme (Run → Arguments → Environment) or your shell. Do not commit keys.
    static let groqAPIKey: String = {
        let v = (ProcessInfo.processInfo.environment["STASH_INFERENCE_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v
    }()

    /// Optional separate key for Whisper: **Groq `gsk_…`** or **OpenAI `sk-…`** when the primary key is xAI. Env: `STASH_SPEECH_TRANSCRIPTION_API_KEY`.
    /// Leave unset to use the same host as the primary key (works for Groq/OpenAI-only setups).
    static let speechTranscriptionAPIKey: String = {
        let v = (ProcessInfo.processInfo.environment["STASH_SPEECH_TRANSCRIPTION_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v
    }()

    /// OpenAI-compatible base URL for **chat** (no trailing slash).
    static var inferenceBaseURL: String {
        baseURL(forKey: groqAPIKey)
    }

    /// Base URL used only for `POST …/audio/transcriptions`.
    static var transcriptionBaseURL: String {
        let extra = speechTranscriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if extra.isEmpty { return inferenceBaseURL }
        return baseURL(forKey: extra)
    }

    /// Bearer token for Whisper requests.
    static var transcriptionAuthKey: String {
        let extra = speechTranscriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? groqAPIKey : extra
    }

    static var whisperModel: String {
        let key = transcriptionAuthKey
        if key.hasPrefix("gsk_") { return "whisper-large-v3-turbo" }
        return "whisper-1"
    }

    static var chatModel: String {
        let k = groqAPIKey
        if k.hasPrefix("gsk_") { return "llama-3.3-70b-versatile" }
        if k.hasPrefix("xai-") { return "grok-3-mini" }
        return "gpt-4o"
    }

    static var providerLabel: String {
        let k = groqAPIKey
        if k.hasPrefix("gsk_") { return "Groq" }
        if k.hasPrefix("xai-") { return "xAI" }
        if k.hasPrefix("sk-proj-") || k.hasPrefix("sk-") { return "OpenAI" }
        return "default(Groq host)"
    }

    private static func baseURL(forKey key: String) -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("gsk_") { return "https://api.groq.com/openai/v1" }
        if k.hasPrefix("xai-") { return "https://api.x.ai/v1" }
        if k.hasPrefix("sk-proj-") || k.hasPrefix("sk-") { return "https://api.openai.com/v1" }
        return "https://api.groq.com/openai/v1"
    }
