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

    private var cancellables = Set<AnyCancellable>()

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
            // Load files immediately
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
        Task { await r2Service.disconnect() }
    }

    // MARK: - File List Actions

    func refreshFileList() async {
        isLoadingFiles = true
        fileListError = nil
        do {
            let allFiles = try await r2Service.listAllFiles()
            files = allFiles.sorted { $0.lastModified > $1.lastModified }
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
        let progress = TransferProgress(
            fileName: url.lastPathComponent,
            fileSize: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
            bytesTransferred: 0,
            status: .waiting,
            direction: .upload
        )

        // Simulate initial progress
        await MainActor.run {
            transfers.append(progress)
            showTransferPanel = true
        }

        do {
            await updateTransfer(id: progress.id, status: .uploading)
            try await r2Service.upload(fileURL: url) { [weak self] pct in
                Task { @MainActor in
                    guard let idx = self?.transfers.firstIndex(where: { $0.id == progress.id }) else { return }
                    self?.transfers[idx].bytesTransferred = Int64(Double(progress.fileSize) * pct / 100.0)
                    self?.transfers[idx].status = .uploading
                }
            }

            // Generate presigned URL for QR code
            let fileName = url.lastPathComponent
            let shareURL = try? await r2Service.generateShareURL(key: fileName, expiresIn: 3600)

            await MainActor.run {
                guard let idx = transfers.firstIndex(where: { $0.id == progress.id }) else { return }
                transfers[idx].status = .completed
                transfers[idx].shareURL = shareURL?.absoluteString
            }

            await refreshFileList()
        } catch {
            await updateTransfer(id: progress.id, status: .failed(error.localizedDescription))
        }
    }

    func downloadFile(file: R2File, to destination: URL) async {
        let progress = TransferProgress(
            fileName: file.fileName,
            fileSize: file.size,
            bytesTransferred: 0,
            status: .waiting,
            direction: .download
        )

        await MainActor.run {
            transfers.append(progress)
            showTransferPanel = true
        }

        do {
            await updateTransfer(id: progress.id, status: .downloading)
            try await r2Service.download(key: file.key, destination: destination) { [weak self] pct in
                Task { @MainActor in
                    guard let idx = self?.transfers.firstIndex(where: { $0.id == progress.id }) else { return }
                    self?.transfers[idx].bytesTransferred = Int64(Double(file.size) * pct / 100.0)
                    self?.transfers[idx].status = .downloading
                }
            }
            await updateTransfer(id: progress.id, status: .completed)
        } catch {
            await updateTransfer(id: progress.id, status: .failed(error.localizedDescription))
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
    private func updateTransfer(id: UUID, status: TransferStatus) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].status = status
    }
}
