import AppKit
import UniformTypeIdentifiers

/// Handles drag-and-drop for both upload (into app) and download (out of app)
///
/// Upload: SwiftUI's .onDrop modifier handles file drops.
/// Download: SwiftUI's .onDrag modifier handles drag out.
/// This file provides AppKit-level helpers for advanced scenarios.
enum DragDropHandler {

    /// Process files dropped onto the app (upload).
    /// Returns array of file URLs that are valid for upload.
    static func handleDragInto(_ providers: [NSItemProvider]) -> [URL] {
        var urls: [URL] = []
        let semaphore = DispatchSemaphore(value: 0)

        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, error in
                if let urlData = data as? Data,
                   let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                    urls.append(url)
                }
                semaphore.signal()
            }
            semaphore.wait()
        }

        return urls
    }
}
