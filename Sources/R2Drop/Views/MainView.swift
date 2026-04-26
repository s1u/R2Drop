import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MainView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VSplitView {
            // Top: Drop zone + file list
            VStack(spacing: 0) {
                // Drop zone
                DropZoneView()
                    .environmentObject(appState)

                // File list
                FileListView()
                    .environmentObject(appState)
            }

            // Bottom: Transfer progress panel
            if appState.showTransferPanel {
                TransferPanelView()
                    .environmentObject(appState)
                    .frame(height: 200)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

// MARK: - Drop Zone (Upload)

struct DropZoneView: View {
    @EnvironmentObject var appState: AppState
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isTargeted ? Color.blue : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.blue.opacity(0.05) : Color.clear)
                )

            VStack(spacing: 8) {
                Image(systemName: "cloud.arrow.up.fill")
                    .font(.system(size: 28))
                    .foregroundColor(isTargeted ? .blue : .secondary)

                Text(isTargeted ? "松手上传" : "拖拽文件到此处上传")
                    .font(.subheadline)
                    .foregroundColor(isTargeted ? .blue : .secondary)
            }
        }
        .frame(height: 80)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers -> Bool in
            handleDroppedFiles(providers)
            return true
        }
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    await appState.uploadFile(url: url)
                }
            }
        }
    }
}

// MARK: - File List (with drag-out download)

struct FileListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedFile: R2File?
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("R2 文件")
                    .font(.headline)

                Spacer()

                // Search
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("搜索文件...", text: $appState.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                .frame(width: 200)
                .padding(6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)

                Button(action: {
                    Task { await appState.refreshFileList() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新")

                Button("锁定") {
                    appState.lock()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // File count info
            HStack {
                Text("共 \(appState.filteredFiles.count) 个文件")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            if appState.isLoadingFiles && appState.files.isEmpty {
                Spacer()
                ProgressView("正在加载文件列表...")
                Spacer()
            } else if let error = appState.fileListError {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                    Button("重试") {
                        Task { await appState.refreshFileList() }
                    }
                }
                Spacer()
            } else if appState.filteredFiles.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(appState.searchQuery.isEmpty ? "暂无文件，拖拽文件到上方区域上传" : "没有匹配的文件")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(appState.filteredFiles) { file in
                            FileRow(file: file, selectedFile: $selectedFile)
                                .environmentObject(appState)
                                .onTapGesture {
                                    selectedFile = file
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }
}

// MARK: - File Row

struct FileRow: View {
    @EnvironmentObject var appState: AppState
    let file: R2File
    @Binding var selectedFile: R2File?
    @State private var isDragging = false
    @State private var isDownloading = false
    @State private var shareURL: String?
    @State private var isGeneratingQR = false
    @State private var showQRCode = false

    var isSelected: Bool { selectedFile?.id == file.id }

    var body: some View {
        HStack(spacing: 12) {
            // File icon
            Image(systemName: file.fileCategory.icon)
                .font(.title3)
                .foregroundColor(fileIconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Text(file.sizeFormatted)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(file.lastModifiedFormatted)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 6) {
                if isDownloading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 20)
                }

                // QR Code button
                Button(action: shareFile) {
                    if isGeneratingQR {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "qrcode")
                            .foregroundColor(.blue)
                    }
                }
                .buttonStyle(.plain)
                .help("分享二维码")
                .disabled(isGeneratingQR)

                Button(action: downloadFile) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help("下载")

                Button(action: { confirmDelete() }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("删除")
                .alert("确认删除", isPresented: $showingDeleteAlert) {
                    Button("取消", role: .cancel) {}
                    Button("删除", role: .destructive) {
                        Task { await appState.deleteFile(file: file) }
                    }
                } message: {
                    Text("确定要删除「\(file.fileName)」吗？此操作不可恢复。")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue.opacity(0.08) : Color.clear)
        )
        // Drag out to download
        .onDrag {
            isDownloading = true
            Task {
                let dest = FileHelper.uniqueDownloadURL(for: file.fileName)
                await appState.downloadFile(file: file, to: dest)
                await MainActor.run { isDownloading = false }
            }
            return NSItemProvider(object: file.fileName as NSString)
        }
        // QR code sheet
        .sheet(isPresented: $showQRCode) {
            if let url = shareURL {
                FileQRCodeView(fileName: file.fileName, shareURL: url)
            }
        }
    }

    @State private var showingDeleteAlert = false

    private var fileIconColor: Color {
        switch file.fileCategory {
        case .image: return .green
        case .video: return .purple
        case .audio: return .pink
        case .pdf: return .red
        case .archive: return .orange
        case .document: return .blue
        case .other: return .gray
        }
    }

    private func shareFile() {
        isGeneratingQR = true
        Task {
            do {
                let url = try await appState.r2Service.generateShareURL(key: file.key, expiresIn: 3600)
                await MainActor.run {
                    shareURL = url.absoluteString
                    isGeneratingQR = false
                    showQRCode = true
                }
            } catch {
                await MainActor.run {
                    isGeneratingQR = false
                }
            }
        }
    }

    private func downloadFile() {
        isDownloading = true
        Task {
            let dest = FileHelper.uniqueDownloadURL(for: file.fileName)
            await appState.downloadFile(file: file, to: dest)
            await MainActor.run { isDownloading = false }
        }
    }

    private func confirmDelete() {
        showingDeleteAlert = true
    }
}

// MARK: - Transfer Panel

struct TransferPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var showQRCode: TransferProgress?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("传输队列")
                    .font(.headline)
                Spacer()
                Button("清除已完成") {
                    appState.transfers.removeAll { t in
                        if case .completed = t.status { return true }
                        return false
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)

                Button("关闭") {
                    appState.showTransferPanel = false
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(appState.transfers) { transfer in
                        TransferRow(transfer: transfer, showQR: $showQRCode)
                    }
                }
                .padding(8)
            }
        }
        // QR Code popover
        .sheet(item: $showQRCode) { transfer in
            QRCodePopoverView(transfer: transfer)
                .environmentObject(appState)
        }
    }
}

struct TransferRow: View {
    let transfer: TransferProgress
    @Binding var showQR: TransferProgress?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundColor(transfer.direction == .upload ? .blue : .green)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.fileName)
                    .font(.caption)
                    .lineLimit(1)

                ProgressView(value: transfer.percentage, total: 100)
                    .progressViewStyle(.linear)
                    .tint(transferColor)
                    .frame(height: 6)

                HStack {
                    Text(transfer.percentageFormatted)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(transfer.sizeFormatted)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()

                    // QR Code button (only for completed uploads)
                    if transfer.direction == .upload,
                       case .completed = transfer.status,
                       transfer.shareURL != nil {
                        Button(action: { showQR = transfer }) {
                            Image(systemName: "qrcode")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("显示二维码")
                    }

                    if case .failed(let error) = transfer.status {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var transferColor: Color {
        switch transfer.status {
        case .completed: return .green
        case .failed: return .red
        case .uploading, .downloading: return .blue
        case .waiting: return .gray
        }
    }
}

// MARK: - QR Code Popover

struct QRCodePopoverView: View {
    @EnvironmentObject var appState: AppState
    let transfer: TransferProgress
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: NSImage?
    @State private var showCopyToast = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("分享文件")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.caption)
            }

            Text(transfer.fileName)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)

            if let qrImage {
                Image(nsImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 200, height: 200)
            } else {
                ProgressView("生成二维码中...")
                    .frame(width: 200, height: 200)
            }

            // Share URL (truncated)
            if let url = transfer.shareURL {
                HStack {
                    Text(url)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        showCopyToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showCopyToast = false
                        }
                    }) {
                        Image(systemName: showCopyToast ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(showCopyToast ? .green : .blue)
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
            }

            Text("链接有效期 1 小时，扫码或复制链接即可下载")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("拷贝链接并关闭") {
                if let url = transfer.shareURL {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if showCopyToast {
                Text("已复制到剪贴板")
                    .font(.caption)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            generateQR()
        }
    }

    private func generateQR() {
        guard let urlString = transfer.shareURL else {
            qrImage = QRCodeGenerator.generate(from: "No URL available")
            return
        }
        qrImage = QRCodeGenerator.generate(from: urlString)
    }
}

// MARK: - File QR Code View (from file list)

/// QR code popover for existing files in the file list
struct FileQRCodeView: View {
    let fileName: String
    let shareURL: String
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: NSImage?
    @State private var showCopyToast = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("分享文件")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.caption)
            }

            Text(fileName)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)

            if let qrImage {
                Image(nsImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 200, height: 200)
            } else {
                ProgressView("生成二维码中...")
                    .frame(width: 200, height: 200)
            }

            // Share URL
            HStack {
                Text(shareURL)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shareURL, forType: .string)
                    showCopyToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopyToast = false
                    }
                }) {
                    Image(systemName: showCopyToast ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(showCopyToast ? .green : .blue)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            Text("链接有效期 1 小时，扫码或复制链接即可下载")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("复制链接并关闭") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shareURL, forType: .string)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if showCopyToast {
                Text("已复制到剪贴板")
                    .font(.caption)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            qrImage = QRCodeGenerator.generate(from: shareURL)
        }
    }
}


// MARK: - Date Formatting

extension R2File {
    var lastModifiedFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: lastModified, relativeTo: Date())
    }
}
