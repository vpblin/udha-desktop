import Foundation

enum SessionState: String, Codable, Hashable, Sendable {
    case starting
    case idle
    case working
    case needsInput
    case errored
    case completed
    case exited
    case crashed
}

struct PendingPrompt: Hashable, Sendable {
    enum Style: String, Hashable, Sendable {
        case yesNo        // y/n
        case numbered     // 1/2/3
        case enterToContinue
        case freeform
    }
    var text: String
    var style: Style
    var isDestructive: Bool
    var detectedAt: Date
}

struct SpokenRecord: Hashable, Sendable {
    var text: String
    var at: Date
}

struct SessionSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    var label: String
    var directory: String
    var state: SessionState
    var stateEnteredAt: Date
    var currentActivity: String?
    var recentSummary: String?
    var pendingPrompt: PendingPrompt?
    var lastErrorMessage: String?
    var lastSpoken: SpokenRecord?
    var priority: SessionPriority
    var exitCode: Int32?
}
