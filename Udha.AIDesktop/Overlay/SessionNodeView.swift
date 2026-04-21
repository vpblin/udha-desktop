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

    /// Small close button pinned inside the card's top-right corner, styled
    /// after macOS window traffic-light buttons. Subtle until hovered.
    private var removeButton: some View {
        Button(action: onRemove) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(hovered ? 0.12 : 0.05))
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovered ? Color.red : .secondary)
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help("Remove this session")
    }

    // MARK: - Card

    private var card: some View {
        let color = snapshot.state.signalColor
        return ZStack(alignment: .topTrailing) {
            attentionGlow(color: color)
            cardBody(color: color)
            cardContent(color: color)
            removeButton
                .padding(.top, 14)
                .padding(.trailing, 14)
        }
        .frame(width: cardWidth + 24, height: cardHeight + 24)
        .scaleEffect(hovered ? 1.015 : 1.0)
        .animation(OverlayTheme.quickEase, value: hovered)
    }

    /// Soft tinted halo behind the card — only visible for attention states
    /// (needsInput, errored, crashed) so it doesn't add noise to the list.
    @ViewBuilder
    private func attentionGlow(color: Color) -> some View {
        if snapshot.state.wantsPulse {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(color.opacity(0.18 + 0.1 * breath))
                .frame(width: cardWidth + 10, height: cardHeight + 10)
                .blur(radius: 14)
                .allowsHitTesting(false)
        }
    }

    private func cardBody(color: Color) -> some View {
        let strokeColor: Color = hovered
            ? color.opacity(0.55)
            : Color.primary.opacity(0.08)
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.thinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: hovered ? 1.0 : 0.6)
            )
            .frame(width: cardWidth, height: cardHeight)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
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
        HStack(spacing: 8) {
            stateDot(color: color)
            Text(snapshot.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            autoApproveButton
            Text(elapsedReadout)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.trailing, 22) // reserve space for the × remove button
    }

    private var autoApproveButton: some View {
        let tint: Color = autoApprove ? .orange : .secondary
        return Button(action: onToggleAutoApprove) {
            HStack(spacing: 3) {
                Image(systemName: autoApprove ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 9, weight: .semibold))
                Text("Auto")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(tint.opacity(autoApprove ? 0.15 : 0.08))
            )
        }
        .buttonStyle(.plain)
        .help(autoApprove
              ? "Auto-approve on. Destructive prompts still require confirmation."
              : "Click to auto-approve non-destructive prompts for this session.")
    }

    private func stateRow(color: Color) -> some View {
        HStack(spacing: 6) {
            Text(stateLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            if let activity = activityText {
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 2, height: 2)
                Text(activity)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    private func meterRow(color: Color) -> some View {
        HStack(spacing: 8) {
            MeterBar(progress: meterProgress, color: color, segments: 14)
                .frame(width: 86, height: 4)
            Text(leftStat)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let badge = trailingBadge {
                Text(badge.text)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(badge.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(badge.color.opacity(0.15)))
            }
        }
    }

    // MARK: - State dot (LED)

    private func stateDot(color: Color) -> some View {
        ZStack {
            if snapshot.state.wantsPulse {
                Circle()
                    .fill(color.opacity(0.25 + 0.2 * breath))
                    .frame(width: 14, height: 14)
                    .blur(radius: 2)
            }
            Circle()
                .fill(color.gradient)
                .frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
    }

    // MARK: - Derived text

    private var stateLabel: String {
        switch snapshot.state {
        case .working:     return "Running"
        case .needsInput:  return "Needs input"
        case .errored:     return "Error"
        case .crashed:     return "Crashed"
        case .completed:   return "Done"
        case .starting:    return "Starting"
        case .idle:        return "Idle"
        case .exited:      return "Exited"
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
