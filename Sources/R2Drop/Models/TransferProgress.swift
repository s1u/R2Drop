import Foundation

/// Upload or download progress state
struct TransferProgress: Identifiable {
    let id: UUID
    let fileName: String
    let fileSize: Int64
    var bytesTransferred: Int64
    var status: TransferStatus
    let direction: TransferDirection
    /// Presigned URL for sharing (set on upload completion)
    var shareURL: String?

    init(id: UUID = UUID(), fileName: String, fileSize: Int64, bytesTransferred: Int64, status: TransferStatus, direction: TransferDirection, shareURL: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.bytesTransferred = bytesTransferred
        self.status = status
        self.direction = direction
        self.shareURL = shareURL
    }

    var percentage: Double {
        guard fileSize > 0 else { return 0 }
        return min(Double(bytesTransferred) / Double(fileSize) * 100, 100)
    }

    var percentageFormatted: String {
        String(format: "%.1f%%", percentage)
    }

    var speedFormatted: String {
        // speed measured externally, computed in service
        "计算中..."
    }

    var sizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytesTransferred) + " / " +
               formatter.string(fromByteCount: fileSize)
    }
}

enum TransferStatus {
    case waiting
    case uploading
    case downloading
    case completed
    case failed(String)
}

enum TransferDirection {
    case upload
    case download
}
