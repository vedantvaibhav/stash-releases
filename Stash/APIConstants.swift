import Foundation

/// OpenAI-compatible inference: host and models are derived from the shape of the **primary** key.
/// Keys are supplied only via `APIKeys` (env / plist — never commit real values).
enum APIConstants {
    static var groqAPIKey: String { APIKeys.stashInferenceAPIKey }
    static var speechTranscriptionAPIKey: String { APIKeys.stashSpeechTranscriptionAPIKey }

    static var inferenceBaseURL: String { baseURL(forKey: groqAPIKey) }

    static var transcriptionBaseURL: String {
        let extra = speechTranscriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if extra.isEmpty { return inferenceBaseURL }
        return baseURL(forKey: extra)
    }

    static var transcriptionAuthKey: String {
        let extra = speechTranscriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? groqAPIKey : extra
    }

    /// Picks the right model name for whatever endpoint we're hitting.
    static var whisperModel: String {
        let key = transcriptionAuthKey
        if key.hasPrefix("gsk_") { return "whisper-large-v3-turbo" }
        if key.hasPrefix("sk-proj-") || key.hasPrefix("sk-") { return "whisper-1" }
        // Key is empty or unknown prefix — fall back to inference provider detection.
        let inferKey = groqAPIKey
        if inferKey.hasPrefix("gsk_") { return "whisper-large-v3-turbo" }
        return "whisper-1"
    }

    static var chatModel: String {
        let k = groqAPIKey
        if k.hasPrefix("gsk_") { return "llama-3.3-70b-versatile" }
        if k.hasPrefix("xai-") { return "grok-3-mini" }
        return "gpt-4o"
    }

    /// Faster/cheaper model for the short (<5 min) cleaning step — speed over polish.
    static var chatModelForShortClean: String {
        let k = groqAPIKey
        if k.hasPrefix("gsk_") { return "llama-3.1-8b-instant" }
        if k.hasPrefix("sk-proj-") || k.hasPrefix("sk-") { return "gpt-4o-mini" }
        return chatModel
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
}
