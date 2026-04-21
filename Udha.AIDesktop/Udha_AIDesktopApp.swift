import SwiftUI

@main
struct Udha_AIDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Udha", id: "main") {
            RootView()
                .environment(delegate.bootstrapCore())
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { EmptyView() }
        }

        Settings {
            let core = delegate.bootstrapCore()
            SettingsView(
                config: core.config,
                keychain: core.keychain,
                tts: core.conversational.tts,
                core: core
            )
        }

        MenuBarExtra {
            MenuBarContent(core: delegate.bootstrapCore())
        } label: {
            let core = delegate.bootstrapCore()
            MenuBarStatusView(voice: core.voice, stateStore: core.stateStore)
        }
        .menuBarExtraStyle(.window)
    }
}
