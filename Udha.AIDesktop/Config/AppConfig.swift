import Foundation

struct SessionConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var label: String
    var directory: String
    var command: String = "claude"
    var args: [String] = []
    var env: [String: String] = [:]
    var priority: SessionPriority = .normal
    var enabled: Bool = true
    var autoApprove: Bool = false
}

enum SessionPriority: String, Codable, Hashable {
    case normal
    case high
}

struct VoiceConfig: Codable, Hashable {
    var elevenLabsAgentID: String = ""
    var elevenLabsVoiceID: String = "LZAcK8Cx5QjdQhfBsJQZ"
    var ttsModel: String = "eleven_flash_v2_5"
    var pushToTalkHotkey: HotkeyBinding = .default
    var pushToTalkMode: PushToTalkMode = .hold
    var volume: Double = 0.8
    var inputSampleRate: Int = 16000
    var outputSampleRate: Int = 16000
    var inputDeviceUID: String = ""
    var outputDeviceUID: String = ""
}

enum PushToTalkMode: String, Codable, Hashable {
    case hold
    case toggle
}

struct HotkeyBinding: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = HotkeyBinding(keyCode: 49, modifiers: 0x100 | 0x200) // ⌘⇧Space
}

struct NotificationsConfig: Codable, Hashable {
    var perSessionCooldownSec: Int = 15
    var globalCooldownSec: Int = 3
    var quietHoursStart: String = "22:00"
    var quietHoursEnd: String = "08:00"
    var quietHoursAllowUrgency: NotificationUrgency = .high
    var suppressFocusedSession: Bool = false
    var destructiveKeywords: [String] = [
        "drop", "delete", "deploy", "production", "rm -rf", "force push",
        "truncate", "format", "destroy", "purge"
    ]
    var maxDailyTTSCharacters: Int = 50_000
}

enum NotificationUrgency: String, Codable, Hashable {
    case low, normal, high
}

struct ClassifierConfig: Codable, Hashable {
    var useHaiku: Bool = true
    var model: String = "anthropic/claude-haiku-4-5"
    var summaryIntervalSec: Int = 30
    var openRouterBaseURL: String = "https://openrouter.ai/api/v1"
}

struct OverlayConfig: Codable, Hashable {
    var enabled: Bool = true
    var edge: OverlayEdge = .right
    var labelMode: OverlayLabelMode = .onHover
    var triggerWidth: Double = 14
    var hoverFocusDelayMs: Int = 180
    var hideMainWindowOnLaunch: Bool = false
}

enum OverlayEdge: String, Codable, Hashable { case left, right }
enum OverlayLabelMode: String, Codable, Hashable { case onHover, always, never }

struct SlackWorkspaceRecord: Codable, Hashable, Identifiable {
    var teamID: String
    var teamName: String
    var teamDomain: String
    var userID: String
    var userName: String
    var addedAt: Date = Date()
    var enabled: Bool = true

    var id: String { teamID }
    var keychainAccount: String { "slack_token_\(teamID)" }
}

struct SlackConfig: Codable, Hashable {
    var workspaces: [SlackWorkspaceRecord] = []
    var pollIntervalSec: Int = 20
    var announceDMs: Bool = true
    var announceMentions: Bool = true
    var announceAllChannelMessages: Bool = false
    var summarize: Bool = true
    var summarizerModel: String = "anthropic/claude-haiku-4-5"
}

struct AppConfig: Codable, Hashable {
    var version: Int = 2
    var sessions: [SessionConfig] = []
    var voice: VoiceConfig = VoiceConfig()
    var notifications: NotificationsConfig = NotificationsConfig()
    var classifier: ClassifierConfig = ClassifierConfig()
    var overlay: OverlayConfig = OverlayConfig()
    var slack: SlackConfig = SlackConfig()
    var recentDirectories: [String] = []
    var hasCompletedFirstRun: Bool = false
}
