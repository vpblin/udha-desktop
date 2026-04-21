import SwiftUI

struct SlackSettingsView: View {
    @Bindable var config: ConfigStore
    let manager: SlackManager

    @State private var newToken: String = ""
    @State private var isAdding: Bool = false
    @State private var message: String = ""

    var body: some View {
        Form {
            Section("Connected workspaces") {
                if config.config.slack.workspaces.isEmpty {
                    Text("No workspaces connected yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(config.config.slack.workspaces) { ws in
                        workspaceRow(ws)
                    }
                }
            }

            Section("Add a workspace") {
                SecureField("User OAuth token (xoxp-…)", text: $newToken)
                HStack {
                    Button(isAdding ? "Adding…" : "Add") {
                        Task { await addWorkspace() }
                    }
                    .disabled(newToken.isEmpty || isAdding)
                    if !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(message.hasPrefix("Error") ? .red : .secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create a Slack app at api.slack.com/apps, add these User Token Scopes, install to your workspace, then paste the User OAuth Token here.")
                    Text("READ scopes: channels:history, groups:history, im:history, mpim:history, users:read")
                    Text("SEND scopes: chat:write, im:write")
                    Text("After changing scopes you must Reinstall to Workspace.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Announcement rules") {
                Toggle("Announce DMs", isOn: Binding(
                    get: { config.config.slack.announceDMs },
                    set: { new in config.mutate { $0.slack.announceDMs = new }; manager.refreshPollers() }
                ))
                Toggle("Announce @-mentions in channels", isOn: Binding(
                    get: { config.config.slack.announceMentions },
                    set: { new in config.mutate { $0.slack.announceMentions = new }; manager.refreshPollers() }
                ))
                Toggle("Announce every channel message (spammy)", isOn: Binding(
                    get: { config.config.slack.announceAllChannelMessages },
                    set: { new in config.mutate { $0.slack.announceAllChannelMessages = new }; manager.refreshPollers() }
                ))
                Toggle("Use Claude to recap (off = plain template)", isOn: Binding(
                    get: { config.config.slack.summarize },
                    set: { new in config.mutate { $0.slack.summarize = new } }
                ))
                Stepper(
                    "Poll every: \(config.config.slack.pollIntervalSec)s",
                    value: Binding(
                        get: { config.config.slack.pollIntervalSec },
                        set: { new in config.mutate { $0.slack.pollIntervalSec = new } }
                    ),
                    in: 10...300,
                    step: 5
                )
            }

            if !manager.lastRecaps.isEmpty {
                Section("Recent recaps") {
                    ForEach(Array(manager.lastRecaps.suffix(5).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func workspaceRow(_ ws: SlackWorkspaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ws.teamName).bold()
                    Text("@\(ws.userName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let status = manager.status[ws.id] {
                        Text(statusLabel(status))
                            .font(.caption2)
                            .foregroundStyle(statusColor(status))
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { ws.enabled },
                    set: { new in manager.setEnabled(teamID: ws.teamID, enabled: new) }
                ))
                .labelsHidden()
                Button("Recheck") {
                    Task { await manager.refreshMissingScopes(for: ws) }
                }
                Button("Remove", role: .destructive) {
                    manager.removeWorkspace(teamID: ws.teamID)
                }
            }
            if let missing = manager.missingScopes[ws.teamID], !missing.isEmpty {
                Text("⚠︎ Missing scopes: \(missing.sorted().joined(separator: ", ")) — add them in your Slack app, then Reinstall to Workspace.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func statusLabel(_ s: SlackWorkspaceStatus) -> String {
        switch s {
        case .idle: return "idle"
        case .polling: return "polling"
        case .tokenMissing: return "token missing — re-add"
        case .error(let msg): return "error: \(msg)"
        }
    }

    private func statusColor(_ s: SlackWorkspaceStatus) -> Color {
        switch s {
        case .polling: return .green
        case .idle: return .secondary
        case .tokenMissing, .error: return .red
        }
    }

    private func addWorkspace() async {
        isAdding = true
        defer { isAdding = false }
        message = ""
        do {
            let ws = try await manager.addWorkspace(userToken: newToken)
            message = "Connected \(ws.teamName) (@\(ws.userName))."
            newToken = ""
        } catch {
            message = "Error: \(error.localizedDescription)"
        }
    }
}
