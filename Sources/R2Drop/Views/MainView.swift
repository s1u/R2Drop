import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MainView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                DropZoneView()
                    .environmentObject(appState)

                FileListView()
                    .environmentObject(appState)
            }

            if appState.showTransferPanel {
                TransferPanelView()
                    .environmentObject(appState)
                    .frame(height: 200)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
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

                Text(isTargeted ? "松手上传" : "拖拽文件或文件夹到此处上传")
                    .font(.body)
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
                    // Check if it's a directory
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir {
                        await appState.uploadFolder(url: url)
                    } else {
                        await appState.uploadFile(url: url)
                    }
                }
            }
        }
    }
}

// MARK: - File List (with folder navigation)

struct FileListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedItem: R2FolderItem?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("R2 文件")
                    .font(.title3)

                // Breadcrumb navigation
                if !appState.currentPath.isEmpty {
                    Button(action: {
                        appState.navigateToBreadcrumb(prefix: "")
                    }) {
                        Text("根目录")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("返回根目录")

                    ForEach(appState.navigationPath, id: \.prefix) { crumb in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Button(action: {
                            appState.navigateToBreadcrumb(prefix: crumb.prefix)
                        }) {
                            Text(crumb.displayName)
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                // Back button
                if !appState.currentPath.isEmpty {
                    Button(action: { appState.navigateUp() }) {
                        Image(systemName: "arrow.up")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("返回上级")

                    Divider()
                        .frame(height: 16)
                }

                // Search
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                    TextField("搜索...", text: $appState.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                }
                .frame(width: 200)
                .padding(6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)

                Button(action: {
                    Task { await appState.refreshFolderContents() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新")

                Button("锁定") {
                    appState.lock()
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Item count info
            HStack {
                Text("共 \(appState.filteredItems.count) 项")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            if appState.isLoadingFiles && appState.folderItems.isEmpty {
                Spacer()
                ProgressView("正在加载...")
                Spacer()
            } else if let error = appState.fileListError {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.red)
                    Button("重试") {
                        Task { await appState.refreshFolderContents() }
                    }
                }
                Spacer()
            } else if appState.filteredItems.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(appState.searchQuery.isEmpty ? "暂无文件，拖拽文件到上方区域上传" : "没有匹配的文件")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(appState.filteredItems) { item in
                            ItemRow(item: item, selectedItem: $selectedItem)
                                .environmentObject(appState)
                                .onTapGesture {
                                    selectedItem = item
                                    if item.isDirectory, let prefix = item.directoryPrefix {
                                        appState.navigateTo(directory: prefix)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }
}

// MARK: - Item Row (File or Directory)

struct ItemRow: View {
    @EnvironmentObject var appState: AppState
    let item: R2FolderItem
    @Binding var selectedItem: R2FolderItem?
    @State private var isDownloading = false
    @State private var shareURL: String?
    @State private var isGeneratingQR = false
    @State private var showQRCode = false

    var isSelected: Bool { selectedItem?.id == item.id }

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            if item.isDirectory {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundColor(.blue)
                    .frame(width: 24)
            } else if let file = item.asFile {
                Image(systemName: file.fileCategory.icon)
                    .font(.title3)
                    .foregroundColor(fileIconColor(for: file))
                    .frame(width: 24)
            } else {
                Image(systemName: "doc")
                    .font(.title3)
                    .foregroundColor(.gray)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)

                if let file = item.asFile {
                    HStack(spacing: 12) {
                        Text(file.sizeFormatted)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(file.lastModifiedFormatted)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("目录")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Action buttons (only for files)
            if let file = item.asFile {
                HStack(spacing: 6) {
                    if isDownloading {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 20)
                    }

                    Button(action: { shareFile(file) }) {
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

                    Button(action: { downloadFile(file) }) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("下载")

                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("删除")
                    .alert("确认删除", isPresented: $showDeleteConfirm) {
                        Button("取消", role: .cancel) {}
                        Button("删除", role: .destructive) {
                            Task { await appState.deleteFile(file: file) }
                        }
                    } message: {
                        Text("确定要删除「\(file.fileName)」吗？此操作不可恢复。")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue.opacity(0.08) : Color.clear)
        )
        .onDrag {
            guard let file = item.asFile else { return NSItemProvider() }
            isDownloading = true
            Task {
                let dest = FileHelper.uniqueDownloadURL(for: file.fileName)
                await appState.downloadFile(file: file, to: dest)
                await MainActor.run { isDownloading = false }
            }
            let provider = NSItemProvider(object: "\(file.fileName) (下载完成后可在下载文件夹查看)" as NSString)
            return provider
        }
        .sheet(isPresented: $showQRCode) {
            if let url = shareURL, let file = item.asFile {
                FileQRCodeView(fileName: file.fileName, shareURL: url, isImage: file.isImageType)
            }
        }
    }

    @State private var showDeleteConfirm = false

    private func fileIconColor(for file: R2File) -> Color {
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

    private func shareFile(_ file: R2File) {
        isGeneratingQR = true
        Task {
            do {
                let url = try await appState.r2Service.generateShareURL(key: file.key, expiresIn: 3600, inline: file.isImageType)
                await MainActor.run {
                    shareURL = url.absoluteString
                    isGeneratingQR = false
                    showQRCode = true
                }
            } catch {
                await MainActor.run { isGeneratingQR = false }
            }
        }
    }

    private func downloadFile(_ file: R2File) {
        isDownloading = true
        Task {
            let dest = FileHelper.uniqueDownloadURL(for: file.fileName)
            await appState.downloadFile(file: file, to: dest)
            await MainActor.run { isDownloading = false }
        }
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
                .font(.subheadline)
                .foregroundColor(.secondary)

                Button("关闭") {
                    appState.showTransferPanel = false
                }
                .buttonStyle(.plain)
                .font(.subheadline)
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
                    .font(.subheadline)
                    .lineLimit(1)

                ProgressView(value: transfer.percentage, total: 100)
                    .progressViewStyle(.linear)
                    .tint(transferColor)
                    .frame(height: 6)

                HStack {
                    Text(transfer.percentageFormatted)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(transfer.sizeFormatted)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()

                    if transfer.direction == .upload,
                       case .completed = transfer.status,
                       transfer.shareURL != nil {
                        Button(action: { showQR = transfer }) {
                            Image(systemName: "qrcode")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("显示二维码")
                    }

                    if case .failed(let error) = transfer.status {
                        Text(error)
                            .font(.subheadline)
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
                    .font(.subheadline)
            }

            Text(transfer.fileName)
                .font(.body)
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

            if let url = transfer.shareURL {
                HStack {
                    Text(url)
                        .font(.subheadline)
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
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(showCopyToast ? .green : .blue)
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
            }

            Text(qrHint(for: transfer.fileName))
                .font(.subheadline)
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
            .controlSize(.regular)

            if showCopyToast {
                Text("已复制到剪贴板")
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { generateQR() }
    }

    private func generateQR() {
        guard let urlString = transfer.shareURL else {
            qrImage = QRCodeGenerator.generate(from: "No URL available")
            return
        }
        qrImage = QRCodeGenerator.generate(from: urlString)
    }

    private func isImageExtension(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff", "tif"].contains(ext)
    }
}

// MARK: - File QR Code View (from file list)

struct FileQRCodeView: View {
    let fileName: String
    let shareURL: String
    let isImage: Bool
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
                    .font(.subheadline)
            }

            Text(fileName)
                .font(.body)
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

            HStack {
                Text(shareURL)
                    .font(.subheadline)
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
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundColor(showCopyToast ? .green : .blue)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            Text(qrHint(for: fileName, isImage: isImage))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("复制链接并关闭") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shareURL, forType: .string)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            if showCopyToast {
                Text("已复制到剪贴板")
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            qrImage = QRCodeGenerator.generate(from: shareURL)
        }
    }
}

// MARK: - QR hint helper

private func qrHint(for fileName: String, isImage: Bool = false) -> String {
    let ext = (fileName as NSString).pathExtension.lowercased()

    if isImage || ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff", "tif"].contains(ext) {
        return "扫码即可在浏览器中直接查看图片"
    }
    if ["mp4", "mov", "avi", "mkv", "webm", "3gp"].contains(ext) {
        return "扫码即可在浏览器中播放视频"
    }
    if ["txt", "md", "json", "xml", "csv", "log", "yaml", "yml", "html", "css", "js", "ts"].contains(ext) {
        return "扫码即可在浏览器中查看文本内容"
    }
    if ["pdf"].contains(ext) {
        return "扫码即可在浏览器中查看 PDF"
    }
    return "扫码即可获取文件下载链接"
}

// MARK: - Date Formatting

extension R2File {
    var lastModifiedFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: lastModified, relativeTo: Date())
    }
}
