import SwiftUI

struct SessionNodeView: View {
    let snapshot: SessionSnapshot
    let hovered: Bool
    let labelMode: OverlayLabelMode
    let edge: OverlayEdge
    let breath: CGFloat
    let marchPhase: CGFloat
    let bufferLineCount: Int
    let autoApprove: Bool
    let onHover: (Bool) -> Void
    let onClick: () -> Void
    let onToggleAutoApprove: () -> Void
    let onRemove: () -> Void

    private let cardWidth: CGFloat = 224
    private let cardHeight: CGFloat = 82

    var body: some View {
        card
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onHover { onHover($0) }
            .onTapGesture { onClick() }
            .animation(OverlayTheme.quickEase, value: hovered)
    }

    /// Always-visible close button pinned inside the card's top-right corner.
    /// Living inside `cardBody` (not the outer glow frame) guarantees it never
    /// gets clipped by the panel edge even for extreme-angle pills.
    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white.opacity(hovered ? 1.0 : 0.78))
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(OverlayTheme.stateErrored.opacity(hovered ? 0.95 : 0.7))
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.6))
                )
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .help("Remove this session")
    }

    // MARK: - Card

    private var card: some View {
        let color = snapshot.state.signalColor
        return ZStack(alignment: .topTrailing) {
            ambientGlow(color: color)
            workingHalo(color: color)
            cardBody(color: color)
            cardContent(color: color)
            // 12pt frame padding + 4pt inset → 16pt from outer frame corner.
            removeButton
                .padding(.top, 16)
                .padding(.trailing, 16)
        }
        .frame(width: cardWidth + 24, height: cardHeight + 24)
        .scaleEffect(hovered ? 1.035 : 1.0)
    }

    private func ambientGlow(color: Color) -> some View {
        let pulseBoost = snapshot.state.wantsPulse ? 0.28 * breath : 0
        let base = hovered ? 0.55 : 0.22
        return RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(color.opacity(base + pulseBoost))
            .frame(width: cardWidth * 1.25, height: cardHeight * 1.55)
            .blur(radius: hovered ? 22 : 16)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func workingHalo(color: Color) -> some View {
        if snapshot.state == .working {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        colors: [color.opacity(0), color, color.opacity(0.9), color.opacity(0)],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    lineWidth: 1.4
                )
                .rotationEffect(.degrees(Double(marchPhase) * 360))
                .frame(width: cardWidth + 6, height: cardHeight + 6)
        }
    }

    private func cardBody(color: Color) -> some View {
        let borderColor: Color = hovered ? color.opacity(0.85) : OverlayTheme.hairlineStrong
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(bodyFill)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [borderColor, Color.black.opacity(0.5)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.9
                    )
            )
            .frame(width: cardWidth, height: cardHeight)
            .shadow(color: .black.opacity(0.55), radius: 8, y: 3)
    }

    private var bodyFill: LinearGradient {
        LinearGradient(
            colors: [
                OverlayTheme.obsidianRim,
                OverlayTheme.obsidianCore,
                OverlayTheme.obsidianEdge
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    // One type scale: display/13 for the name, display/11 for activity,
    // mono/11 for all-caps labels, mono/10 for numeric readouts.
    private func cardContent(color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            topRow(color: color)
            stateRow(color: color)
            meterRow(color: color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
    }

    private func topRow(color: Color) -> some View {
        HStack(spacing: 9) {
            stateDot(color: color)
            Text(snapshot.label)
                .font(OverlayTheme.display(13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            autoApproveButton
            Text(elapsedReadout)
                .font(OverlayTheme.mono(10, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.trailing, 24) // reserve space for the × remove button
    }

    private var autoApproveButton: some View {
        let tint = autoApprove ? OverlayTheme.amber : Color.white.opacity(0.45)
        return Button(action: onToggleAutoApprove) {
            HStack(spacing: 3) {
                Image(systemName: autoApprove ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 9, weight: .bold))
                Text("AUTO")
                    .font(OverlayTheme.mono(9, weight: .bold))
                    .tracking(0.5)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill(tint.opacity(autoApprove ? 0.18 : 0.06))
                    .overlay(Capsule().stroke(tint.opacity(autoApprove ? 0.7 : 0.35), lineWidth: 0.6))
            )
        }
        .buttonStyle(.plain)
        .help(autoApprove
              ? "Auto-approve on. Destructive prompts still require confirmation."
              : "Click to auto-approve non-destructive prompts for this session.")
    }

    private func stateRow(color: Color) -> some View {
        HStack(spacing: 7) {
            Text(stateLabel)
                .font(OverlayTheme.mono(10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(color)
            if let activity = activityText {
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 2, height: 2)
                Text(activity)
                    .font(OverlayTheme.display(11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    private func meterRow(color: Color) -> some View {
        HStack(spacing: 8) {
            MeterBar(progress: meterProgress, color: color, segments: 14)
                .frame(width: 86, height: 5)
            Text(leftStat)
                .font(OverlayTheme.mono(10, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 0)
            if let badge = trailingBadge {
                Text(badge.text)
                    .font(OverlayTheme.mono(9, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(badge.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule().fill(badge.color.opacity(0.14))
                            .overlay(Capsule().stroke(badge.color.opacity(0.55), lineWidth: 0.6))
                    )
            }
        }
    }

    // MARK: - State dot (LED)

    private func stateDot(color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(snapshot.state.wantsPulse ? 0.42 + 0.4 * breath : 0.38))
                .frame(width: 18, height: 18)
                .blur(radius: 3.5)
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .shadow(color: color, radius: 3.5)
            Circle()
                .fill(Color.white.opacity(0.75))
                .frame(width: 2.2, height: 2.2)
                .offset(x: -1.4, y: -1.4)
        }
        .frame(width: 18, height: 18)
    }

    // MARK: - Derived text

    private var stateLabel: String {
        switch snapshot.state {
        case .working:     return "RUNNING"
        case .needsInput:  return "NEEDS INPUT"
        case .errored:     return "ERROR"
        case .crashed:     return "CRASHED"
        case .completed:   return "DONE"
        case .starting:    return "STARTING"
        case .idle:        return "IDLE"
        case .exited:      return "EXITED"
        }
    }

    private var activityText: String? {
        if let prompt = snapshot.pendingPrompt?.text {
            return prompt.components(separatedBy: .newlines).first.map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        if let summary = snapshot.recentSummary, !summary.isEmpty { return summary }
        return snapshot.currentActivity
    }

    private var elapsedReadout: String {
        let secs = Int(Date().timeIntervalSince(snapshot.stateEnteredAt))
        if secs < 60 { return String(format: "%02ds", secs) }
        let m = secs / 60
        let s = secs % 60
        if m < 60 { return String(format: "%02d:%02d", m, s) }
        let h = m / 60
        return String(format: "%dh%02dm", h, m % 60)
    }

    /// Output volume, log-scaled to RingBuffer capacity (2000 lines). Small sessions
    /// show a barely-lit meter, busy ones show a mostly-full meter. Attention states
    /// bump the floor so they always read as "hot."
    private var meterProgress: Double {
        let lines = max(1.0, Double(bufferLineCount))
        let volume = min(1.0, log10(lines) / 3.3) // log10(2000) ≈ 3.3
        switch snapshot.state {
        case .working:
            let wave = 0.06 * Double(sin(Double(marchPhase) * .pi * 2))
            return max(0.2, min(1.0, volume + wave))
        case .needsInput, .errored, .crashed:
            return max(volume, 0.75)
        case .completed:
            return max(volume, 0.55)
        case .idle, .exited, .starting:
            return volume
        }
    }

    private var leftStat: String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.groupingSeparator = ","
        let num = fmt.string(from: NSNumber(value: bufferLineCount)) ?? "\(bufferLineCount)"
        return "\(num) ln"
    }

    private struct Badge {
        let text: String
        let color: Color
    }

    private var trailingBadge: Badge? {
        if let code = snapshot.exitCode, code != 0 {
            return Badge(text: "E\(code)", color: OverlayTheme.stateErrored)
        }
        if snapshot.priority == .high {
            return Badge(text: "HI", color: OverlayTheme.amber)
        }
        if snapshot.pendingPrompt?.isDestructive == true {
            return Badge(text: "DESTR", color: OverlayTheme.stateErrored)
        }
        return nil
    }
}

// MARK: - Meter bar (segmented)

private struct MeterBar: View {
    let progress: Double // 0...1
    let color: Color
    let segments: Int

    var body: some View {
        GeometryReader { geo in
            let segW = (geo.size.width - Double(segments - 1) * 1.2) / Double(segments)
            HStack(spacing: 1.2) {
                ForEach(0..<segments, id: \.self) { idx in
                    let t = Double(idx) / Double(max(segments - 1, 1))
                    let active = t <= max(0, min(1, progress))
                    Capsule(style: .continuous)
                        .fill(active ? color : OverlayTheme.hairline)
                        .frame(width: segW, height: geo.size.height)
                        .opacity(active ? 0.9 : 0.35)
                }
            }
        }
    }
}
