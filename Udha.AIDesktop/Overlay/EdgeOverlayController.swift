import AppKit
import SwiftUI
import Combine

@MainActor
final class EdgeOverlayController: NSObject {
    private weak var core: AppCore?
    private var panel: EdgeOverlayPanel?
    private var hostingView: EdgeOverlayHostingView<EdgeOverlayHost>?
    private var screenObserver: NSObjectProtocol?
    private let state = EdgeOverlayState()
    private var configCancellable: AnyCancellable?

    init(core: AppCore) {
        self.core = core
        super.init()
        present()
        observeScreens()
        observeConfig()
    }

    deinit {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func present() {
        guard let core else { return }
        if !core.config.config.overlay.enabled {
            dismiss()
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panelFrame = panelFrame(for: screen)
        let panel = self.panel ?? EdgeOverlayPanel(contentRect: panelFrame)
        panel.setFrame(panelFrame, display: false)

        let host = EdgeOverlayHost(core: core, config: core.config, stateStore: core.stateStore, state: state, panelSize: panelFrame.size)
        let hosting = hostingView ?? EdgeOverlayHostingView(rootView: host)
        hosting.rootView = host
        hosting.frame = NSRect(origin: .zero, size: panelFrame.size)
        hosting.interactiveRectProvider = { [weak self] in
            self?.currentInteractiveRect(panelSize: panelFrame.size) ?? .zero
        }

        panel.contentView = hosting
        panel.orderFrontRegardless()
        panel.level = .statusBar

        self.panel = panel
        self.hostingView = hosting
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.present() }
        }
    }

    private func observeConfig() {
        // Re-present on config changes that affect geometry (edge / trigger width / enabled).
        configCancellable = NotificationCenter.default
            .publisher(for: .udhaOverlayConfigChanged)
            .sink { [weak self] _ in
                Task { @MainActor in self?.present() }
            }
    }

    private func panelFrame(for screen: NSScreen) -> NSRect {
        let width: CGFloat = 460
        let visible = screen.visibleFrame
        guard let edge = core?.config.config.overlay.edge else {
            return NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
        }
        switch edge {
        case .right:
            return NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
        case .left:
            return NSRect(x: visible.minX, y: visible.minY, width: width, height: visible.height)
        }
    }

    private func currentInteractiveRect(panelSize: CGSize) -> CGRect {
        let edge = core?.config.config.overlay.edge ?? .right
        let trigger = CGFloat(core?.config.config.overlay.triggerWidth ?? 14)
        if state.isExpanded {
            // Disc centered on the edge, radius ~ min(width * 0.95, height * 0.47)
            // Use a tall rectangle covering roughly where the disc is visible.
            let discReach: CGFloat = min(panelSize.width * 0.95, panelSize.height * 0.47)
            let height = discReach * 2 + 40
            let y = (panelSize.height - height) / 2
            switch edge {
            case .right:
                let x = panelSize.width - discReach - 20
                return CGRect(x: x, y: y, width: discReach + 30, height: height)
            case .left:
                return CGRect(x: -10, y: y, width: discReach + 30, height: height)
            }
        } else {
            switch edge {
            case .right:
                return CGRect(x: panelSize.width - trigger, y: 0, width: trigger, height: panelSize.height)
            case .left:
                return CGRect(x: 0, y: 0, width: trigger, height: panelSize.height)
            }
        }
    }
}

/// Shared expansion state — the NSHostingView reads this synchronously for hit-testing
/// while SwiftUI uses it as the source of truth for bloom animation.
@MainActor
final class EdgeOverlayState: ObservableObject {
    @Published var isExpanded: Bool = false
}

struct EdgeOverlayHost: View {
    let core: AppCore
    @Bindable var config: ConfigStore
    @Bindable var stateStore: SessionStateStore
    @ObservedObject var state: EdgeOverlayState
    let panelSize: CGSize
    @State private var collapseTask: DispatchWorkItem?

    var body: some View {
        EdgeOverlayView(
            core: core,
            isExpanded: Binding(
                get: { state.isExpanded },
                set: { state.isExpanded = $0 }
            ),
            config: config,
            stateStore: stateStore,
            panelSize: panelSize
        )
        .onContinuousHover { phase in
            switch phase {
            case .active:
                collapseTask?.cancel()
                collapseTask = nil
                if !state.isExpanded {
                    withAnimation(OverlayTheme.bloomSpring) { state.isExpanded = true }
                }
            case .ended:
                // Debounce — hit-testing along the visible crescent can momentarily drop
                // outside the interactive rect mid-movement; don't flicker closed for that.
                collapseTask?.cancel()
                let work = DispatchWorkItem {
                    withAnimation(OverlayTheme.bloomSpring) { state.isExpanded = false }
                }
                collapseTask = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
            }
        }
    }
}

extension Notification.Name {
    static let udhaOverlayConfigChanged = Notification.Name("udha.overlayConfigChanged")
}
