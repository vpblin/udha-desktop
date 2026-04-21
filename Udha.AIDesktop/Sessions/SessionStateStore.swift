import Foundation
import Observation

@MainActor
@Observable
final class SessionStateStore {
    private(set) var snapshots: [UUID: SessionSnapshot] = [:]
    private(set) var orderedIDs: [UUID] = []
    var focusedSessionID: UUID?

    var all: [SessionSnapshot] {
        orderedIDs.compactMap { snapshots[$0] }
    }

    var active: [SessionSnapshot] {
        all.filter { $0.state != .exited && $0.state != .crashed }
    }

    func snapshot(id: UUID) -> SessionSnapshot? {
        snapshots[id]
    }

    func snapshot(matching label: String) -> SessionSnapshot? {
        let target = label.lowercased()
        let exact = all.first { $0.label.lowercased() == target }
        if let exact { return exact }
        let prefixMatches = all.filter { $0.label.lowercased().hasPrefix(target) }
        return prefixMatches.count == 1 ? prefixMatches.first : nil
    }

    func matches(label: String) -> [SessionSnapshot] {
        let target = label.lowercased()
        return all.filter { $0.label.lowercased().contains(target) }
    }

    func insert(_ snapshot: SessionSnapshot) {
        if snapshots[snapshot.id] == nil {
            orderedIDs.append(snapshot.id)
        }
        snapshots[snapshot.id] = snapshot
    }

    func remove(id: UUID) {
        snapshots.removeValue(forKey: id)
        orderedIDs.removeAll { $0 == id }
        if focusedSessionID == id { focusedSessionID = nil }
    }

    func update(id: UUID, _ block: (inout SessionSnapshot) -> Void) {
        guard var snap = snapshots[id] else { return }
        block(&snap)
        snapshots[id] = snap
    }

    func transition(id: UUID, to newState: SessionState) -> Bool {
        guard var snap = snapshots[id] else { return false }
        guard snap.state != newState else { return false }
        snap.state = newState
        snap.stateEnteredAt = Date()
        snapshots[id] = snap
        return true
    }

    func recordSpoken(id: UUID, text: String) {
        update(id: id) { $0.lastSpoken = SpokenRecord(text: text, at: Date()) }
    }
}
