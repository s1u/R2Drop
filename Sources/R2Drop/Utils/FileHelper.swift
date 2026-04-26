import Foundation
import UniformTypeIdentifiers

/// Helper for file operations
enum FileHelper {

    /// Get the default downloads directory
    static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            ?? FileManager.default.temporaryDirectory
    }

    /// Get a unique file URL in downloads to avoid overwrites
    static func uniqueDownloadURL(for fileName: String) -> URL {
        let downloadsDir = downloadsDirectory
        var url = downloadsDir.appendingPathComponent(fileName)
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let name = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            let newName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            url = downloadsDir.appendingPathComponent(newName)
            counter += 1
        }
        return url
    }

    /// Get file MIME type
    static func mimeType(for url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
