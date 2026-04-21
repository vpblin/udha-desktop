import SwiftUI
import Foundation

enum OverlayTheme {
    // Obsidian base — warm-toned, not neutral grey. Borrowed from instrument panels.
    static let obsidianCore = Color(red: 0.055, green: 0.050, blue: 0.062)
    static let obsidianRim  = Color(red: 0.115, green: 0.100, blue: 0.120)
    static let obsidianEdge = Color(red: 0.020, green: 0.018, blue: 0.024)

    // Amber accent — the default "signal on" color. Warmer than gold, cooler than orange.
    static let amber        = Color(red: 1.00,  green: 0.710, blue: 0.280)
    static let amberGlow    = Color(red: 1.00,  green: 0.585, blue: 0.200)

    // Semantic signal colors. Each is tuned to sit well on the obsidian base.
    static let stateWorking    = Color(red: 0.36, green: 0.88, blue: 1.00)   // electric cyan
    static let stateNeedsInput = Color(red: 1.00, green: 0.710, blue: 0.28)  // amber
    static let stateErrored    = Color(red: 1.00, green: 0.38, blue: 0.31)   // vermilion
    static let stateCompleted  = Color(red: 0.56, green: 0.96, blue: 0.72)   // mint
    static let stateIdle       = Color(red: 0.56, green: 0.56, blue: 0.62)   // slate

    // Engraved hairlines, the fine details that sell the "real object" feel.
    static let hairline       = Color.white.opacity(0.055)
    static let hairlineStrong = Color.white.opacity(0.12)
    static let innerShadow    = Color.black.opacity(0.55)

    // Spring used everywhere — single cohesive motion language.
    static let bloomSpring = Animation.interpolatingSpring(
        mass: 0.9, stiffness: 170, damping: 18, initialVelocity: 0.2
    )
    static let nodeSpring  = Animation.interpolatingSpring(
        mass: 0.6, stiffness: 220, damping: 16
    )
    static let quickEase   = Animation.easeOut(duration: 0.18)

    // Typography — rounded mono for numeric state, rounded sans for labels.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension SessionState {
    var signalColor: Color {
        switch self {
        case .working:              return OverlayTheme.stateWorking
        case .needsInput:           return OverlayTheme.stateNeedsInput
        case .errored, .crashed:    return OverlayTheme.stateErrored
        case .completed:            return OverlayTheme.stateCompleted
        case .starting, .idle:      return OverlayTheme.stateIdle
        case .exited:               return OverlayTheme.stateIdle.opacity(0.5)
        }
    }

    var glyph: String {
        switch self {
        case .working:     return "waveform"
        case .needsInput:  return "questionmark"
        case .errored:     return "exclamationmark"
        case .crashed:     return "bolt.slash"
        case .completed:   return "checkmark"
        case .starting:    return "circle.dotted"
        case .idle:        return "circle"
        case .exited:      return "power"
        }
    }

    var wantsPulse: Bool {
        self == .needsInput || self == .errored
    }
}

// Geometry helpers for the arc layout.
struct OverlayGeometry {
    let edge: OverlayEdge
    let panelSize: CGSize
    let nodeCount: Int

    /// Center point of the arc, on the side of the edge.
    var arcCenter: CGPoint {
        let y = panelSize.height / 2
        let x: CGFloat = edge == .right ? panelSize.width : 0
        return CGPoint(x: x, y: y)
    }

    /// Radius at which session nodes are placed.
    /// Grows with session count so the pills don't squash into each other on
    /// busy days — capped so the disc still fits inside the 460-wide panel.
    var nodeRadius: CGFloat {
        let base: CGFloat = 230
        let extra: CGFloat = CGFloat(max(0, nodeCount - 4)) * 14
        let ceiling = min(panelSize.width - 78, 320)
        return min(base + extra, ceiling)
    }

    /// Arc spread (radians) — also grows with session count. Base 62°, up to ~165°.
    var arcSpread: Double {
        let base = Double.pi * 0.62
        let extra = Double.pi * 0.08 * Double(max(0, nodeCount - 4))
        return min(base + extra, Double.pi * 0.92)
    }

    /// Angle (radians) for node at index — opens inward from the edge.
    func angle(for index: Int) -> Double {
        let n = max(nodeCount, 1)
        if n == 1 { return edge == .right ? .pi : 0 }
        let spread = arcSpread
        let t = Double(index) / Double(max(n - 1, 1))
        let offset = -spread / 2 + spread * t
        // Inward direction is π (left) for right edge, 0 (right) for left edge.
        let inward: Double = edge == .right ? .pi : 0
        return inward + offset
    }

    func position(for index: Int, radius: CGFloat) -> CGPoint {
        let a = angle(for: index)
        let dx = CGFloat(Foundation.cos(a)) * radius
        let dy = CGFloat(Foundation.sin(a)) * radius
        return CGPoint(x: arcCenter.x + dx, y: arcCenter.y + dy)
    }
}
