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

    // MARK: - File List
    @Published var files: [R2File] = []
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

    // MARK: - Auth Actions

    func unlock(masterPassword: String) async {
        do {
            let config = try cryptoService.loadCredentials(masterPassword: masterPassword)
            try await r2Service.connect(config: config)
            isUnlocked = true
            loginError = nil
            await refreshFileList()
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
            await refreshFileList()
        } catch {
            loginError = error.localizedDescription
        }
    }

    func lock() {
        isUnlocked = false
        files = []
        searchQuery = ""
        transfers = []
        showTransferPanel = false
        Task { await r2Service.disconnect() }
    }

    // MARK: - File List Actions

    func refreshFileList() async {
        isLoadingFiles = true
        fileListError = nil
        do {
            let allFiles = try await r2Service.listAllFiles()
            files = allFiles
        } catch {
            fileListError = error.localizedDescription
        }
        isLoadingFiles = false
    }

    var filteredFiles: [R2File] {
        if searchQuery.isEmpty { return files }
        return files.filter { $0.fileName.localizedCaseInsensitiveContains(searchQuery) }
    }

    // MARK: - Transfer Actions

    func uploadFile(url: URL) async {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let progressId = UUID()
        let fileName = url.lastPathComponent

        // Add initial progress entry
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
            try await r2Service.upload(fileURL: url) { [weak self, progressId, fileSize] pct in
                Task { @MainActor [weak self] in
                    guard let self, let idx = self.transfers.firstIndex(where: { $0.id == progressId }) else { return }
                    self.transfers[idx].bytesTransferred = Int64(Double(fileSize) * pct / 100.0)
                    self.transfers[idx].status = .uploading
                }
            }

            // Generate presigned URL for QR code
            let shareURL = try? await r2Service.generateShareURL(key: fileName, expiresIn: 3600)

            await MainActor.run {
                guard let idx = transfers.firstIndex(where: { $0.id == progressId }) else { return }
                transfers[idx].status = .completed
                transfers[idx].shareURL = shareURL?.absoluteString
            }

            await refreshFileList()
        } catch {
            await updateTransferStatus(id: progressId, status: .failed(error.localizedDescription))
        }
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

            // Reveal in Finder
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
            await refreshFileList()
        } catch {
            await MainActor.run { fileListError = error.localizedDescription }
        }
    }

    // MARK: - Private

    @MainActor
    private func updateTransferStatus(id: UUID, status: TransferStatus) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].status = status
    }
}
