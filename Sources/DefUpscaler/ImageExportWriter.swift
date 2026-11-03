import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Export is deliberately off MainActor. Keep the neural result as an
/// untouched lossless PNG until the user explicitly chooses a destination.
enum ImageExportWriter {
    static func write(from source: URL, to destination: URL) throws {
        switch destination.pathExtension.lowercased() {
        case "png":
            // FileManager can stream/clone the PNG; do not materialize the
            // entire encoded result in a Data buffer just to save a copy.
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".defupscaler-\(UUID().uuidString).png")
            let files = FileManager.default
            defer { try? files.removeItem(at: temporary) }
            try files.copyItem(at: source, to: temporary)
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try files.moveItem(at: temporary, to: destination)
            }
        case "jpg", "jpeg":
            try writeJPEG(from: source, to: destination)
        default:
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func writeJPEG(from source: URL, to destination: URL) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: image.width, height: image.height,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let rectangle = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(rectangle)
        // JPEG cannot retain an alpha channel; composite transparencies onto
        // white explicitly instead of silently dropping premultiplied color.
        canvas.draw(image, in: rectangle)
        guard let flattened = canvas.makeImage() else { throw CocoaError(.fileWriteUnknown) }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".defupscaler-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let writer = CGImageDestinationCreateWithURL(
            temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary
        CGImageDestinationAddImage(writer, flattened, options)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try files.moveItem(at: temporary, to: destination)
        }
    }
}
