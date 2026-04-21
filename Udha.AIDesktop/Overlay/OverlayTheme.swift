import SwiftUI
import Foundation

enum OverlayTheme {
    // Translucent panel/card colors. The panel rides on top of .ultraThinMaterial,
    // so these fills are intentionally faint — they mostly provide depth separation.
    static let obsidianCore = Color.primary.opacity(0.02)
    static let obsidianRim  = Color.primary.opacity(0.04)
    static let obsidianEdge = Color.primary.opacity(0.015)

    // Accent — Apple's tintable blue. Used for brand text, hover highlights, and
    // the "needs input" state color is kept amber for semantic clarity.
    static let amber        = Color.orange
    static let amberGlow    = Color.orange.opacity(0.85)

    // Semantic signal colors — native system tints so they adapt to light/dark
    // appearance and tint-by-accessibility.
    static let stateWorking    = Color.blue
    static let stateNeedsInput = Color.orange
    static let stateErrored    = Color.red
    static let stateCompleted  = Color.green
    static let stateIdle       = Color.secondary

    // Very subtle separators for light and dark mode alike.
    static let hairline       = Color.primary.opacity(0.06)
    static let hairlineStrong = Color.primary.opacity(0.14)
    static let innerShadow    = Color.black.opacity(0.12)

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
    /// Grows aggressively with session count so the pills don't overlap at
    /// high counts. Capped so the widest card still fits horizontally AND
    /// the top/bottom cards don't run off the screen vertically.
    var nodeRadius: CGFloat {
        let base: CGFloat = 230
        let extra: CGFloat = CGFloat(max(0, nodeCount - 3)) * 18
        // Card needs ~124pt of horizontal clearance from the panel's inner edge;
        // at angle π the card's left edge = panelWidth - R - 124. Keep ≥16pt margin.
        let widthCeiling = panelSize.width - 140
        // Vertically, top/bottom pills sit at y = arcCenter.y ± R. Keep ~65pt
        // of margin (half card height + breathing room) so they aren't clipped.
        let heightCeiling = panelSize.height / 2 - 65
        let hardCap: CGFloat = 300
        return min(base + extra, min(widthCeiling, heightCeiling, hardCap))
    }

    /// Arc spread (radians). Base 62°, up to a full 180° once there are ~7 sessions.
    var arcSpread: Double {
        let base = Double.pi * 0.62
        let extra = Double.pi * 0.12 * Double(max(0, nodeCount - 3))
        return min(base + extra, Double.pi)
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
