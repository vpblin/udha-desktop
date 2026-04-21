import SwiftUI

struct MenuBarStatusView: View {
    let voice: VoiceController
    @Bindable var stateStore: SessionStateStore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(voice.isListening ? Color.red : iconColor)
                .frame(width: 10, height: 10)
            Text(statusText).font(.system(size: 11, weight: .medium))
        }
    }

    private var needsCount: Int { stateStore.all.filter { $0.state == .needsInput }.count }
    private var errorCount: Int { stateStore.all.filter { $0.state == .errored }.count }
    private var activeCount: Int { stateStore.active.count }

    private var iconColor: Color {
        if errorCount > 0 { return .orange }
        if needsCount > 0 { return .yellow }
        if activeCount > 0 { return .green }
        return .secondary
    }

    private var statusText: String {
        if voice.isListening { return "listening" }
        if needsCount > 0 { return "\(needsCount) waiting" }
        if errorCount > 0 { return "\(errorCount) err" }
        return "Udha"
    }
}

struct MenuBarContent: View {
    let core: AppCore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                core.voice.toggle()
            } label: {
                HStack {
                    Circle()
                        .fill(core.voice.isListening ? Color.red : Color.secondary)
                        .frame(width: 10, height: 10)
                    Text(core.voice.isListening ? "Stop listening" : "Start listening")
                    Spacer()
                    Text("⌘K").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Divider()

            ForEach(core.stateStore.all) { snap in
                HStack {
                    Circle().fill(color(for: snap.state)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snap.label).font(.system(size: 12))
                        Text(snap.state.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show") {
                        core.sessionManager.showSession(id: snap.id)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            }

            let recents = core.config.recentDirectoriesForDisplay
            if !recents.isEmpty {
                Divider()
                Text("Recent projects").font(.caption2).foregroundStyle(.secondary)
                ForEach(recents, id: \.self) { dir in
                    Button {
                        spawnRecent(dir)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.caption2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((dir as NSString).lastPathComponent).font(.system(size: 12))
                                Text(shortPath(dir)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(dir)
                }
            }

            Divider()
            Button("Show Udha Window") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(10)
        .frame(minWidth: 300)
    }

    private func spawnRecent(_ dir: String) {
        let base = (dir as NSString).lastPathComponent
        let label = uniqueLabel(base: base.isEmpty ? "session" : base)
        let cfg = SessionConfig(label: label, directory: dir, command: "claude", args: [])
        core.config.mutate { $0.sessions.append(cfg) }
        core.config.recordRecentDirectory(dir)
        do {
            _ = try core.sessionManager.spawn(sessionConfig: cfg)
        } catch {
            Log.app.error("menu-bar recent spawn failed for \(dir): \(error.localizedDescription)")
        }
    }

    private func uniqueLabel(base: String) -> String {
        let existing = Set(core.config.config.sessions.map { $0.label.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)".lowercased()) { n += 1 }
        return "\(base)-\(n)"
    }

    private func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func color(for state: SessionState) -> Color {
        switch state {
        case .working: return .blue
        case .needsInput: return .yellow
        case .errored: return .red
        case .completed: return .green
        case .idle, .starting: return .gray
        case .exited, .crashed: return .secondary
        }
    }
}
