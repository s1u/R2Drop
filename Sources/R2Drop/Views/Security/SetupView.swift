import SwiftUI

struct SetupView: View {
    @EnvironmentObject var appState: AppState
    @State private var accountId = ""
    @State private var bucket = ""
    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var customDomain = ""
    @State private var masterPassword = ""
    @State private var confirmPassword = ""
    @State private var isSettingUp = false
    @State private var errorMessage: String?
    @FocusState private var focusField: Field?

    enum Field { case accountId, bucket, accessKey, secretKey, customDomain, password, confirm }

    var passwordsMatch: Bool {
        !masterPassword.isEmpty && masterPassword == confirmPassword
    }

    var formValid: Bool {
        !accountId.isEmpty && !bucket.isEmpty && !accessKeyId.isEmpty &&
        !secretAccessKey.isEmpty && passwordsMatch
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 20)

                Image(systemName: "key.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                Text("首次使用 — 配置 R2 连接")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("输入你的 Cloudflare R2 凭据，这些数据将被主密码加密存储")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                // R2 Config fields
                Group {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Account ID").font(.caption).foregroundColor(.secondary)
                        TextField("your-account-id", text: $accountId)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusField, equals: .accountId)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bucket 名称").font(.caption).foregroundColor(.secondary)
                        TextField("my-bucket", text: $bucket)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusField, equals: .bucket)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Access Key ID").font(.caption).foregroundColor(.secondary)
                        TextField("your-access-key-id", text: $accessKeyId)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusField, equals: .accessKey)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Secret Access Key").font(.caption).foregroundColor(.secondary)
                        SecureField("your-secret-access-key", text: $secretAccessKey)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusField, equals: .secretKey)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("自定义域名（可选）").font(.caption).foregroundColor(.secondary)
                        TextField("r2drop.example.com", text: $customDomain)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusField, equals: .customDomain)
                    }
                }
                .frame(width: 360)

                Divider().frame(width: 360)

                // Master Password
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置主密码（用于加密以上凭据）").font(.caption).foregroundColor(.secondary)
                    SecureField("主密码", text: $masterPassword)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusField, equals: .password)
                }
                .frame(width: 360)

                VStack(alignment: .leading, spacing: 4) {
                    SecureField("确认主密码", text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusField, equals: .confirm)
                }
                .frame(width: 360)

                if !masterPassword.isEmpty && !confirmPassword.isEmpty && !passwordsMatch {
                    Text("两次输入的密码不一致")
                        .foregroundColor(.red)
                        .font(.caption)
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                Button(action: setup) {
                    if isSettingUp {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("保存并连接")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(width: 360)
                .disabled(!formValid || isSettingUp)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func setup() {
        guard formValid else { return }
        isSettingUp = true
        errorMessage = nil

        let config = R2Config(
            accountId: accountId,
            bucket: bucket,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            customDomain: customDomain.isEmpty ? nil : customDomain
        )

        Task {
            await appState.setupCredentials(config: config, masterPassword: masterPassword)
            if appState.loginError != nil {
                errorMessage = appState.loginError
            }
            isSettingUp = false
        }
    }
}
