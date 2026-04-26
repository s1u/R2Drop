import SwiftUI

@main
struct R2DropApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
