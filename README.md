# Udha.AIDesktop

A native macOS app that supervises long-running AI coding sessions (Claude Code and other tmux-resident tools), surfaces their state in a right-edge hover overlay, and narrates status through voice. SwiftUI + AppKit, macOS 13+.

## What it does

- Spawns each session inside a named tmux session, tailing output over a log pipe.
- Classifies output in real time: `idle`, `working`, `needsInput`, `errored`, `completed`, `crashed`, `starting`, `exited`.
- Shows a half-disc overlay on the right edge of the screen. Hover the edge to bloom; hover a session pill to bring its Terminal window forward.
- Speaks state transitions through ElevenLabs TTS, and lets you talk back via an ElevenLabs ConvAI WebSocket.
- An LLM (Claude Haiku via OpenRouter) writes short live summaries while sessions are working.
- Optional Slack announcements for DMs and mentions, summarized by Haiku.

## Requirements

- macOS 13 or later (Apple Silicon).
- Xcode 15+.
- `tmux` on `$PATH` — install via `brew install tmux`. The app looks in `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, and `/usr/bin/tmux`.
- An ElevenLabs account with TTS + ConvAI enabled (optional, but the voice UX depends on it).
- An OpenRouter API key (optional; used for Haiku summaries and Slack summarization).

## Build & run

1. Open `Udha.AIDesktop.xcodeproj` in Xcode.
2. Select the `Udha.AIDesktop` scheme.
3. Run. First launch walks through onboarding (keychain seeding, voice agent, permissions for Terminal Apple Events and microphone).

Only Swift Package dependency: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (≥ 1.2).

## Configuration

- User config lives at `~/Library/Application Support/Udha.AI/config.json`. Missing fields fall back to defaults; broken files are backed up on load.
- Secrets live in the macOS Keychain under service `solutions.amk.Udha-AIDesktop`. Expected accounts include `openRouter.apiKey`, `elevenLabs.apiKey`, and agent IDs.
- Logs: `~/Library/Logs/Udha.AI/udha.log` plus the usual `os.Logger` subsystem `solutions.amk.Udha-AIDesktop`.

## Architecture

```
Udha.AIDesktop/
  Udha_AIDesktopApp.swift   @main entry; declares scenes.
  App/                      AppCore, AppDelegate, RootView.
  Overlay/                  The right-edge hover UI.
  Sessions/                 tmux glue + state store + rule-based classifier.
  Classifier/               Haiku summarizer + OpenRouter client.
  Voice/                    Mic capture, playback, TTS, proactive engine, ConvAI agent.
  Tools/                    JSON tool schemas the voice agent can call.
  Context/                  ContextFeed — rendered prompt seen by the agent.
  Scheduler/                Deferred action queue.
  Activity/                 Append-only in-memory activity log.
  Slack/                    Slack polling + announcement piping into the voice engine.
  Config/                   AppConfig struct, JSON store, Keychain wrapper.
  Menu/                     MenuBarExtra views.
  Settings/                 Tabbed SettingsView.
  Onboarding/               First-run flow.
  Shared/                   Logger.
```

### State lifecycle

```
spawn → .starting → .idle ⇄ .working ⇄ .needsInput
                              ↘
                                .errored / .crashed / .completed / .exited
```

Transitions fire the `ProactiveVoiceEngine`, which may enqueue a spoken sentence subject to per-session cooldowns, global cooldowns, and quiet hours. The engine is fully gated on the voice-on toggle — turning the mic off silences all speech.

### Auto-approve

Sessions can be flagged `autoApprove`. When a non-destructive prompt is detected, `SessionManager.maybeAutoApprove` sends the appropriate response (`y`, `1`, or Enter) and the voice engine skips the approval announcement. Destructive prompts (configurable keywords like `drop`, `rm -rf`, `force push`) always require a human response.

### Voice-agent tools

The ConvAI agent can call JSON tools defined in `Tools/ToolSchemas.swift` and dispatched via `Tools/ToolHandlers.swift`:

- `list_sessions`, `describe_session`, `get_recent_output`, `get_pending_prompt`
- `send_input`, `approve_prompt`, `reject_prompt`, `show_session`
- `mute_notifications`, `set_priority`
- `schedule_action`, `cancel_scheduled`

### Overlay internals

`EdgeOverlayPanel` is a borderless, non-activating `NSPanel` at `.statusBar` level, stationary, pinned to the configured edge. An `EdgeOverlayHostingView` overrides `hitTest` so mouse events only land on the interactive rectangle — the rest of the overlay passes clicks through to windows below. The arc layout scales its spread and radius with session count so pills stay readable even when many sessions are running.

## Known rough edges

- `.onContinuousHover` on the overlay can flicker on fast mouse crossings; mitigated with a 220ms collapse debounce in `EdgeOverlayHost`.
- The per-session "meter" shows log-scaled output volume, not a real context-percentage stat.
- Voice agent reconnects are not graceful if the ElevenLabs WebSocket drops mid-turn.

## License

No license file is included. Treat as all-rights-reserved unless a `LICENSE` file is added.
