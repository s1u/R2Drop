import Foundation
import AWSS3
import AWSClientRuntime
import Combine
import SmithyIdentity
import Smithy

/// Main service for interacting with Cloudflare R2 (S3-compatible API)
final actor R2Service {
    private var client: S3Client?
    private var config: R2Config?

    let progressSubject = PassthroughSubject<TransferProgress, Never>()
    let fileListSubject = PassthroughSubject<[R2File], Never>()

    // MARK: - Connection

    func connect(config: R2Config) async throws {
        self.config = config

        let credentials = AWSCredentialIdentity(
            accessKey: config.accessKeyId,
            secret: config.secretAccessKey
        )
        let resolver = try StaticAWSCredentialIdentityResolver(credentials)

        let s3Config = try await S3Client.S3ClientConfiguration(
            awsCredentialIdentityResolver: resolver,
            region: config.region,
            forcePathStyle: true,
            endpoint: config.endpoint
        )

        client = S3Client(config: s3Config)

        // Verify connection — use listBuckets for S3-compatible endpoints
        // Note: R2 requires the correct endpoint, so we verify by accessing the bucket directly
        do {
            _ = try await client?.listBuckets(input: ListBucketsInput())
        } catch {
            // listBuckets may fail on some R2 configurations, verify via listObjects instead
            let verifyInput = ListObjectsV2Input(bucket: config.bucket, maxKeys: 1)
            _ = try await client?.listObjectsV2(input: verifyInput)
        }
    }

    func disconnect() {
        client = nil
        config = nil
    }

    var isConnected: Bool { client != nil }

    // MARK: - List Files

    func listFiles(prefix: String = "", maxKeys: Int = 1000,
                   continuationToken: String? = nil) async throws -> R2FileList {
        guard let client, let config else { throw R2Error.notConnected }

        let input = ListObjectsV2Input(
            bucket: config.bucket,
            continuationToken: continuationToken,
            maxKeys: Int(maxKeys),
            prefix: prefix
        )

        let output = try await client.listObjectsV2(input: input)

        let contents = output.contents ?? []
        var files: [R2File] = []

        for obj in contents {
            guard let key = obj.key, let lastMod = obj.lastModified else { continue }
            let file = R2File(
                key: key,
                size: obj.size.map(Int64.init) ?? Int64(0),
                lastModified: lastMod,
                etag: obj.eTag ?? ""
            )
            files.append(file)
        }

        return R2FileList(
            files: files.sorted { $0.lastModified > $1.lastModified },
            isTruncated: output.isTruncated ?? false,
            nextContinuationToken: output.nextContinuationToken
        )
    }

    func listAllFiles() async throws -> [R2File] {
        var allFiles: [R2File] = []
        var token: String? = nil

        repeat {
            let result = try await listFiles(continuationToken: token)
            allFiles.append(contentsOf: result.files)
            token = result.isTruncated ? result.nextContinuationToken : nil
        } while token != nil

        return allFiles.sorted { $0.lastModified > $1.lastModified }
    }

    // MARK: - Upload (with retry)

    /// Upload a file with automatic retry for transient failures.
    func upload(fileURL: URL, progressHandler: @escaping (Double) -> Void) async throws {
        guard let client, let config else { throw R2Error.notConnected }

        let fileData = try Data(contentsOf: fileURL)
        let key = fileURL.lastPathComponent
        let fileSize = Int64(fileData.count)
        let uploadId: String

        // Check if file already exists — we overwrite silently
        // (S3-compatible APIs overwrite on put)

        // For files < 50MB, use simple put
        if fileSize < 50_000_000 {
            try await retryAsync(maxRetries: 2) {
                let input = PutObjectInput(
                    body: .data(fileData),
                    bucket: config.bucket,
                    key: key
                )
                _ = try await client.putObject(input: input)
            }
            progressHandler(100)
            return
        }

        // Multipart upload for larger files
        let createInput = CreateMultipartUploadInput(
            bucket: config.bucket,
            key: key
        )
        let createOutput = try await client.createMultipartUpload(input: createInput)
        guard let uid = createOutput.uploadId else {
            throw R2Error.uploadFailed("无法获取 Upload ID")
        }
        uploadId = uid

        defer {
            // Clean up if we fail mid-upload
        }

        let partSize = 10_485_760 // 10MB
        var completedParts: [S3ClientTypes.CompletedPart] = []
        var partNumber: Int = 1
        var bytesUploaded: Int64 = 0

        var offset: Int64 = 0
        while offset < fileSize {
            let chunkEnd = min(offset + Int64(partSize), fileSize)
            let chunkRange = Int(offset)..<Int(chunkEnd)
            let chunk = Data(fileData[chunkRange])

            // Upload each part with retry
            try await retryAsync(maxRetries: 2) {
                let uploadPartInput = UploadPartInput(
                    body: .data(chunk),
                    bucket: config.bucket,
                    key: key,
                    partNumber: partNumber,
                    uploadId: uploadId
                )
                let uploadOutput = try await client.uploadPart(input: uploadPartInput)
                guard let etag = uploadOutput.eTag else {
                    throw R2Error.uploadFailed("分片 \(partNumber) 缺少 ETag")
                }

                completedParts.append(S3ClientTypes.CompletedPart(
                    eTag: etag,
                    partNumber: partNumber
                ))
            }

            bytesUploaded += chunkEnd - offset
            progressHandler(Double(bytesUploaded) / Double(fileSize) * 100)
            partNumber += 1
            offset = chunkEnd
        }

        let completeInput = CompleteMultipartUploadInput(
            bucket: config.bucket,
            key: key,
            multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: completedParts),
            uploadId: uploadId
        )
        _ = try await client.completeMultipartUpload(input: completeInput)
    }

    // MARK: - Download

    func download(key: String, destination: URL,
                  progressHandler: @escaping (Double) -> Void) async throws {
        guard let client, let config else { throw R2Error.notConnected }

        let input = GetObjectInput(bucket: config.bucket, key: key)
        let output: GetObjectOutput

        // Retry download on transient failure
        output = try await retryAsync(maxRetries: 2) {
            try await client.getObject(input: input)
        }

        guard let body = output.body else {
            throw R2Error.downloadFailed("服务器返回空数据")
        }

        let expectedSize = output.contentLength ?? 0
        let data: Data
        switch body {
        case .data(let optionalData):
            guard let d = optionalData else {
                throw R2Error.downloadFailed("返回数据为空")
            }
            data = d
        case .stream(let stream):
            data = try await retryAsync(maxRetries: 1) {
                try await stream.readToEndAsync() ?? Data()
            }
        case .noStream:
            data = Data()
        }

        try data.write(to: destination, options: .atomic)
        progressHandler(100)
    }

    // MARK: - Delete

    func deleteFile(key: String) async throws {
        guard let client, let config else { throw R2Error.notConnected }

        let input = DeleteObjectInput(bucket: config.bucket, key: key)
        _ = try await client.deleteObject(input: input)
    }

    // MARK: - Share (presigned URL)

    func generateShareURL(key: String, expiresIn: TimeInterval = 3600) async throws -> URL {
        guard let config else { throw R2Error.notConnected }
        guard !key.isEmpty else { throw R2Error.shareFailed("文件名为空") }

        let signing = SigV4Signer(
            accessKey: config.accessKeyId,
            secretKey: config.secretAccessKey,
            region: config.region,
            service: "s3"
        )

        // URL-encode the key for R2's S3-compatible API
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let host = "\(config.bucket).\(config.accountId).r2.cloudflarestorage.com"
        let path = "/\(encodedKey)"

        return signing.presignURL(
            method: "GET",
            host: host,
            path: path,
            expires: Int(expiresIn)
        )
    }

    // MARK: - Retry helper

    private func retryAsync<T>(maxRetries: Int, operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < maxRetries {
                    // Exponential backoff: 1s, 2s, 4s...
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError ?? R2Error.uploadFailed("重试失败")
    }
}

// MARK: - Errors

enum R2Error: Error, LocalizedError {
    case notConnected
    case uploadFailed(String)
    case downloadFailed(String)
    case deleteFailed(String)
    case shareFailed(String)
    case featureNotImplemented

    var errorDescription: String? {
        switch self {
        case .notConnected: return "未连接到 R2，请先解锁"
        case .uploadFailed(let msg): return "上传失败: \(msg)"
        case .downloadFailed(let msg): return "下载失败: \(msg)"
        case .deleteFailed(let msg): return "删除失败: \(msg)"
        case .shareFailed(let msg): return "分享失败: \(msg)"
        case .featureNotImplemented: return "该功能尚未实现"
        }
    }
}
