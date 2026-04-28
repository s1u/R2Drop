import Foundation
import Combine
import SwiftUI

/// Central app state, shared across views
@MainActor
final class AppState: ObservableObject {
    // MARK: - Auth
    @Published var isUnlocked = false
    @Published var hasCredentials = false
    @Published var loginError: String?

    // MARK: - Folder Navigation
    @Published var folderItems: [R2FolderItem] = []
    @Published var currentPath: String = "" {
        didSet { navigationPath = buildNavigationPath() }
    }
    @Published var navigationPath: [(displayName: String, prefix: String)] = []
    @Published var isLoadingFiles = false
    @Published var fileListError: String?
    @Published var searchQuery = ""

    // MARK: - Transfer
    @Published var transfers: [TransferProgress] = []
    @Published var showTransferPanel = false

    // MARK: - Services
    let cryptoService = CryptoService()
    let r2Service = R2Service()

    init() {
        hasCredentials = cryptoService.hasStoredCredentials
    }

    // MARK: - Navigation Helpers

    private func buildNavigationPath() -> [(displayName: String, prefix: String)] {
        guard !currentPath.isEmpty else { return [] }
        let components = currentPath.split(separator: "/", omittingEmptySubsequences: true)
        var result: [(displayName: String, prefix: String)] = []
        var accumulated = ""
        for comp in components {
            accumulated += "\(comp)/"
            result.append((String(comp), accumulated))
        }
        return result
    }

    /// Navigate into a subdirectory
    func navigateTo(directory prefix: String) {
        guard prefix != currentPath else { return }
        currentPath = prefix
        Task { await refreshFolderContents() }
    }

    /// Navigate to a breadcrumb level
    func navigateToBreadcrumb(prefix: String) {
        guard prefix != currentPath else { return }
        currentPath = prefix
        Task { await refreshFolderContents() }
    }

    /// Go back to parent directory
    func navigateUp() {
        guard !currentPath.isEmpty else { return }
        let trimmed = currentPath.hasSuffix("/") ? String(currentPath.dropLast()) : currentPath
        let parent = (trimmed as NSString).deletingLastPathComponent
        currentPath = parent.isEmpty ? "" : "\(parent)/"
        Task { await refreshFolderContents() }
    }

    // MARK: - Auth Actions

    func unlock(masterPassword: String) async {
        do {
            let config = try cryptoService.loadCredentials(masterPassword: masterPassword)
            try await r2Service.connect(config: config)
            isUnlocked = true
            loginError = nil
            await refreshFolderContents()
        } catch {
            loginError = error.localizedDescription
        }
    }

    func setupCredentials(config: R2Config, masterPassword: String) async {
        do {
            try cryptoService.storeCredentials(config, masterPassword: masterPassword)
            try await r2Service.connect(config: config)
            isUnlocked = true
            hasCredentials = true
            loginError = nil
            await refreshFolderContents()
        } catch {
            loginError = error.localizedDescription
        }
    }

    func lock() {
        isUnlocked = false
        folderItems = []
        currentPath = ""
        navigationPath = []
        searchQuery = ""
        transfers = []
        showTransferPanel = false
        Task { await r2Service.disconnect() }
    }

    // MARK: - File List Actions

    func refreshFolderContents() async {
        isLoadingFiles = true
        fileListError = nil
        do {
            let (items, _, _) = try await r2Service.listFolderContents(prefix: currentPath, continuationToken: nil)
            folderItems = items
        } catch {
            fileListError = error.localizedDescription
        }
        isLoadingFiles = false
    }

    var filteredItems: [R2FolderItem] {
        if searchQuery.isEmpty { return folderItems }
        return folderItems.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    // MARK: - Transfer Actions

    /// Upload a single file (preserving current folder path as prefix)
    func uploadFile(url: URL) async {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let progressId = UUID()
        let fileName = url.lastPathComponent

        // Build key with current folder prefix
        let key = currentPath.isEmpty ? fileName : "\(currentPath)\(fileName)"

        await MainActor.run {
            let progress = TransferProgress(
                id: progressId,
                fileName: fileName,
                fileSize: fileSize,
                bytesTransferred: 0,
                status: .waiting,
                direction: .upload,
                shareURL: nil
            )
            transfers.append(progress)
            showTransferPanel = true
        }

        await updateTransferStatus(id: progressId, status: .uploading)

        do {
            try await r2Service.upload(fileURL: url, key: key) { [weak self, progressId, fileSize] pct in
                Task { @MainActor [weak self] in
                    guard let self, let idx = self.transfers.firstIndex(where: { $0.id == progressId }) else { return }
                    self.transfers[idx].bytesTransferred = Int64(Double(fileSize) * pct / 100.0)
                    self.transfers[idx].status = .uploading
                }
            }

            let shareURL = try? await r2Service.generateShareURL(key: key, expiresIn: 3600,
                inline: isImageExtension(fileName))

            await MainActor.run {
                guard let idx = transfers.firstIndex(where: { $0.id == progressId }) else { return }
                transfers[idx].status = .completed
                transfers[idx].shareURL = shareURL?.absoluteString
            }

            // Small delay to let R2 index the new file before refreshing
            try? await Task.sleep(nanoseconds: 300_000_000)
            await refreshFolderContents()
        } catch {
            await updateTransferStatus(id: progressId, status: .failed(error.localizedDescription))
        }
    }

    /// Upload all files in a directory recursively (preserves relative structure)
    func uploadFolder(url: URL) async {
        let fileManager = FileManager.default
        let folderName = url.lastPathComponent

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let basePrefix = currentPath.isEmpty ? "" : currentPath
        var pendingFiles: [(relativePath: String, fullURL: URL)] = []

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDir = resourceValues.isDirectory,
                  !isDir else { continue }
            // Relative path from the root of the dropped folder, including folder name
            let relativePath = fileURL.pathComponents.dropFirst(url.pathComponents.count - 1).joined(separator: "/")
            let key = "\(basePrefix)\(relativePath)"
            pendingFiles.append((relativePath, fileURL))
        }

        guard !pendingFiles.isEmpty else { return }

        // Show bulk upload notification
        let totalFiles = pendingFiles.count
        await MainActor.run {
            let progress = TransferProgress(
                id: UUID(),
                fileName: "📁 \(folderName) (\(totalFiles) 个文件)",
                fileSize: Int64(totalFiles),
                bytesTransferred: 0,
                status: .uploading,
                direction: .upload,
                shareURL: nil
            )
            transfers.append(progress)
            showTransferPanel = true
        }

        var completedCount = 0
        for (relativePath, fileURL) in pendingFiles {
            let key = "\(basePrefix)\(relativePath)"
            do {
                try await r2Service.upload(fileURL: fileURL, key: key) { _ in }
                completedCount += 1
                // Update bulk progress
                await MainActor.run {
                    if let idx = transfers.firstIndex(where: { $0.fileName.hasPrefix("📁") }) {
                        transfers[idx].bytesTransferred = Int64(completedCount)
                        let pct = Double(completedCount) / Double(totalFiles) * 100
                        transfers[idx].status = .uploading
                    }
                }
            } catch {
                // Log individual file failure but continue with remaining files
                print("Upload failed for \(relativePath): \(error)")
            }
        }

        await MainActor.run {
            if let idx = transfers.firstIndex(where: { $0.fileName.hasPrefix("📁") }) {
                transfers[idx].status = .completed
                transfers[idx].bytesTransferred = Int64(totalFiles)
            }
        }

        // Small delay to let R2 index the new files before refreshing
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refreshFolderContents()
    }

    func downloadFile(file: R2File, to destination: URL) async {
        let progressId = UUID()

        await MainActor.run {
            let progress = TransferProgress(
                id: progressId,
                fileName: file.fileName,
                fileSize: file.size,
                bytesTransferred: 0,
                status: .waiting,
                direction: .download,
                shareURL: nil
            )
            transfers.append(progress)
            showTransferPanel = true
        }

        await updateTransferStatus(id: progressId, status: .downloading)

        do {
            try await r2Service.download(key: file.key, destination: destination) { [progressId, fileSize = file.size] pct in
                Task { @MainActor in
                    guard let idx = self.transfers.firstIndex(where: { $0.id == progressId }) else { return }
                    self.transfers[idx].bytesTransferred = Int64(Double(fileSize) * pct / 100.0)
                    self.transfers[idx].status = .downloading
                }
            }
            await updateTransferStatus(id: progressId, status: .completed)

            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        } catch {
            await updateTransferStatus(id: progressId, status: .failed(error.localizedDescription))
        }
    }

    func deleteFile(file: R2File) async {
        do {
            try await r2Service.deleteFile(key: file.key)
            try? await Task.sleep(nanoseconds: 200_000_000)
            await refreshFolderContents()
        } catch {
            await MainActor.run { fileListError = error.localizedDescription }
        }
    }

    /// Download all files in a folder prefix to a local temp zip archive
    func downloadFolder(prefix: String, folderName: String) async {
        let progressId = UUID()

        // First, list all files in the folder recursively
        await MainActor.run {
            let progress = TransferProgress(
                id: progressId,
                fileName: folderName,
                fileSize: 0,
                bytesTransferred: 0,
                status: .waiting,
                direction: .download,
                shareURL: nil
            )
            transfers.append(progress)
            showTransferPanel = true
        }

        await updateTransferStatus(id: progressId, status: .downloading)

        do {
            // List all files with this prefix (handle pagination)
            var allFiles: [R2File] = []
            var nextToken: String? = nil
            repeat {
                let fileList = try await r2Service.listFiles(prefix: prefix, continuationToken: nextToken)
                allFiles.append(contentsOf: fileList.files)
                nextToken = fileList.nextContinuationToken
            } while nextToken != nil

            guard !allFiles.isEmpty else {
                await updateTransferStatus(id: progressId, status: .failed("文件夹为空"))
                return
            }

            // Create a temp directory for download
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let totalBytes = allFiles.reduce(Int64(0)) { $0 + $1.size }

            await MainActor.run {
                guard let idx = transfers.firstIndex(where: { $0.id == progressId }) else { return }
                transfers[idx].fileSize = totalBytes
            }

            // Download each file preserving folder structure
            var downloadedBytes: Int64 = 0
            for file in allFiles {
                // Compute relative path within the folder
                var relativePath = file.key
                if relativePath.hasPrefix(prefix) {
                    relativePath = String(relativePath.dropFirst(prefix.count))
                }
                if relativePath.isEmpty {
                    relativePath = file.fileName
                }
                let destURL = tempDir.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                try await r2Service.download(key: file.key, destination: destURL) { [progressId] pct in
                    Task { @MainActor [weak self] in
                        guard let self, let idx = self.transfers.firstIndex(where: { $0.id == progressId }) else { return }
                        let fileBytes = Int64(Double(file.size) * pct / 100.0)
                        self.transfers[idx].bytesTransferred = downloadedBytes + fileBytes
                    }
                }
                downloadedBytes += file.size
            }

            // Create a zip archive
            let zipURL = FileHelper.uniqueDownloadURL(for: "\(folderName).zip")
            let coordinator = NSFileCoordinator()
            var zipError: NSError?
            var zipSuccess = false
            coordinator.coordinate(readingItemAt: tempDir, options: [.forUploading], error: &zipError) { zipTempURL in
                do {
                    if FileManager.default.fileExists(atPath: zipURL.path) {
                        try FileManager.default.removeItem(at: zipURL)
                    }
                    try FileManager.default.moveItem(at: zipTempURL, to: zipURL)
                    zipSuccess = true
                } catch {
                    print("Failed to move zip: \(error)")
                }
            }

            if let error = zipError {
                throw error
            }

            // Clean up temp directory
            try? FileManager.default.removeItem(at: tempDir)

            await updateTransferStatus(id: progressId, status: .completed)

            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([zipURL])
            }
        } catch {
            await updateTransferStatus(id: progressId, status: .failed(error.localizedDescription))
        }
    }

    /// Delete all files under a folder prefix recursively
    func deleteFolder(prefix: String) async {
        do {
            var deleteError: String?
            var nextToken: String? = nil

            repeat {
                let fileList = try await r2Service.listFiles(prefix: prefix, continuationToken: nextToken)
                let files = fileList.files

                for file in files {
                    do {
                        try await r2Service.deleteFile(key: file.key)
                    } catch {
                        deleteError = "删除 \(file.fileName) 失败: \(error.localizedDescription)"
                        break
                    }
                }

                if deleteError != nil { break }
                nextToken = fileList.nextContinuationToken
            } while nextToken != nil

            try? await Task.sleep(nanoseconds: 300_000_000)
            await refreshFolderContents()

            if let error = deleteError {
                await MainActor.run { fileListError = error }
            }
        } catch {
            await MainActor.run { fileListError = error.localizedDescription }
        }
    }

    /// Check if a filename has an image extension
    private func isImageExtension(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff", "tif"].contains(ext)
    }

    // MARK: - Private

    @MainActor
    private func updateTransferStatus(id: UUID, status: TransferStatus) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].status = status
    }
}
