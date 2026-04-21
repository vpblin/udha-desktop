import Foundation
import os

enum ElevenLabsError: Error, LocalizedError {
    case noAPIKey
    case httpError(Int, String)
    case noVoiceID

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "ElevenLabs API key not set"
        case .httpError(let code, let body): return "ElevenLabs HTTP \(code): \(body)"
        case .noVoiceID: return "ElevenLabs voice ID not configured"
        }
    }
}

struct TTSVoiceSettings: Codable {
    var stability: Double = 0.5
    var similarity_boost: Double = 0.75
    var style: Double = 0.0
    var use_speaker_boost: Bool = true
}

struct TTSRequestBody: Codable {
    var text: String
    var model_id: String
    var voice_settings: TTSVoiceSettings?
}

actor ElevenLabsTTSClient {
    private let keychain: KeychainStore
    private let config: ConfigStore
    private let session: URLSession

    init(keychain: KeychainStore, config: ConfigStore) {
        self.keychain = keychain
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: cfg)
    }

    func fetchVoices() async throws -> [ElevenLabsVoice] {
        guard let key = keychain.get(.elevenLabsAPIKey) else { throw ElevenLabsError.noAPIKey }
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ElevenLabsError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }
        let decoded = try JSONDecoder().decode(VoicesResponse.self, from: data)
        return decoded.voices
    }

    func getSignedConvAIURL(agentID: String) async throws -> URL {
        guard let key = keychain.get(.elevenLabsAPIKey) else { throw ElevenLabsError.noAPIKey }
        var comps = URLComponents(string: "https://api.elevenlabs.io/v1/convai/conversation/get-signed-url")!
        comps.queryItems = [URLQueryItem(name: "agent_id", value: agentID)]
        var req = URLRequest(url: comps.url!)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ElevenLabsError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }
        struct SignedResponse: Codable { var signed_url: String }
        let decoded = try JSONDecoder().decode(SignedResponse.self, from: data)
        guard let url = URL(string: decoded.signed_url) else {
            throw ElevenLabsError.httpError(-1, "invalid signed_url")
        }
        return url
    }

    func streamingTTS(text: String) async throws -> Data {
        guard let key = keychain.get(.elevenLabsAPIKey) else {
            Log.voice.error("streamingTTS: no API key in keychain")
            throw ElevenLabsError.noAPIKey
        }
        let voiceID = await MainActor.run { config.config.voice.elevenLabsVoiceID }
        let modelID = await MainActor.run { config.config.voice.ttsModel }

        Log.voice.info("streamingTTS: voice=\(voiceID) model=\(modelID) keyPrefix=\(String(key.prefix(6))) keyLen=\(key.count)")

        guard !voiceID.isEmpty else {
            Log.voice.error("streamingTTS: voiceID empty")
            throw ElevenLabsError.noVoiceID
        }

        var comps = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)/stream")!
        comps.queryItems = [
            URLQueryItem(name: "output_format", value: "pcm_16000"),
            URLQueryItem(name: "optimize_streaming_latency", value: "3"),
        ]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/pcm", forHTTPHeaderField: "Accept")

        let body = TTSRequestBody(text: text, model_id: modelID, voice_settings: TTSVoiceSettings())
        req.httpBody = try JSONEncoder().encode(body)

        Log.voice.info("streamingTTS: POST \(comps.url!.absoluteString)")

        let (data, response) = try await session.data(for: req)
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        Log.voice.info("streamingTTS: response status=\(httpCode) bytes=\(data.count)")

        guard (200..<300).contains(httpCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            Log.voice.error("streamingTTS: HTTP \(httpCode) body=\(bodyStr)")
            throw ElevenLabsError.httpError(httpCode, bodyStr)
        }
        return data
    }
}

struct ElevenLabsVoice: Codable, Hashable, Identifiable {
    var voice_id: String
    var name: String
    var category: String?
    var id: String { voice_id }
}

struct VoicesResponse: Codable {
    var voices: [ElevenLabsVoice]
}
