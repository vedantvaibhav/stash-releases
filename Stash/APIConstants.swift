import Foundation

/// OpenAI-compatible inference: host and models are derived from the shape of the **primary** key.
/// Keys are supplied only via `APIKeys` (env / plist — never commit real values).
enum APIConstants {
    static var groqAPIKey: String { APIKeys.stashInferenceAPIKey }
    static var speechTranscriptionAPIKey: String { APIKeys.stashSpeechTranscriptionAPIKey }

    /// Resolved provider for transcription + chat. Detection is prefix-driven
    /// on the single configured inference key (`APIKeys.stashInferenceAPIKey`).
    /// The default for empty/unknown prefixes is OpenAI — flipped from the
    /// prior Groq default because OpenAI's Whisper-1 has measurably lower
    /// false-rejection rates on real conversational audio (field data
    /// 2026-05-15 → 2026-05-19).
    ///
    /// `APIKeys.swift` is untouched — we only change SELECTION here, not
    /// the underlying resolution chain (env → bundled → application-support
    /// `Secrets.plist`). Multi-key support (separate OpenAI / Groq / xAI
    /// slots in Secrets.plist) is a follow-up PR.
    enum Provider {
        case openAI
        case groq
        case xAI
    }

    static var resolvedProvider: (provider: Provider, key: String) {
        let candidate = APIKeys.stashInferenceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty { return (.openAI, "") }
        if candidate.hasPrefix("sk-") || candidate.hasPrefix("sk-proj-") {
            return (.openAI, candidate)
        }
        if candidate.hasPrefix("gsk_") {
            return (.groq, candidate)
        }
        if candidate.hasPrefix("xai-") {
            return (.xAI, candidate)
        }
        // Unknown prefix → default to OpenAI semantics (was: Groq).
        return (.openAI, candidate)
    }

    /// The resolved key for the active provider. Empty if no inference key is configured.
    static var resolvedKey: String {
        return resolvedProvider.key
    }

    static var inferenceBaseURL: String { baseURL(forProvider: resolvedProvider.provider) }

    static var transcriptionBaseURL: String {
        let extra = speechTranscriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if extra.isEmpty { return inferenceBaseURL }
        return baseURL(forKey: extra)
    }

    static var transcriptionAuthKey: String {
        // If a dedicated speech key is set, prefer it (some users separate
        // their speech-transcription quota from their general inference quota).
        let extra = speechTranscriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { return extra }
        return resolvedKey
    }

    /// Picks the right model name for whatever endpoint we're hitting.
    static var whisperModel: String {
        switch resolvedProvider.provider {
        case .openAI: return "whisper-1"
        case .groq:   return "whisper-large-v3-turbo"
        case .xAI:    return "whisper-1"   // xAI doesn't offer Whisper; fall back identity
        }
    }

    static var chatModel: String {
        switch resolvedProvider.provider {
        case .openAI: return "gpt-4o"
        case .groq:   return "llama-3.3-70b-versatile"
        case .xAI:    return "grok-3-mini"
        }
    }

    /// Faster/cheaper model for the short (<5 min) cleaning step — speed over polish.
    static var chatModelForShortClean: String {
        switch resolvedProvider.provider {
        case .openAI: return "gpt-4o-mini"
        case .groq:   return "llama-3.1-8b-instant"
        case .xAI:    return chatModel   // xAI single-tier
        }
    }

    static var providerLabel: String {
        switch resolvedProvider.provider {
        case .openAI: return "OpenAI"
        case .groq:   return "Groq"
        case .xAI:    return "xAI"
        }
    }

    private static func baseURL(forProvider provider: Provider) -> String {
        switch provider {
        case .openAI: return "https://api.openai.com/v1"
        case .groq:   return "https://api.groq.com/openai/v1"
        case .xAI:    return "https://api.x.ai/v1"
        }
    }

    private static func baseURL(forKey key: String) -> String {
        // Single-keyed callers still hit this path via legacy call sites. We map
        // the prefix to provider, then look up the URL. `resolvedProvider` is the
        // preferred entry point for new code.
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("sk-proj-") || k.hasPrefix("sk-") { return "https://api.openai.com/v1" }
        if k.hasPrefix("gsk_") { return "https://api.groq.com/openai/v1" }
        if k.hasPrefix("xai-") { return "https://api.x.ai/v1" }
        return "https://api.openai.com/v1"   // unknown prefix — default to OpenAI
    }
}
