import Foundation
import ImageIO
import UpscaleCore

/// Separate serial lanes keep a large comparison decode from starving the queue.
/// Cancellation skips stale queued work; ImageIO's current decode finishes normally.
actor PreviewDecoder {
    static let inspection = PreviewDecoder(budget: 16 * 1024 * 1024)
    static let thumbnails = PreviewDecoder(budget: 4 * 1024 * 1024)
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private let cache = NSCache<NSString, Entry>()
    init(budget: Int) { cache.totalCostLimit = budget; cache.countLimit = 96 }

    func image(at url: URL, maximumDimension: Int) throws -> CGImage {
        try Task.checkCancellation()
        return try autoreleasepool {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let info = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let key = "\(url.absoluteString)|\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(info.fileSize ?? 0)|\(maximumDimension)" as NSString
            if let cached = cache.object(forKey: key) { return cached.image }
            let metadata = try ImageInspector.read(url)
            guard metadata.width <= 32768, metadata.height <= 32768,
                  UInt64(metadata.width) * UInt64(metadata.height) <= 64_000_000 else {
                throw UpscaleError.tooLarge
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw UpscaleError.invalidImage }
            try Task.checkCancellation()
            // Never retain full-resolution images in the cache in addition to the viewer.
            if maximumDimension <= 1800 {
                cache.setObject(Entry(image), forKey: key, cost: image.bytesPerRow * image.height)
            }
            return image
        }
    }

    func clear() { cache.removeAllObjects() }
}
