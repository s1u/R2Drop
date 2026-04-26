import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if !appState.isUnlocked {
                if appState.hasCredentials {
                    UnlockView()
                } else {
                    SetupView()
                }
            } else {
                MainView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.isUnlocked)
    }
}
