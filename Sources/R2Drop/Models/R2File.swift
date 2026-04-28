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

    /// Check if this file is an image type (for inline QR)
    var isImageType: Bool {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff", "tif":
            return true
        default:
            return false
        }
    }

    /// Check if this file is a text type (viewable in browser inline)
    var isTextType: Bool {
        switch fileExtension.lowercased() {
        case "txt", "md", "json", "xml", "csv", "log", "yaml", "yml", "html", "css", "js", "ts", "py", "rb", "go", "rs", "swift", "c", "h", "cpp", "hpp", "java", "kt", "sh", "bash", "zsh", "env", "cfg", "ini", "toml", "plist", "strings":
            return true
        default:
            return false
        }
    }

    /// Check if this file is a video type
    var isVideoType: Bool {
        switch fileExtension.lowercased() {
        case "mp4", "mov", "avi", "mkv", "webm", "3gp":
            return true
        default:
            return false
        }
    }
}

/// Represents either a file or a directory in a folder listing
struct R2FolderItem: Identifiable, Hashable {
    enum ItemType: Hashable {
        case file(R2File)
        case directory(String) // directory prefix, e.g. "img/"
    }

    let type: ItemType

    var id: String {
        switch type {
        case .file(let file): return file.id
        case .directory(let prefix): return "dir:\(prefix)"
        }
    }

    var name: String {
        switch type {
        case .file(let file): return file.fileName
        case .directory(let prefix):
            // Remove trailing slash
            let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            return (trimmed as NSString).lastPathComponent
        }
    }

    var isDirectory: Bool {
        if case .directory = type { return true }
        return false
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Extract the underlying R2File if this item is a file
    var asFile: R2File? {
        if case .file(let f) = type { return f }
        return nil
    }

    /// Get the directory prefix if this is a directory
    var directoryPrefix: String? {
        if case .directory(let prefix) = type { return prefix }
        return nil
    }

    static func == (lhs: R2FolderItem, rhs: R2FolderItem) -> Bool {
        lhs.id == rhs.id
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
