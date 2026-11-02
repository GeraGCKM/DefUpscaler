import Foundation
import ImageIO
import CoreGraphics

public struct ImageMetadata: Sendable {
    public let width: Int
    public let height: Int
    public let depth: Int
    public var aspectRatio: Double { Double(width) / Double(height) }
}

public enum ImageInspector {
    public static func read(_ url: URL) throws -> ImageMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int,
              let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { throw UpscaleError.invalidImage }
        let orientation = p[kCGImagePropertyOrientation] as? Int ?? 1
        return ImageMetadata(width: orientation >= 5 ? h : w, height: orientation >= 5 ? w : h,
                             depth: p[kCGImagePropertyDepth] as? Int ?? 8)
    }
}
