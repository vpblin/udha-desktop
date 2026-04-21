import AppKit
import SwiftUI

/// A borderless, non-activating panel pinned to the right/left edge of a screen.
/// Always floats on top. Mouse events outside the interactive mask pass through
/// to windows underneath.
final class EdgeOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = true
        self.animationBehavior = .none
    }
}

/// Hosts the SwiftUI overlay and controls hit-testing so the empty parts of
/// the panel don't eat mouse events.
final class EdgeOverlayHostingView<Content: View>: NSHostingView<Content> {
    /// A closure that returns the current interactive rect in view coordinates.
    /// Points outside this rect pass through to the window below.
    var interactiveRectProvider: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let rect = interactiveRectProvider()
        guard rect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}
