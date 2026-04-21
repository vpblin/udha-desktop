import SwiftUI

struct FirstRunView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var config: ConfigStore
    let keychain: KeychainStore
    let tts: ElevenLabsTTSClient
    var onComplete: () -> Void

    @State private var step: Int = 0
    @State private var openRouterKey: String = ""
    @State private var elevenLabsKey: String = ""
    @State private var agentID: String = ""
    @State private var availableVoices: [ElevenLabsVoice] = []
    @State private var selectedVoiceID: String = ""
    @State private var isLoadingVoices: Bool = false
    @State private var errorMessage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Udha.AI").font(.title).bold()
            Text("Two-minute setup. Everything gets saved locally in Keychain.").font(.callout).foregroundStyle(.secondary)

            switch step {
            case 0: openRouterStep
            case 1: elevenLabsStep
            case 2: voiceStep
            case 3: agentStep
            default: doneStep
            }

            if !errorMessage.isEmpty {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }

            HStack {
                if step > 0 && step < 4 {
                    Button("Back") { step -= 1 }
                }
                Spacer()
                if step < 4 {
                    Button(step == 3 ? "Finish" : "Next") { Task { await advance() } }
                        .keyboardShortcut(.return)
                        .disabled(nextDisabled)
                } else {
                    Button("Done") { onComplete(); dismiss() }
                        .keyboardShortcut(.return)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
    }

    private var openRouterStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenRouter key").font(.headline)
            Text("For the Haiku classifier and session summaries.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("sk-or-v1-…", text: $openRouterKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var elevenLabsStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ElevenLabs key").font(.headline)
            Text("For voice — TTS and the conversational agent.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("sk_…", text: $elevenLabsKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick a voice").font(.headline)
            if isLoadingVoices {
                ProgressView("Loading voices…")
            } else if availableVoices.isEmpty {
                HStack {
                    Text("Couldn't load voices.").font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await loadVoices() } }
                }
            } else {
                Picker("Voice", selection: $selectedVoiceID) {
                    ForEach(availableVoices) { v in
                        Text(v.name).tag(v.voice_id)
                    }
                }
                .pickerStyle(.menu)
                Button("Test") { Task { await testVoice() } }
            }
        }
    }

    private var agentStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ElevenLabs agent ID").font(.headline)
            Text("Paste the agent ID from your ElevenLabs dashboard (starts with 'agent_').")
                .font(.caption).foregroundStyle(.secondary)
            TextField("agent_…", text: $agentID)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You're set.").font(.headline)
            Text("Press ⌘⇧Space to talk. Add your first session from the main window.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var nextDisabled: Bool {
        switch step {
        case 0: return openRouterKey.isEmpty
        case 1: return elevenLabsKey.isEmpty
        case 2: return selectedVoiceID.isEmpty
        case 3: return agentID.isEmpty
        default: return false
        }
    }

    private func advance() async {
        errorMessage = ""
        switch step {
        case 0:
            try? keychain.set(openRouterKey, for: .openRouterAPIKey)
            step = 1
        case 1:
            try? keychain.set(elevenLabsKey, for: .elevenLabsAPIKey)
            await loadVoices()
            step = 2
        case 2:
            config.mutate { $0.voice.elevenLabsVoiceID = selectedVoiceID }
            try? keychain.set(selectedVoiceID, for: .elevenLabsVoiceID)
            step = 3
        case 3:
            config.mutate { cfg in
                cfg.voice.elevenLabsAgentID = agentID
                cfg.hasCompletedFirstRun = true
            }
            try? keychain.set(agentID, for: .elevenLabsAgentID)
            step = 4
        default:
            break
        }
    }

    private func loadVoices() async {
        isLoadingVoices = true
        defer { isLoadingVoices = false }
        do {
            let voices = try await tts.fetchVoices()
            availableVoices = voices
            if selectedVoiceID.isEmpty, let first = voices.first {
                selectedVoiceID = first.voice_id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testVoice() async {
        let prior = config.config.voice.elevenLabsVoiceID
        config.mutate { $0.voice.elevenLabsVoiceID = selectedVoiceID }
        do {
            let pcm = try await tts.streamingTTS(text: "Hi Blin, I'm your copilot.")
            let player = AudioPlayer()
            player.start()
            player.enqueuePCM16(pcm)
        } catch {
            errorMessage = error.localizedDescription
        }
        config.mutate { $0.voice.elevenLabsVoiceID = prior }
    }
}
