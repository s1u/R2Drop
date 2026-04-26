import Foundation

/// Represents a file stored on Cloudflare R2
struct R2File: Identifiable, Hashable {
    let key: String
    let size: Int64
    let lastModified: Date
    let etag: String

    var id: String { key }
    var fileName: String { (key as NSString).lastPathComponent }
    var fileExtension: String { (fileName as NSString).pathExtension }
    var sizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    /// Determine file type category for display
    var fileCategory: FileCategory {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg":
            return .image
        case "mp4", "mov", "avi", "mkv", "webm":
            return .video
        case "mp3", "wav", "flac", "aac", "m4a":
            return .audio
        case "pdf":
            return .pdf
        case "zip", "rar", "7z", "tar", "gz":
            return .archive
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx":
            return .document
        default:
            return .other
        }
    }
}

enum FileCategory: String, CaseIterable {
    case image = "图片"
    case video = "视频"
    case audio = "音频"
    case pdf = "PDF"
    case archive = "压缩包"
    case document = "文档"
    case other = "其他"

    var icon: String {
        switch self {
        case .image: return "photo"
        case .video: return "video"
        case .audio: return "music.note"
        case .pdf: return "doc.richtext"
        case .archive: return "archivebox"
        case .document: return "doc.text"
        case .other: return "doc"
        }
    }
}

/// List of files returned from R2
struct R2FileList {
    let files: [R2File]
    let isTruncated: Bool
    let nextContinuationToken: String?
}
