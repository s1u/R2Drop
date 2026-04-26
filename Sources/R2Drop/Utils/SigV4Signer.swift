import Foundation
import CommonCrypto

/// Pure Swift implementation of AWS Signature V4 for generating presigned URLs.
/// Compatible with Cloudflare R2 S3-compatible API.
///
/// Reference: https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
struct SigV4Signer {
    let accessKey: String
    let secretKey: String
    let region: String
    let service: String

    private let iso8601DateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    /// Generate a presigned URL for S3-compatible storage (R2)
    /// - Parameters:
    ///   - method: HTTP method, e.g. "GET"
    ///   - host: Virtual-hosted-style host, e.g. "bucket.accountid.r2.cloudflarestorage.com"
    ///   - path: Object path, e.g. "/myfile.pdf"
    ///   - expires: Time-to-live in seconds
    ///   - date: Optional date (defaults to now)
    /// - Returns: Presigned URL with query string auth parameters
    func presignURL(method: String = "GET",
                    host: String,
                    path: String,
                    expires: Int = 3600,
                    date: Date = Date()) -> URL {

        let now = date
        let amzDate = iso8601DateFormatter.string(from: now)
        let dateStamp = shortDateFormatter.string(from: now)
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"

        // S3 key for hashing
        let signedHeaders = "host"

        // Canonical request components
        let canonicalURI = path.isEmpty ? "/" : path
        let canonicalQueryString = [
            "X-Amz-Algorithm=\(algorithm)",
            "X-Amz-Credential=\(percentEncode("\(accessKey)/\(credentialScope)"))",
            "X-Amz-Date=\(amzDate)",
            "X-Amz-Expires=\(expires)",
            "X-Amz-SignedHeaders=\(signedHeaders)",
        ].joined(separator: "&")

        let canonicalHeaders = "host:\(host)\n"
        let payloadHash = sha256Hex("") // Empty body for GET

        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQueryString,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        // String to sign
        let stringToSign = [
            algorithm,
            amzDate,
            credentialScope,
            sha256Hex(canonicalRequest),
        ].joined(separator: "\n")

        // Signing key
        let signingKey = deriveSigningKey(dateStamp: dateStamp)
        let signature = HMACSHA256(key: signingKey, data: stringToSign).hexString

        // Build the final URL
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "X-Amz-Algorithm", value: algorithm),
            URLQueryItem(name: "X-Amz-Credential", value: "\(accessKey)/\(credentialScope)"),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: String(expires)),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: signedHeaders),
            URLQueryItem(name: "X-Amz-Signature", value: signature),
        ]

        return components.url!
    }

    // MARK: - Signing internals

    private let algorithm = "AWS4-HMAC-SHA256"

    private func deriveSigningKey(dateStamp: String) -> Data {
        let kSecret = "AWS4\(secretKey)".data(using: .utf8)!
        let kDate = HMACSHA256(key: kSecret, data: dateStamp)
        let kRegion = HMACSHA256(key: kDate, data: region)
        let kService = HMACSHA256(key: kRegion, data: service)
        let kSigning = HMACSHA256(key: kService, data: "aws4_request")
        return kSigning
    }

    private func sha256Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Percent-encode per RFC 3986 (needed for X-Amz-Credential)
    private func percentEncode(_ string: String) -> String {
        // AWS SigV4 requires that some characters are encoded
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}

// MARK: - HMAC-SHA256 helper

private func HMACSHA256(key: Data, data: String) -> Data {
    var hmac = CCHmacContext()
    let keyBytes = [UInt8](key)
    let dataBytes = [UInt8](data.utf8)

    CCHmacInit(&hmac, CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes, keyBytes.count)
    CCHmacUpdate(&hmac, dataBytes, dataBytes.count)

    var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CCHmacFinal(&hmac, &mac)

    return Data(mac)
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
