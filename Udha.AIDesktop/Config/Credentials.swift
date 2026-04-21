import Foundation

enum BootstrapCredentials {
    static let openRouterKey = "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"
    static let elevenLabsKey = "sk_24f26a5f2502dbaf03d1150cee207802bdd04d5a7cdb5627"
    static let elevenLabsAgentID = "agent_4701kpbrzqd3ft7s8yxqmzzprkf3"
    static let elevenLabsVoiceID = "LZAcK8Cx5QjdQhfBsJQZ"

    static func seed(keychain: KeychainStore, config: ConfigStore) {
        if keychain.get(.openRouterAPIKey)?.isEmpty != false {
            try? keychain.set(openRouterKey, for: .openRouterAPIKey)
        }
        if keychain.get(.elevenLabsAPIKey)?.isEmpty != false {
            try? keychain.set(elevenLabsKey, for: .elevenLabsAPIKey)
        }
        if keychain.get(.elevenLabsAgentID)?.isEmpty != false {
            try? keychain.set(elevenLabsAgentID, for: .elevenLabsAgentID)
        }
        if keychain.get(.elevenLabsVoiceID)?.isEmpty != false {
            try? keychain.set(elevenLabsVoiceID, for: .elevenLabsVoiceID)
        }
        config.mutate { cfg in
            if cfg.voice.elevenLabsAgentID.isEmpty { cfg.voice.elevenLabsAgentID = elevenLabsAgentID }
            if cfg.voice.elevenLabsVoiceID.isEmpty { cfg.voice.elevenLabsVoiceID = elevenLabsVoiceID }
            cfg.hasCompletedFirstRun = true
        }
    }
}
