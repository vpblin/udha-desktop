import Foundation
import Observation
import os

@MainActor
@Observable
final class ProactiveVoiceEngine {
    let stateStore: SessionStateStore
    let notifications: NotificationBus
    let tts: ElevenLabsTTSClient
    let config: ConfigStore

    private var player: AudioPlayer { AudioPlayer.shared }
    private var queue: [VoiceRequest] = []
    private var isSpeaking: Bool = false
    private var watchTask: Task<Void, Never>?
    private var lastSnapshots: [UUID: SessionSnapshot] = [:]
    private var lastSpokenSummary: [UUID: (text: String, at: Date)] = [:]
    // Gates ALL speech — transition announcements, Slack announcements,
    // anything routed through enqueue. Flipped by VoiceController so the mic
    // button is also a global mute switch.
    private var isEnabled: Bool = false
    var externalBargeIn: (() -> Void)?

    // How long a session must stay in .working before we start announcing
    // periodic summaries, and how often after that.
    private let workingSummaryWarmupSec: TimeInterval = 60
    private let workingSummaryCadenceSec: TimeInterval = 180

    init(stateStore: SessionStateStore, notifications: NotificationBus, tts: ElevenLabsTTSClient, config: ConfigStore) {
        self.stateStore = stateStore
        self.notifications = notifications
        self.tts = tts
        self.config = config
    }

    func start() {
        isEnabled = true
        // Seed lastSnapshots so turning voice on doesn't cause every already-
        // known session to fire an announceFirstSeen on the next tick.
        for snap in stateStore.all where lastSnapshots[snap.id] == nil {
            lastSnapshots[snap.id] = snap
        }
        player.onPlaybackFinished = { [weak self] in
            Task { @MainActor in self?.maybeSpeakNext() }
        }
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.observeTransitions()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        isEnabled = false
        watchTask?.cancel()
        watchTask = nil
        queue.removeAll()
        isSpeaking = false
        player.stop()
    }

    func enqueue(_ request: VoiceRequest) {
        guard isEnabled else {
            Log.voice.info("SUPPRESSED (voice off): \(request.text)")
            return
        }
        guard notifications.shouldSpeak(request) else {
            Log.voice.info("SUPPRESSED: \(request.text)")
            return
        }
        Log.voice.info("queuing proactive: \(request.text)")
        queue.append(request)
        maybeSpeakNext()
    }

    func interrupt() {
        queue.removeAll()
        player.clearQueue()
        isSpeaking = false
    }

    private func maybeSpeakNext() {
        guard !isSpeaking else { return }
        guard !queue.isEmpty else { return }
        let request = queue.removeFirst()
        isSpeaking = true
        Task { @MainActor in
            await speak(request)
            isSpeaking = false
            maybeSpeakNext()
        }
    }

    private func speak(_ request: VoiceRequest) async {
        notifications.didSpeak(request)
        if let sid = request.sessionID {
            stateStore.recordSpoken(id: sid, text: request.text)
        }
        do {
            let pcm = try await tts.streamingTTS(text: request.text)
            player.enqueuePCM16(pcm)
            Log.voice.info("Spoke: \(request.text)")
        } catch {
            Log.voice.error("TTS failed: \(error.localizedDescription)")
            speakFallback(request.text)
        }
    }

    private func speakFallback(_ text: String) {
        let task = Process()
        task.launchPath = "/usr/bin/say"
        task.arguments = [text]
        try? task.run()
    }

    private func observeTransitions() {
        for snap in stateStore.all {
            let prior = lastSnapshots[snap.id]
            defer { lastSnapshots[snap.id] = snap }

            // 1. First time we see this session — announce only if it's
            //    already in an interesting terminal/attention-needing state,
            //    so restarting the app doesn't miss an urgent prompt.
            guard let prior else {
                announceFirstSeen(snap)
                continue
            }

            // 2. State changed — the normal transition announcement.
            if prior.state != snap.state {
                Log.voice.info("transition \(snap.label): \(prior.state.rawValue) → \(snap.state.rawValue)")
                announceTransition(from: prior, to: snap)
                continue
            }

            // 3. State unchanged, but a fresh prompt or new error appeared.
            //    Without this, successive approvals on the same session are
            //    silent.
            if snap.state == .needsInput,
               let prompt = snap.pendingPrompt,
               prompt.text != prior.pendingPrompt?.text {
                Log.voice.info("new prompt on \(snap.label) while already needsInput")
                announceNeedsInput(snap)
                continue
            }
            if snap.state == .errored,
               let err = snap.lastErrorMessage,
               err != prior.lastErrorMessage {
                enqueue(VoiceRequest(
                    text: "\(snap.label) errored again — \(shortened(err))",
                    channel: .proactive,
                    sessionID: snap.id,
                    urgency: .high,
                    allowWhenMuted: true
                ))
                continue
            }

            // 4. Still working — periodic progress update using the Haiku
            //    summary so long-running sessions aren't radio-silent.
            if snap.state == .working {
                maybeAnnounceWorkingSummary(snap)
            }
        }
    }

    private func announceFirstSeen(_ snap: SessionSnapshot) {
        switch snap.state {
        case .needsInput:
            announceNeedsInput(snap)
        case .errored:
            let detail = snap.lastErrorMessage.map { " — " + shortened($0) } ?? "."
            enqueue(VoiceRequest(
                text: "\(snap.label) is errored\(detail)",
                channel: .proactive,
                sessionID: snap.id,
                urgency: .high,
                allowWhenMuted: true
            ))
        case .crashed:
            enqueue(VoiceRequest(
                text: "\(snap.label) has crashed.",
                channel: .proactive,
                sessionID: snap.id,
                urgency: .high,
                allowWhenMuted: true
            ))
        default:
            break
        }
    }

    private func announceTransition(from prior: SessionSnapshot, to snap: SessionSnapshot) {
        if prior.state == .working && snap.state != .working {
            lastSpokenSummary.removeValue(forKey: snap.id)
        }
        switch snap.state {
        case .completed:
            enqueue(VoiceRequest(
                text: "\(snap.label) finished.",
                channel: .proactive,
                sessionID: snap.id,
                urgency: .normal,
                allowWhenMuted: false
            ))
        case .idle where prior.state == .working:
            let workDuration = Date().timeIntervalSince(prior.stateEnteredAt)
            if workDuration >= 10 {
                let summary = snap.recentSummary.map { ": \($0)" } ?? "."
                enqueue(VoiceRequest(
                    text: "\(snap.label) is done\(summary)",
                    channel: .proactive,
                    sessionID: snap.id,
                    urgency: .high,
                    allowWhenMuted: true
                ))
            }
        case .errored:
            let detail = snap.lastErrorMessage.map { " — " + shortened($0) } ?? "."
            enqueue(VoiceRequest(
                text: "\(snap.label) errored\(detail)",
                channel: .proactive,
                sessionID: snap.id,
                urgency: .high,
                allowWhenMuted: true
            ))
        case .needsInput:
            announceNeedsInput(snap)
        case .crashed:
            enqueue(VoiceRequest(
                text: "\(snap.label) crashed.",
                channel: .proactive,
                sessionID: snap.id,
                urgency: .high,
                allowWhenMuted: true
            ))
        default:
            break
        }
    }

    private func announceNeedsInput(_ snap: SessionSnapshot) {
        guard let prompt = snap.pendingPrompt else { return }
        // Auto-approve handles non-destructive prompts silently; destructive
        // prompts still speak, since SessionManager never auto-approves those.
        if !prompt.isDestructive,
           let cfg = config.config.sessions.first(where: { $0.id == snap.id }),
           cfg.autoApprove {
            return
        }
        let text: String
        if prompt.isDestructive {
            text = "\(snap.label) wants to \(prompt.text.prefix(80)). Say it again if you really mean it."
        } else {
            text = "\(snap.label) needs your approval."
        }
        enqueue(VoiceRequest(
            text: text,
            channel: .proactive,
            sessionID: snap.id,
            urgency: .high,
            allowWhenMuted: true
        ))
    }

    private func maybeAnnounceWorkingSummary(_ snap: SessionSnapshot) {
        guard let summary = snap.recentSummary, !summary.isEmpty else { return }
        let now = Date()
        // Warm-up: don't speak until the session has been working long enough
        // that a summary is actually meaningful.
        let inStateFor = now.timeIntervalSince(snap.stateEnteredAt)
        guard inStateFor >= workingSummaryWarmupSec else { return }

        if let last = lastSpokenSummary[snap.id] {
            // Skip if we already spoke this exact text, or if it's too soon.
            if last.text == summary { return }
            if now.timeIntervalSince(last.at) < workingSummaryCadenceSec { return }
        } else {
            // First summary for this working run — honor the cadence from the
            // moment the session entered .working, so we don't spam right at
            // the warm-up boundary.
            if inStateFor < workingSummaryCadenceSec { return }
        }

        lastSpokenSummary[snap.id] = (summary, now)
        enqueue(VoiceRequest(
            text: "\(snap.label): \(summary)",
            channel: .proactive,
            sessionID: snap.id,
            urgency: .normal,
            allowWhenMuted: false
        ))
    }

    private func shortened(_ s: String) -> String {
        if s.count <= 80 { return s }
        let idx = s.index(s.startIndex, offsetBy: 80)
        return String(s[..<idx])
    }
}
