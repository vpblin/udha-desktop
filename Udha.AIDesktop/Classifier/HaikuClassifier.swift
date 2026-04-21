import Foundation

@MainActor
final class HaikuClassifier {
    let openRouter: OpenRouterClient
    let config: ConfigStore

    init(openRouter: OpenRouterClient, config: ConfigStore) {
        self.openRouter = openRouter
        self.config = config
    }

    func summarize(sessionLabel: String, recentLines: [String]) async throws -> String {
        let model = config.config.classifier.model
        let text = recentLines.suffix(40).joined(separator: "\n")

        let system = """
        You summarize what a Claude Code coding session is currently doing in one brief sentence (max 15 words). \
        Present tense. No preamble. No quotes. If the output is idle or unclear, reply "Idle." exactly.
        """
        let user = "Session label: \(sessionLabel)\n\nRecent output:\n\(text)"

        let summary = try await openRouter.complete(
            model: model,
            messages: [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: user)
            ],
            temperature: 0.2,
            maxTokens: 60
        )

        return summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,;:"))
    }

    func naturalProactive(sessionLabel: String, state: SessionState, context: String) async throws -> String {
        let model = config.config.classifier.model
        let system = """
        You craft brief spoken notifications for a voice copilot. Tone: casual, conversational, contractions, max 25 words. \
        Lead with the session label. Never read raw output — paraphrase. Spell numbers as words (forty-seven, not 47).
        """
        let user = """
        Session: \(sessionLabel)
        State: \(state.rawValue)
        Context:
        \(context)

        Write one short spoken notification.
        """
        return try await openRouter.complete(
            model: model,
            messages: [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: user)
            ],
            temperature: 0.5,
            maxTokens: 80
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
