import Foundation
import CoreML
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import OSLog

/// An actor serializes model access. No inference or full-size decoding runs on MainActor.
public actor UpscaleEngine {
    private let logger = Logger(subsystem: "io.geragckm.DefUpscaler", category: "inference")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var model: MLModel?
    private var criticalMemory = false
    private var pressure: DispatchSourceMemoryPressure?

    private let suppliedModelURL: URL?

    public init(modelURL: URL? = nil) { suppliedModelURL = modelURL }

    public func process(url: URL, scale: Int, gentle: Bool,
                        progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        let started = Date()
        logger.info("Starting job scale=\(scale) gentle=\(gentle)")
        criticalMemory = false
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in Task { await self?.markMemoryPressure() } }
        source.resume()
        pressure = source
        defer { source.cancel(); pressure = nil; model = nil; context.clearCaches() }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw UpscaleError.invalidImage }
        // Check metadata before decoding potentially hostile / enormous images.
        _ = try JobPlan(width: width, height: height, scale: scale, memoryBytes: ProcessInfo.processInfo.physicalMemory)
        guard let input = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw UpscaleError.invalidImage
        }
        let image = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let plan = try JobPlan(width: Int(image.extent.width), height: Int(image.extent.height), scale: scale,
                               memoryBytes: ProcessInfo.processInfo.physicalMemory)
        guard let modelURL = suppliedModelURL ?? Bundle.main.url(forResource: "Anime4x", withExtension: "mlmodelc") else {
            throw UpscaleError.missingModel
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loadedModel = try MLModel(contentsOf: modelURL, configuration: configuration)
        model = loadedModel
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let canvas = CGContext(data: nil, width: plan.outputWidth, height: plan.outputHeight,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw UpscaleError.tooLarge
        }
        // First release intentionally flattens transparency onto white, clearly disclosed in the UI.
        let opaque = image.composited(over: CIImage(color: .white).cropped(to: image.extent)).clampedToExtent()
        for (index, tile) in plan.tiles.enumerated() {
            try Task.checkCancellation()
            if criticalMemory { throw UpscaleError.memoryPressure }
            while ProcessInfo.processInfo.thermalState == .critical {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                if criticalMemory { throw UpscaleError.memoryPressure }
            }
            try autoreleasepool {
                let side = JobPlan.modelSide
                var buffer: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
                    let buffer else { throw UpscaleError.tooLarge }
                let region = CGRect(x: tile.x - JobPlan.padding, y: tile.y - JobPlan.padding, width: side, height: side)
                let patch = opaque.cropped(to: region).transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
                context.render(patch, to: buffer, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: colorSpace)
                let features = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(pixelBuffer: buffer)])
                let prediction = try loadedModel.prediction(from: features)
                guard let output = prediction.featureValue(for: "output")?.imageBufferValue,
                      CVPixelBufferGetWidth(output) == side * 4,
                      CVPixelBufferGetHeight(output) == side * 4 else { throw UpscaleError.invalidPrediction }
                let crop = CGRect(x: JobPlan.padding * 4, y: JobPlan.padding * 4, width: tile.width * 4, height: tile.height * 4)
                guard let cg = context.createCGImage(CIImage(cvPixelBuffer: output), from: crop) else {
                    throw UpscaleError.invalidPrediction
                }
                canvas.interpolationQuality = .high
                canvas.draw(cg, in: CGRect(x: tile.x * scale, y: tile.y * scale, width: tile.width * scale, height: tile.height * scale))
            }
            await progress(Double(index + 1) / Double(plan.tiles.count))
            // Yield between predictions so cancel/memory events can reach the actor.
            try await Task.sleep(for: .milliseconds(gentle || ProcessInfo.processInfo.thermalState == .serious ? 80 : 1))
        }
        try Task.checkCancellation()
        guard let output = canvas.makeImage() else { throw UpscaleError.tooLarge }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DefUpscaler", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        do {
            guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw UpscaleError.invalidImage
            }
            CGImageDestinationAddImage(writer, output, nil)
            guard CGImageDestinationFinalize(writer) else { throw UpscaleError.invalidImage }
            logger.info("Finished job tiles=\(plan.tiles.count) seconds=\(Date().timeIntervalSince(started))")
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func markMemoryPressure() { criticalMemory = true }
}
