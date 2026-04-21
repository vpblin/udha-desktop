import SwiftUI

struct SettingsView: View {
    @Bindable var config: ConfigStore
    let keychain: KeychainStore
    let tts: ElevenLabsTTSClient
    let core: AppCore

    @State private var openRouterKey: String = ""
    @State private var elevenLabsKey: String = ""
    @State private var agentID: String = ""
    @State private var voices: [ElevenLabsVoice] = []
    @State private var message: String = ""
    @State private var inputDevices: [AudioDevice] = []
    @State private var outputDevices: [AudioDevice] = []

    var body: some View {
        TabView {
            overlayTab.tabItem { Label("Overlay", systemImage: "rectangle.righthalf.inset.filled") }
            voiceTab.tabItem { Label("Voice", systemImage: "waveform") }
            devicesTab.tabItem { Label("Devices", systemImage: "speaker.wave.2") }
            keysTab.tabItem { Label("Keys", systemImage: "key") }
            notificationsTab.tabItem { Label("Notifications", systemImage: "bell") }
            hotkeyTab.tabItem { Label("Hotkey", systemImage: "keyboard") }
            SlackSettingsView(config: config, manager: core.slack)
                .tabItem { Label("Slack", systemImage: "message") }
        }
        .frame(width: 560, height: 520)
        .onAppear {
            loadFromKeychain()
            refreshDevices()
        }
    }

    private var overlayTab: some View {
        Form {
            Toggle("Edge overlay enabled", isOn: Binding(
                get: { config.config.overlay.enabled },
                set: { new in
                    config.mutate { $0.overlay.enabled = new }
                    NotificationCenter.default.post(name: .udhaOverlayConfigChanged, object: nil)
                }
            ))

            Picker("Screen edge", selection: Binding(
                get: { config.config.overlay.edge },
                set: { new in
                    config.mutate { $0.overlay.edge = new }
                    NotificationCenter.default.post(name: .udhaOverlayConfigChanged, object: nil)
                }
            )) {
                Text("Right").tag(OverlayEdge.right)
                Text("Left").tag(OverlayEdge.left)
            }
            .pickerStyle(.segmented)

            Picker("Labels", selection: Binding(
                get: { config.config.overlay.labelMode },
                set: { new in config.mutate { $0.overlay.labelMode = new } }
            )) {
                Text("On hover").tag(OverlayLabelMode.onHover)
                Text("Always").tag(OverlayLabelMode.always)
                Text("Never").tag(OverlayLabelMode.never)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Trigger width")
                Slider(
                    value: Binding(
                        get: { config.config.overlay.triggerWidth },
                        set: { new in
                            config.mutate { $0.overlay.triggerWidth = new }
                            NotificationCenter.default.post(name: .udhaOverlayConfigChanged, object: nil)
                        }
                    ),
                    in: 4...28, step: 1
                )
                Text("\(Int(config.config.overlay.triggerWidth))pt")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Text("Hover-to-focus delay")
                Slider(
                    value: Binding(
                        get: { Double(config.config.overlay.hoverFocusDelayMs) },
                        set: { new in config.mutate { $0.overlay.hoverFocusDelayMs = Int(new) } }
                    ),
                    in: 0...600, step: 20
                )
                Text("\(config.config.overlay.hoverFocusDelayMs)ms")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 56, alignment: .trailing)
            }

            Toggle("Hide main window on launch", isOn: Binding(
                get: { config.config.overlay.hideMainWindowOnLaunch },
                set: { new in config.mutate { $0.overlay.hideMainWindowOnLaunch = new } }
            ))

            Text("The overlay floats on top of every screen. Hover the edge to bloom, hover a session to bring its Terminal window forward.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding()
    }

    private var devicesTab: some View {
        Form {
            Picker("Microphone", selection: $config.config.voice.inputDeviceUID) {
                Text("System default").tag("")
                ForEach(inputDevices) { dev in
                    Text(dev.name).tag(dev.uid)
                }
            }
            Picker("Speakers / output", selection: $config.config.voice.outputDeviceUID) {
                Text("System default").tag("")
                ForEach(outputDevices) { dev in
                    Text(dev.name).tag(dev.uid)
                }
            }
            HStack {
                Button("Refresh") { refreshDevices() }
                Spacer()
                Button("Save") {
                    config.save()
                    core.applyOutputDevice()
                    message = "Saved. Toggle voice (⌘K twice) to apply mic change."
                }
                .buttonStyle(.borderedProminent)
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func refreshDevices() {
        inputDevices = AudioDeviceLister.inputDevices()
        outputDevices = AudioDeviceLister.outputDevices()
    }

    private var voiceTab: some View {
        Form {
            Section("Voice") {
                Picker("Name", selection: $config.config.voice.elevenLabsVoiceID) {
                    Section("Built-in") {
                        ForEach(BuiltInVoices.all) { v in
                            Text(v.name).tag(v.voice_id)
                        }
                    }
                    if !customVoices.isEmpty {
                        Section("From your ElevenLabs account") {
                            ForEach(customVoices) { v in Text(v.name).tag(v.voice_id) }
                        }
                    }
                    // Keep an entry for whatever's currently saved so the picker
                    // never renders a blank selection for a custom voice ID.
                    if !BuiltInVoices.all.contains(where: { $0.voice_id == config.config.voice.elevenLabsVoiceID }),
                       !customVoices.contains(where: { $0.voice_id == config.config.voice.elevenLabsVoiceID }),
                       !config.config.voice.elevenLabsVoiceID.isEmpty {
                        Text(config.config.voice.elevenLabsVoiceID).tag(config.config.voice.elevenLabsVoiceID)
                    }
                }
                if let v = BuiltInVoices.all.first(where: { $0.voice_id == config.config.voice.elevenLabsVoiceID }),
                   let desc = v.description {
                    Text(desc).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Preview voice") { Task { await previewVoice() } }
                    Button("Load my voices") { Task { await loadVoices() } }
                    Spacer()
                }
            }
            Section("Model & level") {
                Picker("TTS Model", selection: $config.config.voice.ttsModel) {
                    Text("Flash v2.5 (fastest)").tag("eleven_flash_v2_5")
                    Text("Turbo v2.5").tag("eleven_turbo_v2_5")
                    Text("Multilingual v2").tag("eleven_multilingual_v2")
                }
                Slider(value: $config.config.voice.volume, in: 0...1) { Text("Volume") }
            }
            Section("Conversational agent") {
                TextField("Agent ID", text: $agentID)
                Button("Save agent ID") {
                    config.mutate { $0.voice.elevenLabsAgentID = agentID }
                    try? keychain.set(agentID, for: .elevenLabsAgentID)
                    message = "Saved."
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding()
    }

    private var customVoices: [ElevenLabsVoice] {
        voices.filter { v in !BuiltInVoices.all.contains(where: { $0.voice_id == v.voice_id }) }
    }

    private func previewVoice() async {
        do {
            let name = BuiltInVoices.all.first(where: { $0.voice_id == config.config.voice.elevenLabsVoiceID })?.name ?? "there"
            let pcm = try await tts.streamingTTS(text: "Hi, this is \(name). How do I sound?")
            AudioPlayer.shared.enqueuePCM16(pcm)
            message = "Playing preview…"
        } catch {
            message = "Preview failed: \(error.localizedDescription)"
        }
    }

    private var keysTab: some View {
        Form {
            SecureField("OpenRouter key", text: $openRouterKey)
            SecureField("ElevenLabs key", text: $elevenLabsKey)
            Button("Save") {
                if !openRouterKey.isEmpty { try? keychain.set(openRouterKey, for: .openRouterAPIKey) }
                if !elevenLabsKey.isEmpty { try? keychain.set(elevenLabsKey, for: .elevenLabsAPIKey) }
                message = "Saved."
            }
        }
        .padding()
    }

    private var notificationsTab: some View {
        Form {
            Stepper("Per-session cooldown: \(config.config.notifications.perSessionCooldownSec)s",
                    value: $config.config.notifications.perSessionCooldownSec, in: 0...300)
            Stepper("Global cooldown: \(config.config.notifications.globalCooldownSec)s",
                    value: $config.config.notifications.globalCooldownSec, in: 0...60)
            Toggle("Suppress focused session", isOn: $config.config.notifications.suppressFocusedSession)
            TextField("Quiet hours start", text: $config.config.notifications.quietHoursStart)
            TextField("Quiet hours end", text: $config.config.notifications.quietHoursEnd)
            Button("Save") { config.save() }
        }
        .padding()
    }

    private var hotkeyTab: some View {
        Form {
            Picker("Mode", selection: $config.config.voice.pushToTalkMode) {
                Text("Hold").tag(PushToTalkMode.hold)
                Text("Toggle").tag(PushToTalkMode.toggle)
            }
            Text("Default hotkey: ⌘⇧Space (remapping coming)").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private func loadFromKeychain() {
        openRouterKey = keychain.get(.openRouterAPIKey) ?? ""
        elevenLabsKey = keychain.get(.elevenLabsAPIKey) ?? ""
        agentID = config.config.voice.elevenLabsAgentID
    }

    private func loadVoices() async {
        do { voices = try await tts.fetchVoices() } catch { message = "Error: \(error.localizedDescription)" }
    }
}
