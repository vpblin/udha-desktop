import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appCore: AppCore?
    private var overlayController: EdgeOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let core = bootstrapCore()
        core.start()
        installOverlay(core: core)
    }

    /// Lazily construct the AppCore once and cache it — callable from any entry point.
    @discardableResult
    func bootstrapCore() -> AppCore {
        if let c = appCore { return c }
        let c = AppCore()
        appCore = c
        return c
    }

    func installOverlay(core: AppCore) {
        overlayController = EdgeOverlayController(core: core)
        if core.config.config.overlay.hideMainWindowOnLaunch {
            // Defer until after the initial WindowGroup has created its window.
            DispatchQueue.main.async { [weak self] in self?.hideMainWindows() }
        }
    }

    private func hideMainWindows() {
        // Miniaturize instead of orderOut — SwiftUI disposes ordered-out WindowGroup windows,
        // and we still need the window around so the gear/plus buttons can reveal it later.
        for window in mainContentWindows() {
            window.miniaturize(nil)
        }
    }

    /// Bring any existing main window forward. If none exists, returns without creating one —
    /// the Window scene + openWindow path is used for initial creation instead.
    func revealMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let candidates = mainContentWindows(includeMiniaturized: true)
        if let window = candidates.first {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func mainContentWindows(includeMiniaturized: Bool = false) -> [NSWindow] {
        NSApp.windows.filter { window in
            guard !(window is EdgeOverlayPanel) else { return false }
            let cls = String(describing: type(of: window))
            if cls.contains("MenuBarExtra") { return false }
            if cls.contains("StatusBar") { return false }
            if cls.contains("Popover") { return false }
            if cls.contains("Menu") && !cls.contains("Window") { return false }
            if includeMiniaturized && window.isMiniaturized { return true }
            return window.frame.width >= 400 && window.frame.height >= 300
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        appCore?.shutdown()
    }
}
