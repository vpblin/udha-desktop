import Foundation

struct ChatMessage: Codable, Sendable {
    var role: String
    var content: String
}

struct ChatRequest: Codable {
    var model: String
    var messages: [ChatMessage]
    var temperature: Double?
    var max_tokens: Int?
    var stream: Bool?
}

struct ChatChoice: Codable {
    struct Message: Codable { var role: String; var content: String? }
    var index: Int?
    var message: Message?
}

struct ChatResponse: Codable {
    var choices: [ChatChoice]
}

enum OpenRouterError: Error, LocalizedError {
    case noAPIKey
    case httpError(Int, String)
    case decodingFailed
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "OpenRouter API key not set"
        case .httpError(let code, let body): return "OpenRouter HTTP \(code): \(body)"
        case .decodingFailed: return "OpenRouter response could not be decoded"
        case .emptyResponse: return "OpenRouter returned empty content"
        }
    }
}

actor OpenRouterClient {
    private let keychain: KeychainStore
    private let session = URLSession(configuration: .default)
    private let baseURL: URL

    init(keychain: KeychainStore, baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!) {
        self.keychain = keychain
        self.baseURL = baseURL
    }

    func complete(
        model: String,
        messages: [ChatMessage],
        temperature: Double? = 0.2,
        maxTokens: Int? = 300
    ) async throws -> String {
        guard let key = keychain.get(.openRouterAPIKey) else { throw OpenRouterError.noAPIKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/blinkazazi/Udha.AIDesktop", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Udha.AI Desktop", forHTTPHeaderField: "X-Title")

        let body = ChatRequest(model: model, messages: messages, temperature: temperature, max_tokens: maxTokens, stream: false)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.decodingFailed }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw OpenRouterError.httpError(http.statusCode, bodyStr)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message?.content, !content.isEmpty else {
            throw OpenRouterError.emptyResponse
        }
        return content
    }
}
