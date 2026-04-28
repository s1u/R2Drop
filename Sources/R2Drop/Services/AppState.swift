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
            // Relative path from the root of the dropped folder
            let relativePath = fileURL.pathComponents.dropFirst(url.pathComponents.count).joined(separator: "/")
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
            await refreshFolderContents()
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
