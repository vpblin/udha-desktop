import SwiftUI
import AppKit
import Combine
import os

struct RootView: View {
    @Environment(AppCore.self) private var core
    @State private var showSettings: Bool = false
    @State private var showDebug: Bool = false
    @State private var showNewSession: Bool = false
    @State private var selectedID: UUID?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Udha.AI")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                VoiceToggleButton(voice: core.voice)
            }
            ToolbarItem(placement: .primaryAction) {
                TestVoiceButton(tts: core.conversational.tts)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showNewSession = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showDebug = true } label: { Image(systemName: "wrench.and.screwdriver") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Image(systemName: "gear") }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(config: core.config, keychain: core.keychain, tts: core.conversational.tts, core: core)
                .toolbar { ToolbarItem { Button("Done") { showSettings = false } } }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(config: core.config, sessionManager: core.sessionManager, isPresented: $showNewSession)
        }
        .sheet(isPresented: $showDebug) {
            DebugPanel(core: core, isPresented: $showDebug)
        }
        .onAppear {
            if selectedID == nil { selectedID = core.stateStore.all.first?.id }
        }
        .onChange(of: selectedID) { _, new in
            core.stateStore.focusedSessionID = new
        }
        .onReceive(NotificationCenter.default.publisher(for: .udhaRequestNewSession)) { _ in
            showNewSession = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .udhaRequestSettings)) { _ in
            showSettings = true
        }
    }

    private var sidebar: some View {
        List(selection: $selectedID) {
            Section("Sessions") {
                ForEach(core.stateStore.all) { snap in
                    SessionRow(snapshot: snap).tag(Optional(snap.id))
                        .contextMenu {
                            Button("Show in Terminal") { core.sessionManager.showSession(id: snap.id) }
                            Divider()
                            Button("Remove") { core.sessionManager.removeSession(id: snap.id) }
                        }
                }
            }
        }
        .frame(minWidth: 240)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let snap = core.stateStore.snapshot(id: id) {
            SessionDetailView(snapshot: snap, core: core)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "terminal").font(.system(size: 56)).foregroundStyle(.tertiary)
                Text("Add a session to get started").foregroundStyle(.secondary)
                Button("New Session") { showNewSession = true }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct VoiceToggleButton: View {
    let voice: VoiceController
    @State private var pulse: Bool = false

    var body: some View {
        Button { voice.toggle() } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(voice.isListening ? Color.red : Color.secondary)
                    .frame(width: 10, height: 10)
                    .scaleEffect(voice.isListening && pulse ? 1.25 : 1.0)
                    .animation(voice.isListening ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
                Text(voice.statusMessage).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(voice.isListening ? Color.red.opacity(0.12) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(voice.isListening ? "Click to stop listening (⌘K)" : "Click to start listening (⌘K)")
        .keyboardShortcut("k", modifiers: [.command])
        .onAppear { pulse = true }
    }
}

struct TestVoiceButton: View {
    let tts: ElevenLabsTTSClient
    @State private var status: String = ""
    @State private var isPlaying: Bool = false
    private var player: AudioPlayer { AudioPlayer.shared }

    var body: some View {
        Button {
            Task { await test() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isPlaying ? "waveform.circle.fill" : "waveform")
                Text(status.isEmpty ? "Test voice" : status).font(.caption)
            }
        }
        .help("Plays a TTS clip through the same audio pipeline voice uses")
    }

    private func test() async {
        isPlaying = true
        status = "fetching…"
        do {
            let pcm = try await tts.streamingTTS(text: "Hi Blin. If you hear this, audio playback works.")
            status = "playing \(pcm.count)B"
            Log.voice.info("test voice fetched \(pcm.count) bytes")
            player.enqueuePCM16(pcm)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            status = "done"
        } catch {
            let msg = String(describing: error).prefix(80)
            status = String(msg)
            Log.voice.error("test voice failed: \(String(describing: error))")
        }
        isPlaying = false
    }
}

struct SessionRow: View {
    let snapshot: SessionSnapshot

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.label).font(.system(size: 13, weight: .medium))
                Text(stateLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch snapshot.state {
        case .working: return .blue
        case .needsInput: return .yellow
        case .errored: return .red
        case .completed: return .green
        case .starting, .idle: return .gray
        case .exited, .crashed: return .secondary
        }
    }

    private var stateLabel: String {
        if let summary = snapshot.recentSummary, !summary.isEmpty { return summary }
        if let activity = snapshot.currentActivity { return activity }
        return snapshot.state.rawValue
    }
}

struct SessionDetailView: View {
    let snapshot: SessionSnapshot
    let core: AppCore

    @State private var inputText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            autoApproveRow
            stateCard
            if let prompt = snapshot.pendingPrompt {
                pendingPromptCard(prompt)
            }
            recentOutputPreview
            inputBar
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var autoApproveBinding: Binding<Bool> {
        Binding(
            get: { core.config.config.sessions.first(where: { $0.id == snapshot.id })?.autoApprove ?? false },
            set: { newValue in
                core.config.mutate { cfg in
                    if let idx = cfg.sessions.firstIndex(where: { $0.id == snapshot.id }) {
                        cfg.sessions[idx].autoApprove = newValue
                    }
                }
            }
        )
    }

    private var autoApproveRow: some View {
        HStack(spacing: 12) {
            Image(systemName: autoApproveBinding.wrappedValue ? "checkmark.seal.fill" : "checkmark.seal")
                .foregroundStyle(autoApproveBinding.wrappedValue ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-approve prompts").font(.system(size: 13, weight: .medium))
                Text("Destructive prompts always require confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: autoApproveBinding)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle().fill(stateColor).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.label).font(.title2).bold()
                Text(snapshot.directory).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open in Terminal") { core.sessionManager.showSession(id: snapshot.id) }
                .buttonStyle(.borderedProminent)
            Menu {
                Button("Terminate process") { core.sessionManager.terminateSession(id: snapshot.id) }
                Button("Remove session", role: .destructive) { core.sessionManager.removeSession(id: snapshot.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
        }
    }

    private var stateCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("STATE").font(.caption2).foregroundStyle(.secondary)
                Text(snapshot.state.rawValue.capitalized).font(.title3).bold()
                Text(timeInState).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("SUMMARY").font(.caption2).foregroundStyle(.secondary)
                Text(snapshot.recentSummary ?? snapshot.currentActivity ?? "—").font(.body)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func pendingPromptCard(_ prompt: PendingPrompt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: prompt.isDestructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .foregroundStyle(prompt.isDestructive ? .red : .yellow)
                Text(prompt.isDestructive ? "Destructive prompt waiting" : "Prompt waiting")
                    .font(.headline)
                Spacer()
            }
            Text(prompt.text).font(.body).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Approve") {
                    Task { _ = await core.tools.invoke(name: "approve_prompt", arguments: ["label": snapshot.label]) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                Button("Reject") {
                    Task { _ = await core.tools.invoke(name: "reject_prompt", arguments: ["label": snapshot.label]) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Spacer()
            }
        }
        .padding()
        .background(prompt.isDestructive ? Color.red.opacity(0.08) : Color.yellow.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(prompt.isDestructive ? Color.red : Color.yellow, lineWidth: 1))
    }

    private var recentOutputPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT OUTPUT").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Use \"Open in Terminal\" for the real view").font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(recentText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 180)
            .background(Color(NSColor.textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("Send text to session…", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            Button("Send", action: submit).keyboardShortcut(.return)
        }
    }

    private var recentText: String {
        let lines = core.sessionManager.buffer(for: snapshot.id)?.recent(lines: 30) ?? []
        return lines.joined(separator: "\n")
    }

    private var timeInState: String {
        let secs = Int(Date().timeIntervalSince(snapshot.stateEnteredAt))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs / 3600)h \(secs % 3600 / 60)m"
    }

    private var stateColor: Color {
        switch snapshot.state {
        case .working: return .blue
        case .needsInput: return .yellow
        case .errored, .crashed: return .red
        case .completed: return .green
        default: return .gray
        }
    }

    private func submit() {
        let t = inputText
        guard !t.isEmpty else { return }
        core.sessionManager.sendInput(id: snapshot.id, text: t)
        inputText = ""
    }
}

struct NewSessionSheet: View {
    @Bindable var config: ConfigStore
    let sessionManager: SessionManager
    @Binding var isPresented: Bool

    @State private var label: String = ""
    @State private var directory: String = ""
    @State private var command: String = "claude"
    @State private var args: String = ""
    @State private var errorMsg: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New session").font(.title3).bold()
            let recents = config.recentDirectoriesForDisplay
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent projects").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(recents, id: \.self) { dir in
                                Button {
                                    directory = dir
                                    if label.isEmpty {
                                        label = (dir as NSString).lastPathComponent
                                    }
                                } label: {
                                    Text((dir as NSString).lastPathComponent)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(dir)
                            }
                        }
                    }
                }
            }
            TextField("Label", text: $label)
            HStack {
                TextField("Working directory", text: $directory)
                Button("Choose…") { chooseDirectory() }
            }
            TextField("Command", text: $command)
            TextField("Args (space separated)", text: $args)
            if !errorMsg.isEmpty {
                Text(errorMsg).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Start") { start() }
                    .keyboardShortcut(.return)
                    .disabled(label.isEmpty || directory.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 460)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
            if label.isEmpty { label = url.lastPathComponent }
        }
    }

    private func start() {
        let splitArgs = args.split(separator: " ").map(String.init)
        let cfg = SessionConfig(
            label: label,
            directory: directory,
            command: command,
            args: splitArgs
        )
        config.mutate { $0.sessions.append(cfg) }
        config.recordRecentDirectory(directory)
        do {
            _ = try sessionManager.spawn(sessionConfig: cfg)
            isPresented = false
        } catch {
            errorMsg = error.localizedDescription
            Log.app.error("spawn failed: \(error.localizedDescription)")
        }
    }
}

struct DebugPanel: View {
    let core: AppCore
    @Binding var isPresented: Bool
    @State private var selectedTool: ToolName = .listSessions
    @State private var label: String = ""
    @State private var text: String = ""
    @State private var result: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tool debug panel").font(.title3).bold()
                Spacer()
                Button("Close") { isPresented = false }
            }
            Picker("Tool", selection: $selectedTool) {
                ForEach(ToolName.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            TextField("label", text: $label)
            TextField("text / reason / scope / args", text: $text)
            Button("Invoke") { invoke() }
            ScrollView {
                Text(result).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text("Context feed").font(.headline)
            ScrollView {
                Text(core.contextFeed.render()).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).frame(width: 640, height: 520)
    }

    private func invoke() {
        var args: [String: Any] = [:]
        if !label.isEmpty { args["label"] = label }
        switch selectedTool {
        case .sendInput, .rejectPrompt: args["text"] = text; if !text.isEmpty { args["reason"] = text }
        case .muteNotifications: args["scope"] = label.isEmpty ? "all" : label; args["duration_sec"] = Int(text) ?? 60
        case .setPriority: args["level"] = text.isEmpty ? "normal" : text
        case .scheduleAction: args["action"] = "check"; args["delay_sec"] = Int(text) ?? 30
        case .getRecentOutput: args["lines"] = Int(text) ?? 20
        default: break
        }
        Task { @MainActor in
            let r = await core.tools.invoke(name: selectedTool.rawValue, arguments: args)
            result = r.toJSON()
        }
    }
}
