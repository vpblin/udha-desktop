import Foundation
import Observation
import os

@MainActor
@Observable
final class VoiceController {
    let agent: ConversationalAgent
    let proactive: ProactiveVoiceEngine
    let stateStore: SessionStateStore
    let config: ConfigStore
    let tts: ElevenLabsTTSClient

    private(set) var isListening: Bool = false
    private(set) var statusMessage: String = "off"

    init(agent: ConversationalAgent,
         proactive: ProactiveVoiceEngine,
         stateStore: SessionStateStore,
         config: ConfigStore,
         tts: ElevenLabsTTSClient) {
        self.agent = agent
        self.proactive = proactive
        self.stateStore = stateStore
        self.config = config
        self.tts = tts
    }

    func toggle() {
        if isListening { turnOff() } else { Task { await turnOn() } }
    }

    func turnOn() async {
        guard !isListening else { return }
        statusMessage = "Connecting…"
        isListening = true
        // Unmute proactive announcements immediately so state changes are
        // spoken even if the ConvAI connection is still coming up.
        proactive.start()

        // Kick off the Jarvis welcome in parallel with the ConvAI connect — the
        // greeting is speech-only and doesn't depend on the websocket.
        Task { await speakWelcome() }

        if agent.state == .disconnected || agent.state == .failed {
            await agent.connect()
        }
        if agent.state == .connected || agent.state == .streaming {
            agent.startStreamingUserAudio()
            statusMessage = "Listening"
        } else {
            statusMessage = "Offline — TTS only"
            // Keep isListening=true so proactive speech still works; the mic
            // just isn't streaming. Caller can retry by toggling.
        }
    }

    func turnOff() {
        guard isListening else { return }
        agent.stopStreamingUserAudio()
        agent.disconnect()
        proactive.stop()
        isListening = false
        statusMessage = "off"
    }

    /// Speak a personalised Jarvis-style greeting the moment voice is enabled.
    /// Bypasses the proactive queue / cooldowns / budget so it always plays.
    private func speakWelcome() async {
        let text = buildWelcomeText()
        Log.voice.info("welcome: \(text)")
        do {
            let pcm = try await tts.streamingTTS(text: text)
            AudioPlayer.shared.enqueuePCM16(pcm)
        } catch {
            Log.voice.error("welcome TTS failed: \(error.localizedDescription)")
            // Fallback to macOS `say` so the user still gets confirmation audio.
            let task = Process()
            task.launchPath = "/usr/bin/say"
            task.arguments = [text]
            try? task.run()
        }
    }

    private func buildWelcomeText() -> String {
        let name = resolveUserFirstName()
        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d"
        let dateStr = df.string(from: now)
        df.dateFormat = "h:mm a"
        let timeStr = df.string(from: now)

        let sessionCount = stateStore.all.count
        let slackConnected = !config.config.slack.workspaces.filter(\.enabled).isEmpty

        var parts: [String] = []
        parts.append("Welcome, sir \(name).")
        parts.append("It is \(dateStr), \(timeStr).")
        if sessionCount > 0 {
            parts.append("You have \(sessionCount) session\(sessionCount == 1 ? "" : "s") running.")
        } else {
            parts.append("No sessions are running.")
        }
        if slackConnected { parts.append("Slack is connected.") }
        parts.append("Let's do this.")
        return parts.joined(separator: " ")
    }

    private func resolveUserFirstName() -> String {
        // Prefer NSFullUserName's first word; fall back to NSUserName.
        let full = NSFullUserName()
        if let first = full.split(separator: " ").first { return String(first) }
        return NSUserName()
    }
}
