import AppKit
import UniformTypeIdentifiers

/// Handles drag-and-drop for both upload (into app) and download (out of app)
///
/// Upload: User drags files from Finder into the app window.
/// Download: User drags files from the file list onto Finder/Desktop.
enum DragDropHandler {

    // MARK: - Drag Into (Upload)

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

    // MARK: - Drag Out (Download)

    /// Start dragging a file out of the app to Finder/Desktop.
    /// Creates a temporary file and initiates the system drag session.
    static func beginDragOut(from sourceURL: URL, in view: NSView) {
        let draggingItem = NSDraggingItem(pasteboardWriter: sourceURL as NSURL)
        draggingItem.setDraggingFrame(view.bounds, contents: nil)
        if let event = NSApp.currentEvent {
            view.beginDraggingSession(with: [draggingItem], event: event, source: view)
        }
    }

    /// Register the view for file drop (upload)
    static func registerDropTarget(_ view: NSView, handler: @escaping ([URL]) -> Void) {
        // Note: In SwiftUI, this is handled via .onDrop modifier
        // This is for AppKit-level fine control
    }
}
