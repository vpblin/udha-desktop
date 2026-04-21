import Foundation
import Observation

enum VoiceChannel: String, Sendable {
    case proactive
    case conversational
    case system
}

struct VoiceRequest: Identifiable, Sendable {
    let id: UUID = UUID()
    let text: String
    let channel: VoiceChannel
    let sessionID: UUID?
    let urgency: NotificationUrgency
    let createdAt: Date = Date()
    let allowWhenMuted: Bool
}

@MainActor
@Observable
final class NotificationBus {
    let stateStore: SessionStateStore
    let config: ConfigStore

    private(set) var lastGlobalSpeakAt: Date?
    private var lastPerSessionSpeakAt: [UUID: Date] = [:]

    private(set) var muteUntil: Date?
    private var mutedSessionsUntil: [UUID: Date] = [:]
    var focusedSessionID: UUID? { stateStore.focusedSessionID }

    init(stateStore: SessionStateStore, config: ConfigStore) {
        self.stateStore = stateStore
        self.config = config
    }

    func shouldSpeak(_ request: VoiceRequest) -> Bool {
        let now = Date()
        if isGloballyMuted(now: now, urgency: request.urgency) {
            if !request.allowWhenMuted { return false }
        }
        if let sessionID = request.sessionID {
            if let until = mutedSessionsUntil[sessionID], until > now, request.urgency != .high {
                return false
            }
            if config.config.notifications.suppressFocusedSession,
               focusedSessionID == sessionID,
               request.urgency != .high {
                return false
            }
        }
        if let last = lastGlobalSpeakAt,
           now.timeIntervalSince(last) < TimeInterval(config.config.notifications.globalCooldownSec),
           request.urgency != .high {
            return false
        }
        if let sessionID = request.sessionID,
           let last = lastPerSessionSpeakAt[sessionID],
           now.timeIntervalSince(last) < TimeInterval(config.config.notifications.perSessionCooldownSec),
           request.urgency != .high {
            return false
        }
        if inQuietHours(now: now) && request.urgency != .high {
            return false
        }
        return true
    }

    func didSpeak(_ request: VoiceRequest) {
        let now = Date()
        lastGlobalSpeakAt = now
        if let sid = request.sessionID { lastPerSessionSpeakAt[sid] = now }
    }

    func muteAll(durationSec: Int) {
        muteUntil = Date().addingTimeInterval(TimeInterval(durationSec))
    }

    func unmuteAll() {
        muteUntil = nil
    }

    func muteSession(_ id: UUID, durationSec: Int) {
        mutedSessionsUntil[id] = Date().addingTimeInterval(TimeInterval(durationSec))
    }

    func unmuteSession(_ id: UUID) {
        mutedSessionsUntil.removeValue(forKey: id)
    }

    private func isGloballyMuted(now: Date, urgency: NotificationUrgency) -> Bool {
        if let until = muteUntil, until > now, urgency != .high {
            return true
        }
        return false
    }

    private func inQuietHours(now: Date) -> Bool {
        let cfg = config.config.notifications
        guard let (startH, startM) = parseHM(cfg.quietHoursStart),
              let (endH, endM) = parseHM(cfg.quietHoursEnd) else { return false }
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let cur = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let start = startH * 60 + startM
        let end = endH * 60 + endM
        return start > end ? (cur >= start || cur < end) : (cur >= start && cur < end)
    }

    private func parseHM(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return (h, m)
    }
}
