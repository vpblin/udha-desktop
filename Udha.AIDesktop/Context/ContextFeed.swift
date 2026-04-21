import Foundation

@MainActor
final class ContextFeed {
    let stateStore: SessionStateStore
    let notifications: NotificationBus
    weak var sessionManager: SessionManager?

    init(stateStore: SessionStateStore, notifications: NotificationBus) {
        self.stateStore = stateStore
        self.notifications = notifications
    }

    func render(maxRecentAnnouncements: Int = 6) -> String {
        var out = "## Current sessions\n"
        if stateStore.all.isEmpty {
            out += "- (no sessions configured)\n"
        }
        for snap in stateStore.all {
            out += "- \(snap.label) [\(snap.state.rawValue.uppercased()), \(formatDuration(Date().timeIntervalSince(snap.stateEnteredAt)))]: "
            switch snap.state {
            case .needsInput:
                if let prompt = snap.pendingPrompt {
                    out += "Prompt — \(shortened(prompt.text, 160))"
                    if prompt.isDestructive { out += " [DESTRUCTIVE]" }
                    out += ". Full text via get_pending_prompt."
                } else {
                    out += "Awaiting input."
                }
            case .errored:
                out += "Error — \(shortened(snap.lastErrorMessage ?? "unknown", 140))"
            case .working:
                if let summary = snap.recentSummary, !summary.isEmpty {
                    out += summary
                } else if let activity = snap.currentActivity, !activity.isEmpty {
                    out += activity
                } else {
                    out += "Working."
                }
            case .idle:
                out += "Idle."
            case .starting:
                out += "Starting up."
            case .completed:
                out += "Completed."
            case .exited:
                out += "Exited (code \(snap.exitCode ?? 0))."
            case .crashed:
                out += "Crashed."
            }
            if let spoken = snap.lastSpoken {
                out += " Last spoken \(formatDuration(Date().timeIntervalSince(spoken.at))) ago."
            }
            out += "\n"

            // Short recent-output excerpt per session (last 6 non-empty lines)
            if let sm = sessionManager, let session = sm.session(for: snap.id) {
                let content = session.captureScrollback(maxLines: 20)
                let lines = content.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .suffix(6)
                if !lines.isEmpty {
                    out += "  recent:\n"
                    for line in lines {
                        let safe = shortened(line, 180)
                        out += "    | \(safe)\n"
                    }
                }
            }
        }

        if let muteUntil = notifications.muteUntil, muteUntil > Date() {
            out += "\n## Notification state\nGlobally muted until \(formatClock(muteUntil)).\n"
        }

        if let focused = stateStore.focusedSessionID,
           let snap = stateStore.snapshot(id: focused) {
            out += "\n## User's focused session\n\(snap.label)\n"
        } else {
            out += "\n## User's focused session\n(none)\n"
        }

        return out
    }

    private func shortened(_ s: String, _ n: Int) -> String {
        if s.count <= n { return s }
        let idx = s.index(s.startIndex, offsetBy: n)
        return String(s[..<idx]) + "…"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m \(s%60)s" }
        return "\(s/3600)h \(s%3600/60)m"
    }

    private func formatClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        return formatter.string(from: date)
    }
}
