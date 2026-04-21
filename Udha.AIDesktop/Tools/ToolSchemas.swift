import Foundation

enum ToolName: String, CaseIterable, Sendable {
    case listSessions = "list_sessions"
    case describeSession = "describe_session"
    case getPendingPrompt = "get_pending_prompt"
    case sendInput = "send_input"
    case approvePrompt = "approve_prompt"
    case rejectPrompt = "reject_prompt"
    case showSession = "show_session"
    case muteNotifications = "mute_notifications"
    case setPriority = "set_priority"
    case scheduleAction = "schedule_action"
    case cancelScheduled = "cancel_scheduled"
    case getRecentOutput = "get_recent_output"
    case checkSlack = "check_slack"
    case sendSlackMessage = "send_slack_message"
}

enum ToolSchemas {
    static func allForElevenLabsAgent() -> [[String: Any]] {
        [
            tool(
                name: .listSessions,
                description: "Returns a compact list of all current sessions with state and basic info. Call only if context feed missing.",
                parameters: [:],
                required: []
            ),
            tool(
                name: .describeSession,
                description: "Returns full detail for a session: recent summary, current activity, pending prompt if any.",
                parameters: ["label": ["type": "string", "description": "Session label (case-insensitive)."]],
                required: ["label"]
            ),
            tool(
                name: .getPendingPrompt,
                description: "Returns the full text of a session's current permission prompt.",
                parameters: ["label": ["type": "string"]],
                required: ["label"]
            ),
            tool(
                name: .sendInput,
                description: "Types the given text plus newline into the session's stdin.",
                parameters: [
                    "label": ["type": "string"],
                    "text": ["type": "string", "description": "Text to send, without trailing newline."],
                ],
                required: ["label", "text"]
            ),
            tool(
                name: .approvePrompt,
                description: "Smart approve — detects y/n, 1/2/3, or enter-to-continue and sends the right response. MUST double-confirm verbally before calling if prompt is destructive.",
                parameters: ["label": ["type": "string"]],
                required: ["label"]
            ),
            tool(
                name: .rejectPrompt,
                description: "Smart reject. Optional reason is sent as a follow-up instruction after the rejection.",
                parameters: [
                    "label": ["type": "string"],
                    "reason": ["type": "string", "description": "Optional reason or follow-up instruction."],
                ],
                required: ["label"]
            ),
            tool(
                name: .showSession,
                description: "Brings the app window to focus and selects this session's terminal.",
                parameters: ["label": ["type": "string"]],
                required: ["label"]
            ),
            tool(
                name: .muteNotifications,
                description: "Silences proactive notifications for a scope and duration.",
                parameters: [
                    "scope": ["type": "string", "description": "'all' or a session label."],
                    "duration_sec": ["type": "integer", "description": "Duration in seconds."],
                ],
                required: ["scope", "duration_sec"]
            ),
            tool(
                name: .setPriority,
                description: "Set a session to 'normal' or 'high' priority. High priority speaks even when focused.",
                parameters: [
                    "label": ["type": "string"],
                    "level": ["type": "string", "enum": ["normal", "high"]],
                ],
                required: ["label", "level"]
            ),
            tool(
                name: .scheduleAction,
                description: "Schedule a 'retry' or 'check' action for a session after N seconds.",
                parameters: [
                    "label": ["type": "string"],
                    "action": ["type": "string", "enum": ["retry", "check"]],
                    "delay_sec": ["type": "integer"],
                ],
                required: ["label", "action", "delay_sec"]
            ),
            tool(
                name: .cancelScheduled,
                description: "Cancel a scheduled action by its ID or by label+action.",
                parameters: [
                    "id": ["type": "string"],
                    "label": ["type": "string"],
                    "action": ["type": "string"],
                ],
                required: []
            ),
            tool(
                name: .getRecentOutput,
                description: "Fetch the last N lines of raw terminal output for a session. Use sparingly.",
                parameters: [
                    "label": ["type": "string"],
                    "lines": ["type": "integer", "description": "1-100"],
                ],
                required: ["label"]
            ),
            tool(
                name: .checkSlack,
                description: "Check Slack messages. Three modes. (1) No filter args: returns one-sentence recaps of DMs and @-mentions Udha captured since launch. (2) With 'from': live-fetches actual recent DMs from that person — use this when user asks 'what did Scott say' or 'read Molly's messages'. (3) With 'channel': live-fetches channel history. Modes 2 and 3 bypass the in-memory buffer and query Slack directly, so they see older messages.",
                parameters: [
                    "from": ["type": "string", "description": "Person's name or handle to fetch DMs from (e.g. 'Molly', 'scott@acme.com', or 'U12345')."],
                    "channel": ["type": "string", "description": "Channel name or ID to read from (e.g. '#exec' or 'exec-team')."],
                    "since_minutes": ["type": "integer", "description": "How far back to look, in minutes. Default 1440 (24h). Max 10080 (7d)."],
                    "limit": ["type": "integer", "description": "Max messages / recaps to return, 1-20. Default 10."],
                    "workspace": ["type": "string", "description": "Workspace name to restrict to. Optional; omit to search all connected workspaces."],
                ],
                required: []
            ),
            tool(
                name: .sendSlackMessage,
                description: "Send a Slack message as the user to a person or channel in a connected workspace. MUST repeat the recipient, workspace, and message text back to the user and get explicit spoken confirmation ('yes', 'send it', 'go ahead') BEFORE calling this tool. Never call without confirmation. If the user corrects anything, re-confirm.",
                parameters: [
                    "recipient": [
                        "type": "string",
                        "description": "Who to send to: a person's name (e.g. 'Scott'), a display name, an email, a channel like '#exec-team', or a raw Slack ID (U…/C…/D…).",
                    ],
                    "text": [
                        "type": "string",
                        "description": "The message text to send, exactly as it should appear.",
                    ],
                    "workspace": [
                        "type": "string",
                        "description": "Workspace name or domain to send from. Optional if only one workspace is connected.",
                    ],
                ],
                required: ["recipient", "text"]
            ),
        ]
    }

    private static func tool(name: ToolName, description: String, parameters: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "client",
            "name": name.rawValue,
            "description": description,
            "parameters": [
                "type": "object",
                "properties": parameters,
                "required": required,
            ],
        ]
    }
}
