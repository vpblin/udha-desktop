import Foundation

actor SlackSummarizer {
    private let openRouter: OpenRouterClient
    private let model: String

    init(openRouter: OpenRouterClient, model: String) {
        self.openRouter = openRouter
        self.model = model
    }

    /// Produces one short natural sentence suited for a voice assistant to speak.
    /// Falls back to a template line if the LLM call fails.
    func summarize(_ message: SlackNewMessage) async -> String {
        let location: String
        switch message.kind {
        case .im:
            location = "in a DM"
        case .mpim:
            location = "in \(message.channelLabel)"
        case .channel, .privateGroup:
            location = "in \(message.channelLabel)"
        }

        let system = """
        You turn a Slack message into one concise spoken sentence for a voice assistant to read out loud \
        to a user named Blin. Output ONE sentence only, 20 words or fewer. No quotes, no emojis, no markdown.
        Format guide: "Blin, <sender> <verb phrase describing the message intent> <location>."
        Paraphrase — do not read the message verbatim. If it's a question, say "asked…". If it's an update, say "said…" or "mentioned…".
        """

        let user = """
        Sender: \(message.senderName)
        Location: \(location) in the \(message.workspaceName) workspace
        Mentions you: \(message.mentionsSelf ? "yes" : "no")

        Message text:
        \(message.text)
        """

        do {
            let raw = try await openRouter.complete(
                model: model,
                messages: [
                    ChatMessage(role: "system", content: system),
                    ChatMessage(role: "user", content: user),
                ],
                temperature: 0.3,
                maxTokens: 80
            )
            return clean(raw)
        } catch {
            Log.slack.error("summarize failed: \(error.localizedDescription)")
            return fallback(for: message)
        }
    }

    private func clean(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("\""), out.hasSuffix("\""), out.count > 1 {
            out = String(out.dropFirst().dropLast())
        }
        return out
    }

    private func fallback(for message: SlackNewMessage) -> String {
        switch message.kind {
        case .im:
            return "Blin, \(message.senderName) sent you a DM in \(message.workspaceName)."
        case .mpim:
            return "Blin, \(message.senderName) messaged in a group DM in \(message.workspaceName)."
        case .channel, .privateGroup:
            return "Blin, \(message.senderName) mentioned you in \(message.channelLabel)."
        }
    }
}
