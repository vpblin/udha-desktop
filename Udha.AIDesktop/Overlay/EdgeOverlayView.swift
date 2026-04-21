import SwiftUI
import AppKit

struct EdgeOverlayView: View {
    let core: AppCore
    @Binding var isExpanded: Bool
    @Bindable var config: ConfigStore
    @Bindable var stateStore: SessionStateStore
    let panelSize: CGSize

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettingsAction
    @State private var hoveredSessionID: UUID?
    @State private var breath: CGFloat = 0
    @State private var marchPhase: CGFloat = 0
    @State private var sessionPendingRemoval: SessionSnapshot?

    private var edge: OverlayEdge { config.config.overlay.edge }
    private var triggerWidth: CGFloat { CGFloat(config.config.overlay.triggerWidth) }
    private var sessions: [SessionSnapshot] { stateStore.all }
    private var hasAttention: Bool { sessions.contains { $0.state.wantsPulse } }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Clear base — hit testing is handled by the NSHostingView override.
            Color.clear

            if isExpanded {
                bloomStack
                    .transition(.opacity.combined(with: .move(edge: edge == .right ? .trailing : .leading)))
            } else {
                restingSpine
                    .transition(.opacity.combined(with: .move(edge: edge == .right ? .trailing : .leading)))
            }
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: edge == .right ? .trailing : .leading)
        .animation(OverlayTheme.bloomSpring, value: isExpanded)
        .animation(OverlayTheme.quickEase, value: hasAttention)
        .confirmationDialog(
            "Remove \(sessionPendingRemoval?.label ?? "session")?",
            isPresented: Binding(
                get: { sessionPendingRemoval != nil },
                set: { if !$0 { sessionPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: sessionPendingRemoval
        ) { snap in
            Button("Remove", role: .destructive) {
                core.sessionManager.removeSession(id: snap.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This stops the tmux session and deletes the project from your config.")
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breath = 1
            }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                marchPhase = 1
            }
        }
    }

    // MARK: - Resting spine

    /// Ultra-slim strip pinned to the edge. A living "pilot light" that hints at state
    /// without demanding attention. Intended for peripheral vision.
    private var restingSpine: some View {
        ZStack {
            spineGradient
            spineAmbientBreath
            spineDots
            if hasAttention { spineAttentionGlow }
        }
        .frame(width: triggerWidth, height: panelSize.height)
        .contentShape(Rectangle())
    }

    /// Gentle living glow so the edge strip reads as "alive" even when no session
    /// needs input. Breathes with the same phase as the dots.
    private var spineAmbientBreath: some View {
        let base: Color = OverlayTheme.amber.opacity(0.18)
        return Rectangle()
            .fill(
                LinearGradient(
                    colors: [base.opacity(0), base.opacity(0.12 + 0.18 * breath), base.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(width: triggerWidth * 2.4)
            .blur(radius: 14)
            .allowsHitTesting(false)
    }

    private var spineGradient: some View {
        let gradient = LinearGradient(
            colors: [
                OverlayTheme.obsidianEdge.opacity(0.0),
                OverlayTheme.obsidianCore.opacity(0.92),
                OverlayTheme.obsidianRim.opacity(0.95),
                OverlayTheme.obsidianEdge
            ],
            startPoint: edge == .right ? .leading : .trailing,
            endPoint: edge == .right ? .trailing : .leading
        )
        let cornerTL: CGFloat = edge == .right ? 4 : 0
        let cornerBL: CGFloat = edge == .right ? 4 : 0
        let cornerTR: CGFloat = edge == .right ? 0 : 4
        let cornerBR: CGFloat = edge == .right ? 0 : 4
        let mask = UnevenRoundedRectangle(
            topLeadingRadius: cornerTL,
            bottomLeadingRadius: cornerBL,
            bottomTrailingRadius: cornerBR,
            topTrailingRadius: cornerTR
        )
        let shadowOffset: CGFloat = edge == .right ? -6 : 6
        return gradient
            .overlay(spineHairline)
            .mask(mask)
            .shadow(color: .black.opacity(0.35), radius: 14, x: shadowOffset, y: 0)
    }

    private var spineHairline: some View {
        let alignment: Alignment = edge == .right ? .leading : .trailing
        return Rectangle()
            .fill(OverlayTheme.hairline)
            .frame(width: 0.5)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var spineDots: some View {
        VStack(spacing: 11) {
            ForEach(sessions) { snap in
                SpineDot(state: snap.state, breath: breath)
            }
        }
    }

    private var spineAttentionGlow: some View {
        let colors: [Color] = [
            OverlayTheme.amber.opacity(0.0),
            OverlayTheme.amberGlow.opacity(0.55 * breath),
            OverlayTheme.amber.opacity(0.0)
        ]
        return Rectangle()
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: triggerWidth * 1.8)
            .blur(radius: 10)
            .allowsHitTesting(false)
    }

    // MARK: - Bloomed vertical stack

    private var bloomStack: some View {
        ZStack(alignment: .top) {
            bloomBackground
            VStack(spacing: 0) {
                headerBar
                if core.voice.isListening {
                    voiceStatusBar
                }
                Divider().background(OverlayTheme.hairline)
                sessionList
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
    }

    /// Slim banner under the header that appears whenever voice is on. Gives
    /// an unmistakable "the mic is live" cue — a pulsing dot plus the status
    /// text the controller is publishing ("Connecting…" / "Listening" / etc.).
    private var voiceStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .opacity(0.55 + 0.45 * breath)
                .shadow(color: Color.red.opacity(0.6), radius: 4)
            Text(core.voice.statusMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.08))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var bloomBackground: some View {
        ZStack {
            Rectangle()
                .fill(OverlayTheme.panelBG)
            // Hairline along the inward edge for panel-attached crispness.
            HStack(spacing: 0) {
                if edge == .right {
                    Rectangle()
                        .fill(OverlayTheme.hairlineStrong)
                        .frame(width: 0.5)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(OverlayTheme.hairlineStrong)
                        .frame(width: 0.5)
                }
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 20, x: edge == .right ? -8 : 8, y: 0)
        .allowsHitTesting(false)
    }

    private var headerBar: some View {
        let activeCount = sessions.filter { $0.state == .working }.count
        let needsCount = sessions.filter { $0.state == .needsInput }.count
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Udha")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(statusReadout(active: activeCount, needs: needsCount))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hasAttention ? OverlayTheme.stateNeedsInput : .white.opacity(0.55))
            }
            Spacer()
            micButton
            headerControl(glyph: "plus", tint: .white, action: openNewSession)
            headerControl(glyph: "gearshape", tint: .white, action: openSettings)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func headerControl(glyph: String, tint: Color, action: @escaping () -> Void) -> some View {
        HeaderControlButton(glyph: glyph, tint: tint, action: action)
    }

    /// Mic button with a live-state ring — two expanding circles pulse out
    /// while voice is on, like a FaceTime/Zoom in-call indicator. No ambiguity
    /// about whether the mic is actually engaged.
    private var micButton: some View {
        ZStack {
            if core.voice.isListening {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(Color.red.opacity(0.6 - 0.3 * Double(i)), lineWidth: 1.2)
                        .frame(width: 30 + CGFloat(i) * 10 + 18 * breath,
                               height: 30 + CGFloat(i) * 10 + 18 * breath)
                        .opacity(1 - breath)
                }
            }
            HeaderControlButton(
                glyph: core.voice.isListening ? "mic.fill" : "mic",
                tint: core.voice.isListening ? Color.red : .white,
                action: { core.voice.toggle() }
            )
        }
        .frame(width: 30, height: 30)
    }

    private func statusReadout(active: Int, needs: Int) -> String {
        if needs > 0 { return "\(needs) waiting" }
        if active > 0 { return "\(active) running" }
        if sessions.isEmpty { return "Idle" }
        return "\(sessions.count) sessions"
    }

    private var sessionList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 4) {
                ForEach(sessions) { snap in
                    let lineCount = core.sessionManager.buffer(for: snap.id)?.count ?? 0
                    SessionNodeView(
                        snapshot: snap,
                        hovered: hoveredSessionID == snap.id,
                        labelMode: config.config.overlay.labelMode,
                        edge: edge,
                        breath: breath,
                        marchPhase: marchPhase,
                        bufferLineCount: lineCount,
                        autoApprove: config.config.sessions.first(where: { $0.id == snap.id })?.autoApprove ?? false,
                        onHover: { hovering in handleHover(sessionID: snap.id, hovering: hovering) },
                        onClick: { core.sessionManager.showSession(id: snap.id) },
                        onToggleAutoApprove: {
                            config.mutate { cfg in
                                if let idx = cfg.sessions.firstIndex(where: { $0.id == snap.id }) {
                                    cfg.sessions[idx].autoApprove.toggle()
                                }
                            }
                        },
                        onRemove: { sessionPendingRemoval = snap }
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92)),
                        removal: .opacity
                    ))
                }
                if sessions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "terminal")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                        Text("No sessions yet")
                            .font(OverlayTheme.mono(11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                        Text("Tap + to add one.")
                            .font(OverlayTheme.mono(10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.top, 60)
                }
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: - Interaction

    private func handleHover(sessionID: UUID, hovering: Bool) {
        if hovering {
            hoveredSessionID = sessionID
            let delay = Double(config.config.overlay.hoverFocusDelayMs) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if hoveredSessionID == sessionID {
                    core.sessionManager.showSession(id: sessionID)
                }
            }
        } else if hoveredSessionID == sessionID {
            hoveredSessionID = nil
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    private func openNewSession() {
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .udhaRequestNewSession, object: nil)
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's Settings scene — opens the standard Settings window.
        openSettingsAction()
    }
}

// MARK: - Spine dot

private struct SpineDot: View {
    let state: SessionState
    let breath: CGFloat

    var body: some View {
        let color = state.signalColor
        let pulseScale = state.wantsPulse ? 1.0 + 0.22 * breath : 1.0
        return ZStack {
            // Inner bright core.
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color, radius: 4)
                .shadow(color: color.opacity(0.7), radius: 8)

            // Outer ring, always faintly visible so even idle sessions show.
            Circle()
                .stroke(color.opacity(0.55), lineWidth: 0.8)
                .frame(width: 11, height: 11)

            // Expanding pulse ring for attention states.
            if state.wantsPulse {
                Circle()
                    .stroke(color.opacity(1 - breath), lineWidth: 1)
                    .frame(width: 11 + 12 * breath, height: 11 + 12 * breath)
            }
        }
        .scaleEffect(pulseScale)
    }
}

// MARK: - Tick mark ring

private struct TickMarkRing: View {
    let edge: OverlayEdge
    let center: CGPoint
    let radius: CGFloat
    let tickCount: Int
    let activeTicks: Set<Int>
    let marchPhase: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<tickCount, id: \.self) { idx in
                let progress = Double(idx) / Double(tickCount - 1)
                // Spread ticks across the visible semicircle (inside-facing 180° arc).
                let spread = Double.pi * 0.95
                let startAngle: Double = edge == .right ? .pi - spread / 2 : -spread / 2
                let a = startAngle + progress * spread
                let isActive = activeTicks.contains(idx)
                let tickLength: CGFloat = isActive ? 9 : 5
                let tickColor = isActive ? OverlayTheme.amber.opacity(0.85) : OverlayTheme.hairline
                let tickWidth: CGFloat = isActive ? 1.4 : 0.7

                let p1 = CGPoint(
                    x: center.x + CGFloat(Foundation.cos(a)) * radius,
                    y: center.y + CGFloat(Foundation.sin(a)) * radius
                )
                let p2 = CGPoint(
                    x: center.x + CGFloat(Foundation.cos(a)) * (radius - tickLength),
                    y: center.y + CGFloat(Foundation.sin(a)) * (radius - tickLength)
                )

                Path { path in
                    path.move(to: p1)
                    path.addLine(to: p2)
                }
                .stroke(tickColor, lineWidth: tickWidth)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Header control button

private struct HeaderControlButton: View {
    let glyph: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(hovering ? Color.white.opacity(0.14) : Color.white.opacity(0.07))
                    .overlay(
                        Circle().stroke(Color.white.opacity(hovering ? 0.22 : 0.12), lineWidth: 0.5)
                    )
                Image(systemName: glyph)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)
            .animation(OverlayTheme.quickEase, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension Notification.Name {
    static let udhaRequestNewSession = Notification.Name("udha.requestNewSession")
    static let udhaRequestSettings   = Notification.Name("udha.requestSettings")
}
