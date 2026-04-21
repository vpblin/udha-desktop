import Foundation
import Observation
import os

enum AgentConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case streaming
    case failed
}

@MainActor
@Observable
final class ConversationalAgent {
    let keychain: KeychainStore
    let config: ConfigStore
    let contextFeed: ContextFeed
    let tools: ToolHandlers
    let proactive: ProactiveVoiceEngine
    let activity: ActivityLog

    private(set) var state: AgentConnectionState = .disconnected
    private(set) var lastUserTranscript: String = ""
    private(set) var lastAgentResponse: String = ""

    private var task: URLSessionWebSocketTask?
    private var audioCapture: AudioCapture?
    private var audioPlayer: AudioPlayer { AudioPlayer.shared }
    private var session: URLSession
    private var isSending: Bool = false
    let tts: ElevenLabsTTSClient

    init(keychain: KeychainStore,
         config: ConfigStore,
         contextFeed: ContextFeed,
         tools: ToolHandlers,
         proactive: ProactiveVoiceEngine,
         activity: ActivityLog) {
        self.keychain = keychain
        self.config = config
        self.contextFeed = contextFeed
        self.tools = tools
        self.proactive = proactive
        self.activity = activity
        self.session = URLSession(configuration: .default)
        self.tts = ElevenLabsTTSClient(keychain: keychain, config: config)
    }

    func connect() async {
        guard state == .disconnected || state == .failed else { return }
        state = .connecting

        let agentID = config.config.voice.elevenLabsAgentID
        guard !agentID.isEmpty else {
            Log.agent.error("No agent ID configured")
            state = .failed
            return
        }

        do {
            let url: URL
            if let key = keychain.get(.elevenLabsAPIKey), !key.isEmpty {
                url = try await tts.getSignedConvAIURL(agentID: agentID)
            } else {
                var comps = URLComponents(string: "wss://api.elevenlabs.io/v1/convai/conversation")!
                comps.queryItems = [URLQueryItem(name: "agent_id", value: agentID)]
                url = comps.url!
            }

            let task = session.webSocketTask(with: url)
            task.resume()
            self.task = task
            state = .connected

            try await sendInitiation()
            audioPlayer.start()
            listen()
            proactive.interrupt()
            Log.agent.info("Connected to agent \(agentID)")
        } catch {
            Log.agent.error("Connect failed: \(error.localizedDescription)")
            state = .failed
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        audioCapture?.stop()
        audioCapture = nil
        audioPlayer.stop()
        state = .disconnected
    }

    func startStreamingUserAudio() {
        guard state == .connected else { return }
        state = .streaming
        let capture = AudioCapture(
            sampleRate: Double(config.config.voice.inputSampleRate),
            preferredDeviceUID: config.config.voice.inputDeviceUID.isEmpty ? nil : config.config.voice.inputDeviceUID
        )
        capture.onAudioChunk = { [weak self] data in
            Task { @MainActor in self?.sendAudioChunk(data) }
        }
        audioCapture = capture
        Task { @MainActor in
            do {
                try await capture.start()
                Log.agent.info("Mic streaming started")
            } catch {
                Log.agent.error("Mic start failed: \(error.localizedDescription)")
                self.state = .connected
                self.audioCapture = nil
            }
        }
    }

    func stopStreamingUserAudio() {
        audioCapture?.stop()
        audioCapture = nil
        if state == .streaming { state = .connected }
    }

    private func sendInitiation() async throws {
        let payload: [String: Any] = [
            "type": "conversation_initiation_client_data",
            "dynamic_variables": [
                "current_context": contextFeed.render(),
            ],
        ]
        try await send(json: payload)
    }

    func pushContextUpdate() async {
        let payload: [String: Any] = [
            "type": "contextual_update",
            "text": contextFeed.render(),
        ]
        try? await send(json: payload)
    }

    private func sendAudioChunk(_ data: Data) {
        guard let task else { return }
        let base64 = data.base64EncodedString()
        let payload: [String: Any] = [
            "type": "user_audio_chunk",
            "user_audio_chunk": base64,
        ]
        Task {
            try? await send(json: payload, task: task)
        }
    }

    private func send(json: [String: Any]) async throws {
        guard let task else { return }
        try await send(json: json, task: task)
    }

    nonisolated private func send(json: [String: Any], task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        let s = String(data: data, encoding: .utf8) ?? ""
        try await task.send(.string(s))
    }

    private func listen() {
        Task { @MainActor [weak self] in
            guard let self, let task = self.task else { return }
            while self.state != .disconnected && self.state != .failed {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        self.handleServerMessage(text: text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleServerMessage(text: text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    Log.agent.error("WS receive failed: \(error.localizedDescription)")
                    self.state = .failed
                    return
                }
            }
        }
    }

    private func handleServerMessage(text: String) {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else {
            return
        }

        switch type {
        case "conversation_initiation_metadata":
            Log.agent.debug("init metadata received")

        case "ping":
            if let ping = obj["ping_event"] as? [String: Any],
               let eventID = ping["event_id"] {
                Task { try? await self.send(json: ["type": "pong", "event_id": eventID]) }
            }

        case "user_transcript":
            if let ev = obj["user_transcription_event"] as? [String: Any],
               let transcript = ev["user_transcript"] as? String {
                lastUserTranscript = transcript
                Log.agent.info("user: \(transcript)")
            }

        case "agent_response":
            if let ev = obj["agent_response_event"] as? [String: Any],
               let resp = ev["agent_response"] as? String {
                lastAgentResponse = resp
                Log.agent.info("agent: \(resp)")
                activity.record(.voiceSpoken(text: resp, channel: "agent"))
            }

        case "audio":
            if let ev = obj["audio_event"] as? [String: Any],
               let base64 = ev["audio_base_64"] as? String,
               let pcm = Data(base64Encoded: base64) {
                audioPlayer.enqueuePCM16(pcm)
            }

        case "interruption":
            audioPlayer.clearQueue()

        case "client_tool_call":
            handleToolCall(obj)

        case "vad_score":
            break

        default:
            Log.agent.debug("unhandled message type \(type)")
        }
    }

    private func handleToolCall(_ obj: [String: Any]) {
        guard let call = obj["client_tool_call"] as? [String: Any],
              let name = call["tool_name"] as? String,
              let id = call["tool_call_id"] as? String else {
            Log.agent.error("malformed client_tool_call: \(obj)")
            return
        }
        let params = call["parameters"] as? [String: Any] ?? [:]
        Log.agent.info("tool_call: \(name) params=\(params) id=\(id)")
        Task { @MainActor in
            let result = await self.tools.invoke(name: name, arguments: params)
            let resultJSON = result.toJSON()
            Log.agent.info("tool_result: success=\(result.success) body=\(resultJSON)")
            let payload: [String: Any] = [
                "type": "client_tool_result",
                "tool_call_id": id,
                "result": resultJSON,
                "is_error": !result.success,
            ]
            do {
                try await self.send(json: payload)
                Log.agent.info("tool_result sent for id=\(id)")
            } catch {
                Log.agent.error("tool_result send FAILED: \(error.localizedDescription)")
            }
        }
    }

    private func buildSystemPrompt() -> String {
        let feed = contextFeed.render()
        return """
        You are the voice copilot for Blin's Claude Code sessions. He runs 5–15 sessions in parallel.

        Style (non-negotiable):
        - Conversational, casual, concise. Always use contractions.
        - Lead with the session label when referencing a session.
        - Answer the question first, offer follow-ups second.
        - Never read raw terminal output aloud — paraphrase.
        - Max 40 words unless the user asks for detail.
        - Numbers as words ("forty-seven", not "47").
        - Past tense for completions, present for blockers.

        DESTRUCTIVE RULE: if a pending prompt contains "drop", "delete", "deploy", "production", "rm -rf", or "force push", you MUST repeat the specific action and wait for the user's second explicit confirmation before calling approve_prompt.

        The current session state is authoritative. Do not invent state not present in the Current sessions list below.

        \(feed)
        """
    }
}
