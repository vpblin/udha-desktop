import Foundation

struct ClassifierResult: Sendable {
    var state: SessionState?
    var activity: String?
    var pendingPrompt: PendingPrompt?
    var errorMessage: String?
    var completed: Bool = false
}

struct ClaudeCodePatterns {
    // Patterns applied to ONLY the LAST ~15 lines of the pane — the active UI region.
    // Earlier lines contain historical content (tool descriptions, prior responses)
    // that would produce false positives.
    static let needsInputMarkers: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)do\s*you\s*want\s*to\s*proceed"#),
        try! NSRegularExpression(pattern: #"❯\s*\d+\s*\.\s*\S"#),
        try! NSRegularExpression(pattern: #"(?i)this\s*command\s*requires\s*approval"#),
        try! NSRegularExpression(pattern: #"(?i)waiting\s*for\s*your\s*approval"#),
        try! NSRegularExpression(pattern: #"(?i)esc\s*to\s*cancel\s*·\s*tab\s*to\s*amend"#),
        try! NSRegularExpression(pattern: #"(?i)\[y/n\]"#),
        try! NSRegularExpression(pattern: #"(?i)\(y/n\)"#),
        try! NSRegularExpression(pattern: #"(?i)press\s*enter\s*to\s*continue"#),
    ]

    // Working = Claude Code is ACTIVELY processing RIGHT NOW.
    // The reliable signal is "esc to interrupt" (shown during streaming).
    // Bare spinner glyphs (✻ etc) show up in past-tense summaries too, don't trust them.
    static let workingMarkers: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)esc\s*to\s*interrupt"#),
        try! NSRegularExpression(pattern: #"⎿\s*Running"#),
    ]

    // Error markers: require a real error line, not just a keyword in discussion.
    static let errorMarkers: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"^\s*Error:\s"#),
        try! NSRegularExpression(pattern: #"^\s*API\s*Error:\s"#),
        try! NSRegularExpression(pattern: #"(?i)\b(429|500|502|503|504)\s+(Too Many Requests|Server Error|Bad Gateway|Service Unavailable|Gateway Timeout)"#),
        try! NSRegularExpression(pattern: #"(?i)connection\s*refused"#),
        try! NSRegularExpression(pattern: #"^\s*Traceback\b"#),
        try! NSRegularExpression(pattern: #"(?i)^\s*FATAL:"#),
    ]

    static let completedMarkers: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)all\s*tasks\s*completed"#),
        try! NSRegularExpression(pattern: #"✓\s*finished"#),
        try! NSRegularExpression(pattern: #"(?i)✨\s*done"#),
        try! NSRegularExpression(pattern: #"(?i)successfully\s*(deployed|completed|finished|merged|pushed)"#),
    ]

    static let activityExtractors: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"⏺\s*(Read|Bash|Edit|Write|Grep|Glob|WebFetch|WebSearch|Task)\s*\(([^)]{0,120})\)"#),
        try! NSRegularExpression(pattern: #"●\s*(Read|Bash|Edit|Write|Grep|Glob|WebFetch|WebSearch|Task)\s*\(([^)]{0,120})\)"#),
        try! NSRegularExpression(pattern: #"(?i)(Reading|Writing|Editing|Searching|Running|Fetching)\s*\S.{0,100}"#),
    ]
}

struct OutputClassifier {
    let destructiveKeywords: [String]

    func classify(lines: [String]) -> ClassifierResult {
        var result = ClassifierResult()

        // Only check the active UI region — last ~15 lines.
        // Checking more picks up historical text (past responses, tool descriptions)
        // and produces false positives.
        let recentText = lines.suffix(15).joined(separator: "\n")
        let lastLines = lines.suffix(8)

        for pattern in ClaudeCodePatterns.completedMarkers {
            if match(pattern, in: recentText) {
                result.state = .completed
                result.completed = true
                return result
            }
        }

        for pattern in ClaudeCodePatterns.needsInputMarkers {
            if match(pattern, in: recentText) {
                let promptBlock = Self.extractPromptBlock(lines: Array(lastLines))
                let style = Self.detectPromptStyle(recentText)
                let destructive = Self.isDestructive(text: promptBlock, keywords: destructiveKeywords)
                result.state = .needsInput
                result.pendingPrompt = PendingPrompt(
                    text: promptBlock,
                    style: style,
                    isDestructive: destructive,
                    detectedAt: Date()
                )
                return result
            }
        }

        for pattern in ClaudeCodePatterns.errorMarkers {
            if let hit = firstMatch(pattern, in: recentText) {
                result.state = .errored
                result.errorMessage = hit
                return result
            }
        }

        for pattern in ClaudeCodePatterns.workingMarkers {
            if match(pattern, in: recentText) {
                result.state = .working
                for extractor in ClaudeCodePatterns.activityExtractors {
                    if let activity = firstMatch(extractor, in: recentText) {
                        result.activity = activity.trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
                return result
            }
        }

        return result
    }

    private func match(_ pattern: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.firstMatch(in: text, options: [], range: range) != nil
    }

    private func firstMatch(_ pattern: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = pattern.firstMatch(in: text, options: [], range: range),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    private static func extractPromptBlock(lines: [String]) -> String {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return cleaned.joined(separator: " ")
    }

    private static func detectPromptStyle(_ text: String) -> PendingPrompt.Style {
        // Claude Code's selection menu: "❯ 1. Yes" or the space-collapsed "❯1.Yes".
        // Checking the ❯ form first is reliable; the bare "\d+\.\s" fallback
        // misses the collapsed case and misroutes to .yesNo (sending "y" which
        // Claude Code's numbered menu ignores).
        if text.range(of: #"❯\s*\d+\s*\.\s*\S"#, options: .regularExpression) != nil {
            return .numbered
        }
        if text.range(of: #"\d+\.\s"#, options: .regularExpression) != nil {
            return .numbered
        }
        if text.range(of: #"(?i)\[y/n\]|\(y/n\)|\byes\b|\bno\b"#, options: .regularExpression) != nil {
            return .yesNo
        }
        if text.range(of: #"(?i)press enter"#, options: .regularExpression) != nil {
            return .enterToContinue
        }
        return .freeform
    }

    static func isDestructive(text: String, keywords: [String]) -> Bool {
        let lower = text.lowercased()
        return keywords.contains(where: { lower.contains($0.lowercased()) })
    }
}
