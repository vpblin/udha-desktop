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

    private var edge: OverlayEdge { config.config.overlay.edge }
    private var triggerWidth: CGFloat { CGFloat(config.config.overlay.triggerWidth) }
    private var sessions: [SessionSnapshot] { stateStore.all }
    private var hasAttention: Bool { sessions.contains { $0.state.wantsPulse } }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Clear base — hit testing is handled by the NSHostingView override.
            Color.clear

            if isExpanded {
                bloomDisc
                    .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: edge == .right ? .trailing : .leading)))
            } else {
                restingSpine
                    .transition(.opacity.combined(with: .move(edge: edge == .right ? .trailing : .leading)))
            }
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: edge == .right ? .trailing : .leading)
        .animation(OverlayTheme.bloomSpring, value: isExpanded)
        .animation(OverlayTheme.quickEase, value: hasAttention)
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

    // MARK: - Bloomed disc

    private var bloomDisc: some View {
        ZStack {
            discBackground
            sessionArc
            centerBadge
            footerControls
        }
        .frame(width: panelSize.width, height: panelSize.height)
    }

    private var discBackground: some View {
        let geom = OverlayGeometry(edge: edge, panelSize: panelSize, nodeCount: sessions.count)
        let discRadius: CGFloat = geom.nodeRadius + 72
        let diameter = discRadius * 2
        let center = geom.arcCenter
        let tickRadius = geom.nodeRadius + 46
        let rimLightGradient = AngularGradient(
            colors: rimLightColors(),
            center: .center,
            startAngle: .degrees(edge == .right ? 90 : -90),
            endAngle: .degrees(edge == .right ? 270 : 270)
        )
        return ZStack {
            // Ambient halo — soft warm wash behind the disc.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            OverlayTheme.amber.opacity(hasAttention ? 0.18 : 0.08),
                            OverlayTheme.amber.opacity(0.0)
                        ],
                        center: .center,
                        startRadius: discRadius * 0.4,
                        endRadius: discRadius * 0.95
                    )
                )
                .frame(width: diameter * 1.4, height: diameter * 1.4)
                .blur(radius: 28)
                .position(center)
                .allowsHitTesting(false)

            // Disc body — dense obsidian glass, now noticeably opaque.
            Circle()
                .fill(.regularMaterial)
                .overlay(
                    Circle().fill(
                        RadialGradient(
                            colors: [
                                OverlayTheme.obsidianCore.opacity(0.98),
                                OverlayTheme.obsidianCore,
                                OverlayTheme.obsidianEdge
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: discRadius
                        )
                    )
                )
                .frame(width: diameter, height: diameter)
                .position(center)
                .shadow(color: .black.opacity(0.65), radius: 50, x: edge == .right ? -16 : 16, y: 18)

            // Rim meniscus — two stacked strokes for a thicker, more luminous edge.
            Circle()
                .strokeBorder(rimLightGradient, lineWidth: 2.0)
                .frame(width: diameter, height: diameter)
                .position(center)
                .blendMode(.screen)
                .allowsHitTesting(false)

            Circle()
                .strokeBorder(OverlayTheme.hairlineStrong, lineWidth: 0.6)
                .frame(width: diameter - 4, height: diameter - 4)
                .position(center)
                .allowsHitTesting(false)

            // Concentric engraved guides — subtle mechanical detail.
            Circle()
                .stroke(OverlayTheme.hairline, lineWidth: 0.5)
                .frame(width: (geom.nodeRadius + 8) * 2, height: (geom.nodeRadius + 8) * 2)
                .position(center)
            Circle()
                .stroke(OverlayTheme.hairline.opacity(0.7), lineWidth: 0.5)
                .frame(width: (geom.nodeRadius - 46) * 2, height: (geom.nodeRadius - 46) * 2)
                .position(center)

            // Deep drop shadow cast back toward the screen interior.
            Circle()
                .fill(Color.black.opacity(0.001))
                .frame(width: diameter, height: diameter)
                .position(center)
                .shadow(color: .black.opacity(0.5), radius: 40, x: edge == .right ? -18 : 18, y: 14)
                .allowsHitTesting(false)

            // Tick marks — instrument-panel character around the rim.
            TickMarkRing(
                edge: edge,
                center: center,
                radius: tickRadius,
                tickCount: 18,
                activeTicks: activeTickIndices(),
                marchPhase: marchPhase
            )
        }
    }

    /// Which tick indices should glow — derived from session positions so the
    /// rim hints at where nodes will bloom.
    private func activeTickIndices() -> Set<Int> {
        let n = sessions.count
        guard n > 0 else { return [] }
        let total = 18
        // Map each session onto the 11 middle ticks (skip first/last few).
        let inset = 3
        let range = total - inset * 2
        var out = Set<Int>()
        for i in 0..<n {
            let slot = inset + Int(round(Double(i) / Double(max(n - 1, 1)) * Double(range - 1)))
            out.insert(slot)
        }
        return out
    }

    /// Colors that make the visible (inward) side of the rim glow warm,
    /// while the hidden side fades into the screen edge.
    private func rimLightColors() -> [Color] {
        let bright = hasAttention ? OverlayTheme.amberGlow : OverlayTheme.amber.opacity(0.85)
        let mid    = OverlayTheme.hairlineStrong
        let dim    = Color.black.opacity(0.4)
        // For right edge, inward is left (180°). For left edge, inward is right (0°).
        // AngularGradient starts at 0° (right) and sweeps clockwise.
        if edge == .right {
            return [dim, mid, bright, bright, mid, dim]
        } else {
            return [bright, mid, dim, dim, mid, bright]
        }
    }

    /// Session nodes arranged on a parametric arc.
    private var sessionArc: some View {
        let geom = OverlayGeometry(edge: edge, panelSize: panelSize, nodeCount: sessions.count)
        let radius = geom.nodeRadius
        return ZStack {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { (idx, snap) in
                let pos = geom.position(for: idx, radius: radius)
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
                    }
                )
                .position(pos)
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.1, anchor: .center)
                            .combined(with: .opacity)
                            .animation(OverlayTheme.nodeSpring.delay(Double(idx) * 0.04)),
                        removal: .opacity
                    )
                )
            }
        }
    }

    private var centerBadge: some View {
        let size: CGFloat = 72
        // Inset slightly from the edge so the whole badge is visible.
        let center = OverlayGeometry(edge: edge, panelSize: panelSize, nodeCount: 0).arcCenter
        let inset: CGFloat = size / 2 + 6
        let badgeCenter = CGPoint(
            x: edge == .right ? center.x - inset : center.x + inset,
            y: center.y
        )
        let activeCount = sessions.filter { $0.state == .working }.count
        let needsCount = sessions.filter { $0.state == .needsInput }.count
        return ZStack {
            // Bezeled pad.
            Circle()
                .fill(OverlayTheme.obsidianEdge)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [OverlayTheme.hairlineStrong, Color.black.opacity(0.6)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            VStack(spacing: 3) {
                Text("UDHA")
                    .font(OverlayTheme.display(12, weight: .heavy))
                    .tracking(3.0)
                    .foregroundStyle(OverlayTheme.amber)
                Rectangle()
                    .fill(OverlayTheme.hairlineStrong)
                    .frame(width: 26, height: 0.5)
                Text(statusReadout(active: activeCount, needs: needsCount))
                    .font(OverlayTheme.mono(10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(hasAttention ? OverlayTheme.amber : .white.opacity(0.78))
            }
        }
        .frame(width: size, height: size)
        .position(badgeCenter)
    }

    private func statusReadout(active: Int, needs: Int) -> String {
        if needs > 0 { return "\(needs) WAIT" }
        if active > 0 { return "\(active) RUN" }
        if sessions.isEmpty { return "IDLE" }
        return "\(sessions.count) OK"
    }

    private var footerControls: some View {
        let geom = OverlayGeometry(edge: edge, panelSize: panelSize, nodeCount: 0)
        let center = geom.arcCenter
        // Stack the tray of controls vertically along the disc axis, inside the rim.
        let trayX: CGFloat = edge == .right ? center.x - 44 : center.x + 44
        let trayY: CGFloat = center.y + geom.nodeRadius + 20
        let items: [FooterControl] = [
            FooterControl(
                glyph: core.voice.isListening ? "mic.fill" : "mic",
                action: { core.voice.toggle() },
                tint: core.voice.isListening ? OverlayTheme.stateErrored : .white
            ),
            FooterControl(glyph: "plus", action: { openNewSession() }, tint: .white),
            FooterControl(glyph: "gearshape", action: { openSettings() }, tint: .white)
        ]
        return HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { (_, item) in
                FooterControlButton(item: item)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(OverlayTheme.obsidianEdge.opacity(0.88))
                .overlay(Capsule().stroke(OverlayTheme.hairlineStrong, lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.4), radius: 6)
        .position(x: trayX, y: trayY)
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

// MARK: - Footer button

private struct FooterControl {
    let glyph: String
    let action: () -> Void
    let tint: Color
}

private struct FooterControlButton: View {
    let item: FooterControl
    @State private var hovering = false

    var body: some View {
        Button(action: item.action) {
            ZStack {
                Circle()
                    .fill(OverlayTheme.obsidianCore)
                    .overlay(Circle().stroke(
                        hovering ? OverlayTheme.amber.opacity(0.65) : OverlayTheme.hairlineStrong,
                        lineWidth: 0.8
                    ))
                    .shadow(color: .black.opacity(0.4), radius: 4)
                Image(systemName: item.glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? OverlayTheme.amber : item.tint.opacity(0.85))
            }
            .frame(width: 28, height: 28)
            .scaleEffect(hovering ? 1.08 : 1.0)
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
