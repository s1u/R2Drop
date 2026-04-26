import Foundation
import AWSS3
import AWSClientRuntime
import Combine

/// Main service for interacting with Cloudflare R2 (S3-compatible API)
final actor R2Service {
    private var client: S3Client?
    private var config: R2Config?

    let progressSubject = PassthroughSubject<TransferProgress, Never>()
    let fileListSubject = PassthroughSubject<[R2File], Never>()

    /// Connect to R2 with decrypted config
    func connect(config: R2Config) async throws {
        self.config = config
        let endpoint = config.endpoint

        let credentials = try AWSCredentialsProvider(
            accessKey: config.accessKeyId,
            secret: config.secretAccessKey
        )

        let s3Config = try await S3Client.S3ClientConfiguration(
            region: config.region,
            endpoint: endpoint,
            credentialsProvider: credentials,
            signingService: "s3",
            // Force path-style addressing for R2 compatibility
            usePathStyle: true
        )

        client = S3Client(config: s3Config)

        // Verify connection by listing buckets
        _ = try await client?.listBuckets(input: ListBucketsInput())
    }

    /// Disconnect and clear credentials from memory
    func disconnect() {
        client = nil
        config = nil
    }

    var isConnected: Bool { client != nil }

    // MARK: - List Files

    /// List all files in the bucket with pagination
    func listFiles(prefix: String = "", maxKeys: Int32 = 1000,
                   continuationToken: String? = nil) async throws -> R2FileList {
        guard let client, let config else { throw R2Error.notConnected }

        let input = ListObjectsV2Input(
            bucket: config.bucket,
            continuationToken: continuationToken,
            maxKeys: maxKeys,
            prefix: prefix
        )

        let output = try await client.listObjectsV2(input: input)

        let files = (output.contents ?? []).compactMap { obj -> R2File? in
            guard let key = obj.key, let lastMod = obj.lastModified else { return nil }
            return R2File(
                key: key,
                size: obj.size ?? 0,
                lastModified: lastMod,
                etag: obj.eTag ?? ""
            )
        }

        return R2FileList(
            files: files,
            isTruncated: output.isTruncated ?? false,
            nextContinuationToken: output.nextContinuationToken
        )
    }

    /// List all files (auto-paginated)
    func listAllFiles() async throws -> [R2File] {
        var allFiles: [R2File] = []
        var token: String? = nil

        repeat {
            let result = try await listFiles(continuationToken: token)
            allFiles.append(contentsOf: result.files)
            token = result.isTruncated ? result.nextContinuationToken : nil
        } while token != nil

        return allFiles
    }

    // MARK: - Upload

    /// Upload a file from local URL. Returns when upload completes.
    func upload(fileURL: URL, progressHandler: @escaping (Double) -> Void) async throws {
        guard let client, let config else { throw R2Error.notConnected }

        let fileData = try Data(contentsOf: fileURL)
        let key = fileURL.lastPathComponent
        let fileSize = Int64(fileData.count)

        // Build the multipart upload input
        let createInput = CreateMultipartUploadInput(
            bucket: config.bucket,
            key: key
        )

        let createOutput = try await client.createMultipartUpload(input: createInput)
        guard let uploadId = createOutput.uploadId else {
            throw R2Error.uploadFailed("Failed to get upload ID")
        }

        // For files < 50MB, use single part upload
        if fileSize < 50_000_000 {
            try await singlePartUpload(key: key, data: fileData, progressHandler: progressHandler)
            return
        }

        // Multipart upload for larger files
        let partSize: Int64 = 10_000_000 // 10MB per part
        var partNumber: Int32 = 1
        var completedParts: [S3ClientTypes.CompletedPart] = []
        var bytesUploaded: Int64 = 0

        for offset in stride(from: Int64(0), to: fileSize, by: partSize) {
            let chunkSize = min(partSize, fileSize - offset)
            let chunk = fileData[Int(offset)..<Int(offset + chunkSize)]

            let uploadPartInput = UploadPartInput(
                body: .data(chunk),
                bucket: config.bucket,
                key: key,
                partNumber: partNumber,
                uploadId: uploadId
            )

            let uploadOutput = try await client.uploadPart(input: uploadPartInput)
            guard let etag = uploadOutput.eTag else {
                throw R2Error.uploadFailed("Missing ETag for part \(partNumber)")
            }

            completedParts.append(S3ClientTypes.CompletedPart(
                eTag: etag,
                partNumber: partNumber
            ))

            bytesUploaded += chunkSize
            progressHandler(Double(bytesUploaded) / Double(fileSize) * 100)
            partNumber += 1
        }

        // Complete the multipart upload
        let completeInput = CompleteMultipartUploadInput(
            bucket: config.bucket,
            key: key,
            multipartUpload: S3ClientTypes.CompletedMultipartUpload(
                parts: completedParts
            ),
            uploadId: uploadId
        )

        _ = try await client.completeMultipartUpload(input: completeInput)
    }

    private func singlePartUpload(key: String, data: Data,
                                  progressHandler: @escaping (Double) -> Void) async throws {
        guard let client, let config else { throw R2Error.notConnected }

        // Simulate progress for single upload (send 100% at end)
        let input = PutObjectInput(
            body: .data(data),
            bucket: config.bucket,
            key: key
        )

        _ = try await client.putObject(input: input)
        progressHandler(100)
    }

    // MARK: - Download

    /// Download a file from R2. Returns local temp URL.
    /// - Parameters:
    ///   - key: R2 object key
    ///   - destination: Local file URL to write to
    ///   - progressHandler: Progress callback (0-100)
    func download(key: String, destination: URL,
                  progressHandler: @escaping (Double) -> Void) async throws {
        guard let client, let config else { throw R2Error.notConnected }

        let input = GetObjectInput(
            bucket: config.bucket,
            key: key
        )

        let output = try await client.getObject(input: input)

        guard let body = output.body else {
            throw R2Error.downloadFailed("Empty response body")
        }

        // Stream data to file with progress
        var buffer = Data()
        for try await chunk in body {
            buffer.append(chunk)
            let progress = Double(buffer.count) / Double(output.contentLength ?? Int64(buffer.count)) * 100
            progressHandler(min(progress, 100))
        }

        try buffer.write(to: destination, options: .atomic)
        progressHandler(100)
    }

    // MARK: - Delete

    func deleteFile(key: String) async throws {
        guard let client, let config else { throw R2Error.notConnected }

        let input = DeleteObjectInput(
            bucket: config.bucket,
            key: key
        )

        _ = try await client.deleteObject(input: input)
    }

    // MARK: - Share (presigned URL)

    /// Generate a presigned URL for sharing (valid for specified duration)
    func generateShareURL(key: String, expiresIn: TimeInterval = 3600) throws -> URL {
        // For now, return a placeholder. Full presigned URL generation
        // requires additional AWS SDK setup
        throw R2Error.featureNotImplemented
    }
}

// MARK: - Errors

enum R2Error: Error, LocalizedError {
    case notConnected
    case uploadFailed(String)
    case downloadFailed(String)
    case deleteFailed(String)
    case featureNotImplemented

    var errorDescription: String? {
        switch self {
        case .notConnected: return "未连接到 R2，请先解锁"
        case .uploadFailed(let msg): return "上传失败: \(msg)"
        case .downloadFailed(let msg): return "下载失败: \(msg)"
        case .deleteFailed(let msg): return "删除失败: \(msg)"
        case .featureNotImplemented: return "该功能尚未实现"
        }
    }
}
