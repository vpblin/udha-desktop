import Foundation
import Observation

struct ScheduledAction: Identifiable, Hashable, Sendable {
    let id: UUID
    let sessionID: UUID
    let action: String
    let fireAt: Date
    let args: [String: String]
}

@MainActor
@Observable
final class ActionScheduler {
    let activity: ActivityLog
    weak var tools: ToolHandlers?
    private(set) var pending: [ScheduledAction] = []
    private var timers: [UUID: DispatchSourceTimer] = [:]

    init(activity: ActivityLog) {
        self.activity = activity
    }

    @discardableResult
    func schedule(sessionID: UUID, action: String, delaySec: Int, args: [String: String] = [:]) -> UUID {
        let id = UUID()
        let fireAt = Date().addingTimeInterval(TimeInterval(delaySec))
        let scheduled = ScheduledAction(id: id, sessionID: sessionID, action: action, fireAt: fireAt, args: args)
        pending.append(scheduled)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + TimeInterval(delaySec), repeating: .never)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.fire(id: id) }
        }
        timer.resume()
        timers[id] = timer

        activity.record(.scheduleAction(sessionID: sessionID, action: action, fireAt: fireAt, scheduleID: id))
        return id
    }

    func cancel(id: UUID) {
        timers[id]?.cancel()
        timers.removeValue(forKey: id)
        pending.removeAll { $0.id == id }
        activity.record(.cancelScheduled(scheduleID: id))
    }

    private func fire(id: UUID) {
        guard let scheduled = pending.first(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        timers.removeValue(forKey: id)
        tools?.executeScheduledAction(scheduled)
    }
}
