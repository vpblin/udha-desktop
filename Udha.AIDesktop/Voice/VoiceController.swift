import Foundation
import Observation
import os

@MainActor
@Observable
final class VoiceController {
    let agent: ConversationalAgent
    let proactive: ProactiveVoiceEngine

    private(set) var isListening: Bool = false
    private(set) var statusMessage: String = "off"

    init(agent: ConversationalAgent, proactive: ProactiveVoiceEngine) {
        self.agent = agent
        self.proactive = proactive
    }

    func toggle() {
        if isListening { turnOff() } else { Task { await turnOn() } }
    }

    func turnOn() async {
        guard !isListening else { return }
        statusMessage = "connecting…"
        isListening = true
        // Unmute proactive announcements immediately so state changes are
        // spoken even if the ConvAI connection is still coming up.
        proactive.start()
        if agent.state == .disconnected || agent.state == .failed {
            await agent.connect()
        }
        if agent.state == .connected || agent.state == .streaming {
            agent.startStreamingUserAudio()
            statusMessage = "listening"
        } else {
            statusMessage = "failed to connect"
            isListening = false
            proactive.stop()
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
}
