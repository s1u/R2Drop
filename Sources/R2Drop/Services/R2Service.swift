import Foundation
import AWSS3
import AWSClientRuntime
import Combine

/// Main service for interacting with Cloudflare R2 (S3-compatible API)
final actor R2Service {
    private var client: S3Client?
    private var config: R2Config?
    private var s3Config: S3Client.S3ClientConfiguration?

    let progressSubject = PassthroughSubject<TransferProgress, Never>()
    let fileListSubject = PassthroughSubject<[R2File], Never>()

    /// Connect to R2 with decrypted config
    func connect(config: R2Config) async throws {
        self.config = config
        let endpoint = config.endpoint

        let s3Config = try await S3Client.S3ClientConfiguration(
            region: config.region,
            endpoint: endpoint,
            signingService: "s3",
            usePathStyle: true
        )
        self.s3Config = s3Config

        client = S3Client(config: s3Config)

        // Verify connection
        _ = try await client?.listBuckets(input: ListBucketsInput())
    }

    /// Disconnect and clear credentials from memory
    func disconnect() {
        client = nil
        config = nil
        s3Config = nil
    }

    var isConnected: Bool { client != nil }

    // MARK: - List Files

    func listFiles(prefix: String = "", maxKeys: Int = 1000,
                   continuationToken: String? = nil) async throws -> R2FileList {
        guard let client, let config else { throw R2Error.notConnected }

        let input = ListObjectsV2Input(
            bucket: config.bucket,
            continuationToken: continuationToken,
            maxKeys: maxKeys,
            prefix: prefix
        )

        let output = try await client.listObjectsV2(input: input)

        // S3 SDK returns contents as [S3ClientTypes.Object]?
        let contents = output.contents ?? []
        var files: [R2File] = []

        for obj in contents {
            guard let key = obj.key, let lastMod = obj.lastModified else { continue }
            let file = R2File(
                key: key,
                size: obj.size ?? 0,
                lastModified: lastMod,
                etag: obj.eTag ?? ""
            )
            files.append(file)
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

    func upload(fileURL: URL, progressHandler: @escaping (Double) -> Void) async throws {
        guard let client, let config else { throw R2Error.notConnected }

        let fileData = try Data(contentsOf: fileURL)
        let key = fileURL.lastPathComponent
        let fileSize = Int64(fileData.count)

        // Single part upload for files < 50MB
        if fileSize < 50_000_000 {
            let input = PutObjectInput(
                body: .data(fileData),
                bucket: config.bucket,
                key: key
            )
            _ = try await client.putObject(input: input)
            progressHandler(100)
            return
        }

        // Multipart upload for larger files
        let createInput = CreateMultipartUploadInput(
            bucket: config.bucket,
            key: key
        )
        let createOutput = try await client.createMultipartUpload(input: createInput)
        guard let uploadId = createOutput.uploadId else {
            throw R2Error.uploadFailed("无法获取 Upload ID")
        }

        let partSize = 10 * 1024 * 1024 // 10MB per part
        var completedParts: [S3ClientTypes.CompletedPart] = []
        var partNumber: Int = 1
        var bytesUploaded: Int64 = 0

        var offset = 0
        while offset < fileData.count {
            let chunkSize = min(partSize, fileData.count - offset)
            let chunk = fileData[offset..<offset + chunkSize]

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

            bytesUploaded += Int64(chunkSize)
            progressHandler(Double(bytesUploaded) / Double(fileSize) * 100)
            partNumber += 1
            offset += chunkSize
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
        let output = try await client.getObject(input: input)

        guard let body = output.body else {
            throw R2Error.downloadFailed("服务器返回空数据")
        }

        // ByteStream provides data directly
        let data = try await body.readData()
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

    /// Generate a presigned URL for sharing using AWS SigV4.
    func generateShareURL(key: String, expiresIn: TimeInterval = 3600) async throws -> URL {
        guard let config else { throw R2Error.notConnected }
        guard !key.isEmpty else { throw R2Error.shareFailed("文件名为空") }

        let signing = SigV4Signer(
            accessKey: config.accessKeyId,
            secretKey: config.secretAccessKey,
            region: config.region,
            service: "s3"
        )

        let host = "\(config.bucket).\(config.accountId).r2.cloudflarestorage.com"
        let path = "/\(key)"

        return signing.presignURL(
            method: "GET",
            host: host,
            path: path,
            expires: Int(expiresIn)
        )
    }
}

// MARK: - ByteStream async read

extension ByteStream {
    /// Read all data from the stream
    func readData() async throws -> Data {
        var result = Data()
        for try await chunk in self {
            result.append(chunk)
        }
        return result
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
