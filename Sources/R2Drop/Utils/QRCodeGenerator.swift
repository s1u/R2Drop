import AppKit
import CoreImage

/// Generates QR code images from text/URL strings
enum QRCodeGenerator {

    /// Generate a QR code as NSImage with the given size
    static func generate(from string: String, size: CGSize = CGSize(width: 200, height: 200)) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        let data = string.data(using: .utf8)
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel") // High error correction

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up the small QR code to the desired size
        let scaleX = size.width / ciImage.extent.size.width
        let scaleY = size.height / ciImage.extent.size.height
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Convert to NSImage
        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)

        return nsImage
    }
}
