import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var appState: AppState
    @State private var password: String = ""
    @State private var isUnlocking = false
    @FocusState private var focusField: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Logo
            Image(systemName: "cloud.fill")
                .font(.system(size: 60))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .padding(.bottom, 8)

            Text("R2Drop")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("输入主密码解锁加密存储")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Password field
            SecureField("主密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($focusField)
                .onSubmit { unlock() }
                .disabled(isUnlocking)

            if let error = appState.loginError {
                Text(error)
                .foregroundColor(.red)
                .font(.caption)
            }

            Button(action: unlock) {
                if isUnlocking {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("解锁")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(width: 280)
            .disabled(password.isEmpty || isUnlocking)

            Button("重置凭据") {
                try? appState.cryptoService.deleteCredentials()
                appState.hasCredentials = false
                appState.loginError = nil
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { focusField = true }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        isUnlocking = true
        Task {
            await appState.unlock(masterPassword: password)
            isUnlocking = false
        }
    }
}
