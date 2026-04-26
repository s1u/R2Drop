import Foundation
import CryptoSwift

/// Encrypts/decrypts R2 credentials using a master password.
/// Credentials are stored as an encrypted file, NOT in system keychain.
final class CryptoService {
    private let appDir: URL
    private let credsFile: URL
    private let saltFile: URL

    private static let appName = "r2drop"
    private static let credsFileName = "creds.enc"
    private static let saltFileName = "salt.bin"

    init() {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        appDir = paths[0].appendingPathComponent(Self.appName)
        credsFile = appDir.appendingPathComponent(Self.credsFileName)
        saltFile = appDir.appendingPathComponent(Self.saltFileName)

        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    }

    /// Returns whether encrypted credentials exist on disk
    var hasStoredCredentials: Bool {
        FileManager.default.fileExists(atPath: credsFile.path) &&
        FileManager.default.fileExists(atPath: saltFile.path)
    }

    /// Encrypt R2 config and save to file
    func storeCredentials(_ config: R2Config, masterPassword: String) throws {
        let salt = Salt()
        let key = deriveKey(password: masterPassword, salt: salt)

        let jsonData = try JSONEncoder().encode(config)
        let encrypted = try encrypt(data: jsonData, key: key)

        try salt.data.write(to: saltFile, options: .atomic)
        try encrypted.write(to: credsFile, options: .atomic)
    }

    /// Decrypt and return R2 config
    func loadCredentials(masterPassword: String) throws -> R2Config {
        guard let salt = Salt(data: try Data(contentsOf: saltFile)) else {
            throw CryptoError.invalidSalt
        }
        let key = deriveKey(password: masterPassword, salt: salt)
        let encryptedData = try Data(contentsOf: credsFile)
        let decrypted = try decrypt(data: encryptedData, key: key)
        return try JSONDecoder().decode(R2Config.self, from: decrypted)
    }

    /// Delete stored credentials
    func deleteCredentials() throws {
        if FileManager.default.fileExists(atPath: credsFile.path) {
            try FileManager.default.removeItem(at: credsFile)
        }
        if FileManager.default.fileExists(atPath: saltFile.path) {
            try FileManager.default.removeItem(at: saltFile)
        }
    }

    // MARK: - Crypto internals

    private struct Salt {
        let data: Data

        init() {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            data = Data(bytes)
        }

        init?(data: Data) {
            guard data.count == 32 else { return nil }
            self.data = data
        }
    }

    private func deriveKey(password: String, salt: Salt) -> [UInt8] {
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt.data)
        // PBKDF2 with 100,000 iterations
        let derived = try! PKCS5.PBKDF2(
            password: passwordBytes,
            salt: saltBytes,
            iterations: 100_000,
            keyLength: 32, // AES-256
            variant: .sha256
        ).calculate()
        return derived
    }

    private func encrypt(data: Data, key: [UInt8]) throws -> Data {
        let iv = AES.randomIV(16)
        let aes = try AES(key: key, blockMode: CBC(iv: iv), padding: .pkcs7)
        let encrypted = try aes.encrypt(Array(data))
        // Prepend IV to ciphertext
        var result = Data(iv)
        result.append(Data(encrypted))
        return result
    }

    private func decrypt(data: Data, key: [UInt8]) throws -> Data {
        guard data.count > 16 else { throw CryptoError.invalidData }
        let iv = Array(data[0..<16])
        let ciphertext = Array(data[16...])
        let aes = try AES(key: key, blockMode: CBC(iv: iv), padding: .pkcs7)
        let decrypted = try aes.decrypt(ciphertext)
        return Data(decrypted)
    }
}

enum CryptoError: Error, LocalizedError {
    case invalidSalt
    case invalidData

    var errorDescription: String? {
        switch self {
        case .invalidSalt: return "加密数据损坏（无效的 salt）"
        case .invalidData: return "加密数据损坏"
        }
    }
}
