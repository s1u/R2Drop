import Foundation

/// R2 connection configuration
struct R2Config: Codable {
    let accountId: String
    let bucket: String
    let accessKeyId: String
    let secretAccessKey: String
    let endpoint: String

    var region: String { "auto" }

    /// Optional custom domain for public access (e.g., "r2drop.230032.xyz")
    let customDomain: String?

    init(accountId: String, bucket: String, accessKeyId: String, secretAccessKey: String, customDomain: String? = nil) {
        self.accountId = accountId
        self.bucket = bucket
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.customDomain = customDomain
        self.endpoint = "https://\(accountId).r2.cloudflarestorage.com"
    }
}
