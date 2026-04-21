import Foundation
import AppKit
import Combine
import os

@MainActor
final class SessionManager: ObservableObject {
    let stateStore: SessionStateStore
    let classifier: HaikuClassifier
    let config: ConfigStore
    let activity: ActivityLog

    private var sessions: [UUID: TmuxSession] = [:]
    private var buffers: [UUID: RingBuffer] = [:]
    private var summaryTimers: [UUID: DispatchSourceTimer] = [:]
    private var quietTimers: [UUID: DispatchSourceTimer] = [:]
    private var pendingClassification: [UUID: (state: SessionState, seenAt: Date)] = [:]

    init(stateStore: SessionStateStore, classifier: HaikuClassifier, config: ConfigStore, activity: ActivityLog) {
        self.stateStore = stateStore
        self.classifier = classifier
        self.config = config
        self.activity = activity
    }

    func restoreSessions() {
        for cfg in config.config.sessions where cfg.enabled {
            _ = try? spawn(sessionConfig: cfg)
        }
    }

    func shutdownAll() {
        for s in sessions.values { s.detach() }
    }

    func buffer(for id: UUID) -> RingBuffer? {
        buffers[id]
    }

    func session(for id: UUID) -> TmuxSession? {
        sessions[id]
    }

    func spawn(sessionConfig: SessionConfig) throws -> UUID {
        let id = sessionConfig.id
        let buffer = RingBuffer(maxLines: 2000)
        let session = TmuxSession(
            id: id,
            label: sessionConfig.label,
            directory: sessionConfig.directory,
            command: sessionConfig.command,
            args: sessionConfig.args
        )

        let snapshot = SessionSnapshot(
            id: id,
            label: sessionConfig.label,
            directory: sessionConfig.directory,
            state: .starting,
            stateEnteredAt: Date(),
            currentActivity: nil,
            recentSummary: nil,
            pendingPrompt: nil,
            lastErrorMessage: nil,
            lastSpoken: nil,
            priority: sessionConfig.priority,
            exitCode: nil
        )
        stateStore.insert(snapshot)

        let destructiveKeywords = config.config.notifications.destructiveKeywords

        session.onData = { [weak self] data in
            guard let self else { return }
            buffer.append(data)
            Task { @MainActor in
                self.handleOutput(id: id, buffer: buffer, destructiveKeywords: destructiveKeywords)
            }
        }

        session.onSnapshot = { [weak self] content in
            guard let self else { return }
            Task { @MainActor in
                self.handleSnapshot(id: id, content: content, destructiveKeywords: destructiveKeywords)
            }
        }

        session.onExit = { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                self.stateStore.update(id: id) { snap in
                    snap.state = code == 0 ? .exited : .crashed
                    snap.exitCode = code
                    snap.stateEnteredAt = Date()
                }
                self.stopSummaryTimer(for: id)
                Log.pty.info("Session \(sessionConfig.label) exited code=\(code)")
            }
        }

        do {
            try session.start()
            sessions[id] = session
            buffers[id] = buffer
            _ = stateStore.transition(id: id, to: .idle)

            // Seed buffer with recent scrollback so restart doesn't lose history
            let scrollback = session.captureScrollback(maxLines: 200)
            if !scrollback.isEmpty {
                buffer.append(string: scrollback + "\n")
                Log.pty.info("seeded \(sessionConfig.label) with \(scrollback.count)B scrollback")
            }

            startQuietTransitionTimer(for: id)
            startSummaryTimer(for: id)
        } catch {
            stateStore.update(id: id) { $0.state = .crashed; $0.lastErrorMessage = "\(error)" }
            Log.pty.error("Failed to start session \(sessionConfig.label): \(error.localizedDescription)")
            throw error
        }

        return id
    }

    func terminateSession(id: UUID) {
        sessions[id]?.kill()
    }

    func removeSession(id: UUID) {
        sessions[id]?.kill()
        sessions.removeValue(forKey: id)
        buffers.removeValue(forKey: id)
        stopSummaryTimer(for: id)
        stateStore.remove(id: id)
        config.mutate { $0.sessions.removeAll(where: { $0.id == id }) }
    }

    func sendInput(id: UUID, text: String) {
        sessions[id]?.sendInput(text: text)
        activity.record(.sendInput(sessionID: id, text: text))
    }

    func sendRaw(id: UUID, text: String) {
        sessions[id]?.sendRaw(text: text)
    }

    func sendKey(id: UUID, key: String) {
        sessions[id]?.sendKey(key)
    }

    func showSession(id: UUID) {
        sessions[id]?.bringToFront()
    }

    private func handleSnapshot(id: UUID, content: String, destructiveKeywords: [String]) {
        // Snapshot from tmux capture-pane — contains the current visible pane.
        let lines = content.components(separatedBy: "\n")
            .map { line in RingBuffer.stripANSI(line) }
        runClassifier(id: id, lines: lines, destructiveKeywords: destructiveKeywords)
    }

    private func handleOutput(id: UUID, buffer: RingBuffer, destructiveKeywords: [String]) {
        let lines = buffer.recent(lines: 80)
        runClassifier(id: id, lines: lines, destructiveKeywords: destructiveKeywords)
    }

    private func runClassifier(id: UUID, lines: [String], destructiveKeywords: [String]) {
        let classifier = OutputClassifier(destructiveKeywords: destructiveKeywords)
        let result = classifier.classify(lines: lines)

        guard let snap = stateStore.snapshot(id: id) else { return }

        // Stability filter: don't transition on first observation of a new state.
        // Require it to be seen for >=1.5s OR 2 consecutive identical classifications.
        // This kills the oscillation we were seeing.
        if let newState = result.state, newState != snap.state {
            let now = Date()
            if let pending = pendingClassification[id], pending.state == newState {
                if now.timeIntervalSince(pending.seenAt) >= 1.5 {
                    applyClassification(id: id, newState: newState, result: result, snap: snap)
                    pendingClassification.removeValue(forKey: id)
                }
            } else {
                pendingClassification[id] = (newState, now)
            }
        } else {
            pendingClassification.removeValue(forKey: id)
            // State is unchanged, but details within the state may have moved —
            // a new prompt text while still in .needsInput, a new error line
            // while still in .errored. Propagate these so downstream (UI + the
            // proactive voice engine) can notice successive events that don't
            // cross a state boundary.
            var newPrompt: PendingPrompt? = nil
            stateStore.update(id: id) { s in
                if let activity = result.activity { s.currentActivity = activity }
                if s.state == .needsInput, let prompt = result.pendingPrompt,
                   prompt.text != s.pendingPrompt?.text {
                    s.pendingPrompt = prompt
                    newPrompt = prompt
                }
                if s.state == .errored, let err = result.errorMessage, err != s.lastErrorMessage {
                    s.lastErrorMessage = err
                }
            }
            if let prompt = newPrompt {
                maybeAutoApprove(id: id, prompt: prompt)
            }
        }

        restartQuietTransitionTimer(for: id)
    }

    private func applyClassification(id: UUID, newState: SessionState, result: ClassifierResult, snap: SessionSnapshot) {
        let oldState = snap.state.rawValue
        let label = snap.label
        Log.classify.info("classifier: \(label) \(oldState) → \(newState.rawValue)")
        stateStore.update(id: id) { s in
            s.state = newState
            s.stateEnteredAt = Date()
            if let activity = result.activity { s.currentActivity = activity }
            if let prompt = result.pendingPrompt { s.pendingPrompt = prompt }
            if newState != .needsInput { s.pendingPrompt = nil }
            if let err = result.errorMessage { s.lastErrorMessage = err }
        }
        if newState == .needsInput, let prompt = result.pendingPrompt {
            maybeAutoApprove(id: id, prompt: prompt)
        }
    }

    // Auto-approves the pending prompt when the session's config has
    // `autoApprove` enabled. Destructive prompts are always skipped so a
    // `rm -rf` or `force push` confirmation still requires a human.
    private func maybeAutoApprove(id: UUID, prompt: PendingPrompt) {
        guard !prompt.isDestructive else { return }
        guard let cfg = config.config.sessions.first(where: { $0.id == id }), cfg.autoApprove else { return }
        let delivered = deliverApprove(style: prompt.style, sessionID: id)
        activity.record(.approvePrompt(sessionID: id, promptText: prompt.text))
        Log.classify.info("auto-approved prompt for \(cfg.label): \(delivered)")
    }

    private func deliverApprove(style: PendingPrompt.Style, sessionID: UUID) -> String {
        switch style {
        case .yesNo, .freeform:
            sendInput(id: sessionID, text: "y")
            return "y⏎"
        case .numbered:
            sendInput(id: sessionID, text: "1")
            return "1⏎"
        case .enterToContinue:
            sendKey(id: sessionID, key: "Enter")
            return "⏎"
        }
    }

    private func startSummaryTimer(for id: UUID) {
        stopSummaryTimer(for: id)
        let interval = TimeInterval(config.config.classifier.summaryIntervalSec)
        guard config.config.classifier.useHaiku else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshSummary(for: id)
            }
        }
        timer.resume()
        summaryTimers[id] = timer
    }

    private func stopSummaryTimer(for id: UUID) {
        summaryTimers[id]?.cancel()
        summaryTimers.removeValue(forKey: id)
    }

    private func refreshSummary(for id: UUID) async {
        guard let snap = stateStore.snapshot(id: id), snap.state == .working else { return }
        guard let buffer = buffers[id] else { return }
        let lines = buffer.recent(lines: 60)
        guard let summary = try? await classifier.summarize(sessionLabel: snap.label, recentLines: lines) else {
            return
        }
        stateStore.update(id: id) { $0.recentSummary = summary }
    }

    private func startQuietTransitionTimer(for id: UUID) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: .never)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.quietTransition(for: id)
            }
        }
        timer.resume()
        quietTimers[id] = timer
    }

    private func restartQuietTransitionTimer(for id: UUID) {
        quietTimers[id]?.cancel()
        startQuietTransitionTimer(for: id)
    }

    private func quietTransition(for id: UUID) {
        stateStore.update(id: id) { snap in
            if snap.state == .working {
                snap.state = .idle
                snap.stateEnteredAt = Date()
                snap.currentActivity = nil
            }
        }
    }
}
