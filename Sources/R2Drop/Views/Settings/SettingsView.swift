import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gear") }

            AboutSettings()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 450, height: 250)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("安全") {
                if appState.hasCredentials {
                    HStack {
                        Text("凭据状态")
                        Spacer()
                        Text("已加密存储")
                            .foregroundColor(.green)
                            .font(.caption)
                    }

                    Button("清除凭据并重新设置") {
                        try? appState.cryptoService.deleteCredentials()
                        appState.hasCredentials = false
                        appState.lock()
                    }
                } else {
                    Text("未设置凭据")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("R2Drop")
                .font(.title2)
                .fontWeight(.bold)

            Text("v1.0.0")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("跨平台 Cloudflare R2 文件管理工具")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
