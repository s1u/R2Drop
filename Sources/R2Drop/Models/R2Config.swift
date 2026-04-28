import Foundation

/// R2 connection configuration
struct R2Config: Codable {
    let accountId: String
    let bucket: String
    let accessKeyId: String
    let secretAccessKey: String
    let endpoint: String

    var region: String { "auto" }

    init(accountId: String, bucket: String, accessKeyId: String, secretAccessKey: String) {
        self.accountId = accountId
        self.bucket = bucket
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.endpoint = "https://\(accountId).r2.cloudflarestorage.com"
    }
}
