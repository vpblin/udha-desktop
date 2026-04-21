import Foundation
import AppKit
import Observation

struct ToolResult: Sendable {
    var success: Bool
    var data: [String: Any]
    var spokenSummary: String?

    func toJSON() -> String {
        var payload: [String: Any] = ["success": success]
        payload.merge(data) { _, new in new }
        if let summary = spokenSummary { payload["summary"] = summary }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

@MainActor
final class ToolHandlers {
    let stateStore: SessionStateStore
    let sessionManager: SessionManager
    let notifications: NotificationBus
    let scheduler: ActionScheduler
    let activity: ActivityLog
    let config: ConfigStore
    var slack: SlackManager?

    init(stateStore: SessionStateStore,
         sessionManager: SessionManager,
         notifications: NotificationBus,
         scheduler: ActionScheduler,
         activity: ActivityLog,
         config: ConfigStore) {
        self.stateStore = stateStore
        self.sessionManager = sessionManager
        self.notifications = notifications
        self.scheduler = scheduler
        self.activity = activity
        self.config = config
    }

    func invoke(name: String, arguments: [String: Any]) async -> ToolResult {
        activity.record(.toolCall(name: name, arguments: summarize(arguments)))
        guard let tool = ToolName(rawValue: name) else {
            return ToolResult(success: false, data: ["error": "unknown_tool"], spokenSummary: nil)
        }
        switch tool {
        case .listSessions:      return listSessions()
        case .describeSession:   return describeSession(arguments)
        case .getPendingPrompt:  return getPendingPrompt(arguments)
        case .sendInput:         return sendInput(arguments)
        case .approvePrompt:     return approvePrompt(arguments)
        case .rejectPrompt:      return rejectPrompt(arguments)
        case .showSession:       return showSession(arguments)
        case .muteNotifications: return muteNotifications(arguments)
        case .setPriority:       return setPriority(arguments)
        case .scheduleAction:    return scheduleAction(arguments)
        case .cancelScheduled:   return cancelScheduled(arguments)
        case .getRecentOutput:   return getRecentOutput(arguments)
        case .checkSlack:        return await checkSlack(arguments)
        case .sendSlackMessage:  return await sendSlackMessage(arguments)
        }
    }

    func executeScheduledAction(_ scheduled: ScheduledAction) {
        guard let snap = stateStore.snapshot(id: scheduled.sessionID) else { return }
        switch scheduled.action {
        case "retry":
            sessionManager.sendInput(id: snap.id, text: "/retry")
            notifications.didSpeak(VoiceRequest(text: "retry fired", channel: .system, sessionID: snap.id, urgency: .normal, allowWhenMuted: false))
        case "check":
            break
        default:
            break
        }
    }

    private func listSessions() -> ToolResult {
        let rows = stateStore.all.map { snap -> [String: Any] in
            var row: [String: Any] = [
                "label": snap.label,
                "state": snap.state.rawValue,
                "state_entered_sec_ago": Int(Date().timeIntervalSince(snap.stateEnteredAt)),
                "priority": snap.priority.rawValue,
            ]
            if let summary = snap.recentSummary { row["summary"] = summary }
            if let activity = snap.currentActivity { row["activity"] = activity }
            if snap.pendingPrompt != nil { row["has_pending_prompt"] = true }
            return row
        }
        return ToolResult(success: true, data: ["sessions": rows], spokenSummary: nil)
    }

    private func describeSession(_ args: [String: Any]) -> ToolResult {
        guard let label = args["label"] as? String, let snap = resolve(label: label) else {
            return notFound(label: args["label"] as? String ?? "?")
        }
        var data: [String: Any] = [
            "label": snap.label,
            "state": snap.state.rawValue,
            "seconds_in_state": Int(Date().timeIntervalSince(snap.stateEnteredAt)),
        ]
        if let s = snap.recentSummary { data["summary"] = s }
        if let a = snap.currentActivity { data["activity"] = a }
        if let p = snap.pendingPrompt {
            data["pending_prompt"] = [
                "text": p.text,
                "style": p.style.rawValue,
                "is_destructive": p.isDestructive,
            ]
        }
        if let err = snap.lastErrorMessage { data["last_error"] = err }
        return ToolResult(success: true, data: data, spokenSummary: nil)
    }

    private func getPendingPrompt(_ args: [String: Any]) -> ToolResult {
        guard let label = args["label"] as? String, let snap = resolve(label: label) else {
            return notFound(label: args["label"] as? String ?? "?")
        }
        guard let prompt = snap.pendingPrompt else {
            return ToolResult(success: false, data: ["error": "no_pending_prompt"], spokenSummary: "No pending prompt on \(snap.label).")
        }
        return ToolResult(success: true, data: [
            "text": prompt.text,
            "style": prompt.style.rawValue,
            "is_destructive": prompt.isDestructive,
        ], spokenSummary: nil)
    }

    private func sendInput(_ args: [String: Any]) -> ToolResult {
        guard let label = args["label"] as? String, let snap = resolve(label: label) else {
            return notFound(label: args["label"] as? String ?? "?")
        }
        guard let text = args["text"] as? String else {
            return ToolResult(success: false, data: ["error": "missing_text"], spokenSummary: nil)
        }
        sessionManager.sendInput(id: snap.id, text: text)
        return ToolResult(success: true, data: ["sent": text], spokenSummary: "Sent to \(snap.label).")
    }

    private func approvePrompt(_ args: [String: Any]) -> ToolResult {
        guard let label = args["label"] as? String, let snap = resolve(label: label) else {
            return notFound(label: args["label"] as? String ?? "?")
        }
        guard let prompt = snap.pendingPrompt else {
            return ToolResult(success: false, data: ["error": "no_pending_prompt"], spokenSummary: "No prompt waiting on \(snap.label).")
        }
        let sent = deliverApprove(style: prompt.style, sessionID: snap.id)
        stateStore.update(id: snap.id) { $0.pendingPrompt = nil }
        activity.record(.approvePrompt(sessionID: snap.id, promptText: prompt.text))
        return ToolResult(success: true, data: ["sent": sent], spokenSummary: "Approved \(snap.label).")
    }

    private func rejectPrompt(_ args: [String: Any]) -> ToolResult {
        guard let label = args["label"] as? String, let snap = resolve(label: label) else {
            return notFound(label: args["label"] as? String ?? "?")
        }
        guard let prompt = snap.pendingPrompt else {
            return ToolResult(success: false, data: ["error": "no_pending_prompt"], spokenSummary: "No prompt waiting on \(snap.label).")
        }
        let sent = deliverReject(style: prompt.style, sessionID: snap.id)
        if let reason = args["reason"] as? String, !reason.isEmpty {
            sessionManager.sendInput(id: snap.id, text: reason)
        }
        stateStore.update(id: snap.id) { $0.pendingPrompt = nil }
        activity.record(.rejectPrompt(sessionID: snap.id, promptText: prompt.text, reason: args["reason"] as? String))
        return ToolResult(success: true, data: ["sent": sent], spokenSummary: "Rejected \(snap.label).")
    }

    private func showSession(_ args: [String: Any]) -> ToolResult {
        guard let label = args["label"] as? String, let snap = resolve(label: label) else {
            return notFound(label: args["label"] as? String ?? "?")
        }
        stateStore.focusedSessionID = snap.id
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        return ToolResult(success: true, data: ["focused": snap.label], spokenSummary: "Showing \(snap.label).")
    }

    private func muteNotifications(_ args: [String: Any]) -> ToolResult {
        let scope = (args["scope"] as? String) ?? "all"
        let duration = (args["duration_sec"] as? Int) ?? 1800
        if scope.lowercased() == "all" {
            notifications.muteAll(durationSec: duration)
        } else if let snap = resolve(label: scope) {
            notifications.muteSession(snap.id, durationSec: duration)
        } else {
            return notFound(label: scope)
        }
        activity.record(.mute(scope: scope, durationSec: duration))
        return ToolResult(success: true, data: ["scope": scope, "duration_sec": duration],
                          spokenSummary: "Muted \(scope) for \(duration / 60) minutes.")
    }

    private func setPriority(_ args: [String: Any]) -> ToolResult {
        guard let label = args["label"] as? String, let snap = resolve(label: label) else {
            return notFound(label: args["label"] as? String ?? "?")
        }
        guard let levelStr = args["level"] as? String,
              let level = SessionPriority(rawValue: levelStr) else {
            return ToolResult(success: false, data: ["error": "bad_level"], spokenSummary: nil)
        }
        stateStore.update(id: snap.id) { $0.priority = level }
        config.mutate { cfg in
            if let idx = cfg.sessions.firstIndex(where: { $0.id == snap.id }) {
                cfg.sessions[idx].priority = level
            }
        }
        activity.record(.setPriority(sessionID: snap.id, level: level))
        return ToolResult(success: true, data: ["label": snap.label, "level": levelStr],
                          spokenSummary: "\(snap.label) is \(levelStr) priority.")
    }

    private func scheduleAction(_ args: [String: Any]) -> ToolResult {
        guard let label = args["label"] as? String, let snap = resolve(label: label) else {
            return notFound(label: args["label"] as? String ?? "?")
        }
        guard let action = args["action"] as? String, let delay = args["delay_sec"] as? Int else {
            return ToolResult(success: false, data: ["error": "bad_args"], spokenSummary: nil)
        }
        let id = scheduler.schedule(sessionID: snap.id, action: action, delaySec: delay)
        let fireAt = Date().addingTimeInterval(TimeInterval(delay))
        return ToolResult(success: true, data: ["schedule_id": id.uuidString, "fire_at": isoFormatter.string(from: fireAt)],
                          spokenSummary: "Will \(action) \(snap.label) at \(clockFormatter.string(from: fireAt)).")
    }

    private func cancelScheduled(_ args: [String: Any]) -> ToolResult {
        if let idStr = args["id"] as? String, let id = UUID(uuidString: idStr) {
            scheduler.cancel(id: id)
            return ToolResult(success: true, data: ["cancelled": idStr], spokenSummary: "Cancelled.")
        }
        if let label = args["label"] as? String, let snap = resolve(label: label) {
            let action = (args["action"] as? String) ?? ""
            let match = scheduler.pending.first { $0.sessionID == snap.id && (action.isEmpty || $0.action == action) }
            if let match {
                scheduler.cancel(id: match.id)
                return ToolResult(success: true, data: ["cancelled": match.id.uuidString], spokenSummary: "Cancelled the \(snap.label) \(action).")
            }
        }
        return ToolResult(success: false, data: ["error": "not_found"], spokenSummary: "Nothing to cancel.")
    }

    private func getRecentOutput(_ args: [String: Any]) -> ToolResult {
        guard let label = args["label"] as? String, let snap = resolve(label: label) else {
            return notFound(label: args["label"] as? String ?? "?")
        }
        let count = max(1, min(200, (args["lines"] as? Int) ?? 40))
        // Pull live from tmux scrollback — this survives app restarts and never
        // misses anything the in-memory ring buffer didn't capture.
        if let session = sessionManager.session(for: snap.id) {
            let content = session.captureScrollback(maxLines: count)
            let all = content.components(separatedBy: "\n")
            let taken = Array(all.suffix(count))
            return ToolResult(success: true, data: ["lines": taken], spokenSummary: nil)
        }
        let lines = sessionManager.buffer(for: snap.id)?.recent(lines: count) ?? []
        return ToolResult(success: true, data: ["lines": lines], spokenSummary: nil)
    }

    private func checkSlack(_ args: [String: Any]) async -> ToolResult {
        guard let slack else {
            return ToolResult(
                success: false,
                data: ["error": "slack_not_wired"],
                spokenSummary: "Slack isn't wired up."
            )
        }
        let workspaces = config.config.slack.workspaces
        guard !workspaces.isEmpty else {
            return ToolResult(
                success: true,
                data: [
                    "workspaces": [] as [Any],
                    "messages": [] as [Any],
                    "count": 0,
                ],
                spokenSummary: "You haven't connected any Slack workspaces yet."
            )
        }

        let limit = max(1, min(20, (args["limit"] as? Int) ?? 10))
        let sinceMinutes = max(5, min(10_080, (args["since_minutes"] as? Int) ?? 1440))  // default 24h, max 7d
        let workspaceHint = args["workspace"] as? String
        let from = (args["from"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = (args["channel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Mode: from a specific person → live fetch their DMs
        if let from, !from.isEmpty {
            let msgs = await slack.fetchFromPerson(
                workspaceHint: workspaceHint,
                userQuery: from,
                sinceMinutes: sinceMinutes,
                limit: limit
            )
            return renderFetched(msgs, label: "from \(from)", sinceMinutes: sinceMinutes)
        }

        // Mode: from a channel → live fetch channel history
        if let channel, !channel.isEmpty {
            let msgs = await slack.fetchFromChannel(
                workspaceHint: workspaceHint,
                channelQuery: channel,
                sinceMinutes: sinceMinutes,
                limit: limit
            )
            return renderFetched(msgs, label: "in \(channel)", sinceMinutes: sinceMinutes)
        }

        // Default mode: rolling recaps buffer (fast, since app start)
        let recaps = Array(slack.lastRecaps.suffix(limit).reversed())
        let wsData: [[String: Any]] = workspaces.map { ws in
            [
                "name": ws.teamName,
                "user": ws.userName,
                "enabled": ws.enabled,
                "status": Self.slackStatusString(slack.status[ws.id]),
            ]
        }
        var data: [String: Any] = [
            "workspaces": wsData,
            "recent_recaps": recaps,
            "count": recaps.count,
        ]
        if recaps.isEmpty {
            data["note"] = "No new messages captured since Udha started. To read older messages, call again with 'from: <person's name>' or 'channel: #name'."
        }
        return ToolResult(success: true, data: data, spokenSummary: nil)
    }

    private func renderFetched(_ msgs: [SlackFetchedMessage], label: String, sinceMinutes: Int) -> ToolResult {
        let rows: [[String: Any]] = msgs.map { m in
            [
                "workspace": m.workspaceName,
                "channel": m.channelLabel,
                "sender": m.senderName,
                "text": m.text,
                "ts": m.ts,
            ]
        }
        let windowDesc = sinceMinutes >= 1440
            ? "last \(sinceMinutes / 1440)d"
            : (sinceMinutes >= 60 ? "last \(sinceMinutes / 60)h" : "last \(sinceMinutes)m")
        var data: [String: Any] = [
            "messages": rows,
            "count": rows.count,
            "window": windowDesc,
        ]
        if rows.isEmpty {
            data["note"] = "No messages found \(label) in the \(windowDesc). Could be: wrong name, DM doesn't exist yet, or nothing sent in that window."
        }
        return ToolResult(success: true, data: data, spokenSummary: nil)
    }

    private func sendSlackMessage(_ args: [String: Any]) async -> ToolResult {
        guard let slack else {
            return ToolResult(
                success: false,
                data: ["error": "slack_not_wired"],
                spokenSummary: "Slack isn't wired up."
            )
        }
        guard let recipient = (args["recipient"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !recipient.isEmpty else {
            return ToolResult(
                success: false,
                data: ["error": "missing_recipient"],
                spokenSummary: "I need a recipient — a person's name or a channel."
            )
        }
        guard let text = (args["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return ToolResult(
                success: false,
                data: ["error": "missing_text"],
                spokenSummary: "I need the message text."
            )
        }
        let workspaceHint = args["workspace"] as? String
        do {
            let result = try await slack.sendMessage(
                workspaceHint: workspaceHint,
                recipient: recipient,
                text: text
            )
            let data: [String: Any] = [
                "workspace": result.workspaceName,
                "recipient": result.recipientLabel,
                "channel_id": result.channelID,
                "ts": result.ts,
            ]
            return ToolResult(
                success: true,
                data: data,
                spokenSummary: "Sent to \(result.recipientLabel) in \(result.workspaceName)."
            )
        } catch let err as SlackSendError {
            return ToolResult(
                success: false,
                data: ["error": String(describing: err)],
                spokenSummary: err.errorDescription
            )
        } catch {
            return ToolResult(
                success: false,
                data: ["error": error.localizedDescription],
                spokenSummary: "Slack send failed: \(error.localizedDescription)"
            )
        }
    }

    private static func slackStatusString(_ status: SlackWorkspaceStatus?) -> String {
        switch status {
        case .some(.polling): return "polling"
        case .some(.idle), .none: return "idle"
        case .some(.tokenMissing): return "token_missing"
        case .some(.error(let msg)): return "error: \(msg)"
        }
    }

    private func resolve(label: String) -> SessionSnapshot? {
        stateStore.snapshot(matching: label)
    }

    private func notFound(label: String) -> ToolResult {
        let all = stateStore.all.map { $0.label }.joined(separator: ", ")
        return ToolResult(success: false, data: ["error": "session_not_found", "known": all],
                          spokenSummary: "I don't have a session called \(label).")
    }

    // Routes approve/reject through the right tmux primitive so the prompt
    // actually submits. `sendInput` writes literal text then a separate
    // tmux `Enter` key (CR, 0x0D) — which is what TUIs running in raw mode
    // listen for. Bare `sendRaw` with "\n" goes out as LF (0x0A), which
    // many TUIs (including Claude Code) ignore, so 'y' lands in the input
    // buffer but never submits.
    private func deliverApprove(style: PendingPrompt.Style, sessionID: UUID) -> String {
        switch style {
        case .yesNo, .freeform:
            sessionManager.sendInput(id: sessionID, text: "y")
            return "y⏎"
        case .numbered:
            sessionManager.sendInput(id: sessionID, text: "1")
            return "1⏎"
        case .enterToContinue:
            sessionManager.sendKey(id: sessionID, key: "Enter")
            return "⏎"
        }
    }

    private func deliverReject(style: PendingPrompt.Style, sessionID: UUID) -> String {
        switch style {
        case .yesNo, .freeform:
            sessionManager.sendInput(id: sessionID, text: "n")
            return "n⏎"
        case .numbered:
            sessionManager.sendInput(id: sessionID, text: "2")
            return "2⏎"
        case .enterToContinue:
            sessionManager.sendKey(id: sessionID, key: "C-c")
            return "^C"
        }
    }

    private func summarize(_ args: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private var isoFormatter: ISO8601DateFormatter {
        ISO8601DateFormatter()
    }

    private var clockFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }
}
