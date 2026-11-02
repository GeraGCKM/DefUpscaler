import Foundation
import CoreML
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import OSLog
import Metal

public actor UpscaleEngine {
    private let logger = Logger(subsystem: "io.geragckm.DefUpscaler", category: "inference")
    private let context = CIContext(options: [.cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private var memoryWarning = false
    private var criticalMemory = false
    private var busy = false
    private let suppliedModelURL: URL?
    public init(modelURL: URL? = nil) { suppliedModelURL = modelURL }

    public func process(url: URL, scale: Int, mode: ImageMode = .illustration,
                        progress: @escaping @Sendable (Double) async -> Void,
                        status: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        guard !busy else { throw UpscaleError.busy }
        busy = true
        defer { busy = false; context.clearCaches() }
        try Task.checkCancellation()
        criticalMemory = false
        memoryWarning = false
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            let event = source.data
            Task { await self?.setPressure(warning: event.contains(.warning), critical: event.contains(.critical)) }
        }
        source.resume()
        defer { source.setEventHandler {}; source.cancel() }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let metadata = try ImageInspector.read(url)
        guard metadata.depth <= 8 else { throw UpscaleError.unsupportedColor }
        let plan = try JobPlan(width: metadata.width, height: metadata.height, scale: scale,
                               memoryBytes: ProcessInfo.processInfo.physicalMemory)
        let estimated = UInt64(plan.outputWidth) * UInt64(plan.outputHeight) * 24 + 768 * 1024 * 1024
        if let available = MemorySnapshot.availableBytes(), estimated > available * 3 / 4 { throw UpscaleError.tooLarge }
        guard let input = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw UpscaleError.invalidImage }
        // Gain-map HEIC/HDR is not claimed as supported: only the SDR base is decoded.
        // Deep input is rejected above; every accepted image is color-managed into sRGB.
        let image = input.transformed(by: .init(translationX: -input.extent.minX, y: -input.extent.minY))
        guard let modelURL = suppliedModelURL ?? Bundle.main.url(forResource: mode.modelName, withExtension: "mlmodelc") else {
            throw UpscaleError.missingModel
        }
        await status("Preparando modelo…")
        let configuration = MLModelConfiguration()
        configuration.computeUnits = MTLCreateSystemDefaultDevice() == nil ? .cpuOnly : .all
        logger.info("Compute path: \(MTLCreateSystemDefaultDevice() == nil ? "CPU (no Metal device)" : "automatic acceleration")")
        var model: MLModel?
        var loadedSide = 0
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let canvas = CGContext(data: nil, width: plan.outputWidth, height: plan.outputHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw UpscaleError.tooLarge }
        // Feed straight RGB to the model, and resample alpha separately without hallucinating it.
        let rgb = image.unpremultiplyingAlpha().applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).clampedToExtent()
        let alpha = image.transformed(by: .init(scaleX: CGFloat(scale), y: CGFloat(scale)))
        var governor = ResourceGovernor()
        var y = 0
        var completedPixels = 0
        let started = Date()
        while y < plan.height {
            try Task.checkCancellation()
            let rowSide = governor.coreSide
            let requestedSide = rowSide + 2 * JobPlan.padding
            let variantChanged = loadedSide != requestedSide
            if variantChanged {
                model = nil
                context.clearCaches()
                let variantURL = requestedSide == 96 ? modelURL : modelURL.deletingLastPathComponent()
                    .appendingPathComponent(modelURL.deletingPathExtension().lastPathComponent + "-\(requestedSide).mlmodelc")
                model = try MLModel(contentsOf: variantURL, configuration: configuration)
                loadedSide = requestedSide
            }
            guard let activeModel = model else { throw UpscaleError.missingModel }
            let rowHeight = min(rowSide, plan.height - y)
            var x = 0
            let rowStarted = Date()
            var constrained = false
            while x < plan.width {
                try Task.checkCancellation()
                if criticalMemory { throw UpscaleError.memoryPressure }
                while ProcessInfo.processInfo.thermalState == .critical {
                    await status("Esperando a que baje la temperatura…")
                    try await Task.sleep(for: .milliseconds(500))
                    if criticalMemory { throw UpscaleError.memoryPressure }
                }
                let thermal = ProcessInfo.processInfo.thermalState
                constrained = constrained || memoryWarning || thermal == .serious || thermal == .fair
                if let available = MemorySnapshot.availableBytes(), available < 512 * 1024 * 1024 {
                    throw UpscaleError.memoryPressure
                }
                await status(memoryWarning ? "Ajustando carga por memoria…" : thermal == .serious ? "Ajustando carga por temperatura…" : "Reescalando…")
                let width = min(rowSide, plan.width - x)
                try autoreleasepool {
                    let side = rowSide + 2 * JobPlan.padding
                    var buffer: CVPixelBuffer?
                    guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
                        let buffer else { throw UpscaleError.tooLarge }
                    let region = CGRect(x: x - JobPlan.padding, y: y - JobPlan.padding, width: side, height: side)
                    let patch = rgb.cropped(to: region).transformed(by: .init(translationX: -region.minX, y: -region.minY))
                    context.render(patch, to: buffer, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: colorSpace)
                    let features = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(pixelBuffer: buffer)])
                    let prediction = try activeModel.prediction(from: features)
                    guard let array = prediction.featureValue(for: "output")?.multiArrayValue else {
                        throw UpscaleError.invalidPrediction
                    }
                    let output = try TensorImage.make(array, side: side * 4, colorSpace: colorSpace)
                    // Resample with context still present, then crop; avoids independent hard-edge resampling.
                    let resized = CIImage(cgImage: output).applyingFilter("CILanczosScaleTransform", parameters: [
                        kCIInputScaleKey: Double(scale) / 4, kCIInputAspectRatioKey: 1.0
                    ]).transformed(by: .init(translationX: CGFloat((x - JobPlan.padding) * scale), y: CGFloat((y - JobPlan.padding) * scale)))
                    let rect = CGRect(x: x * scale, y: y * scale, width: width * scale, height: rowHeight * scale)
                    let restored = resized.applyingFilter("CIBlendWithAlphaMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect),
                        kCIInputMaskImageKey: alpha
                    ])
                    guard let cg = context.createCGImage(restored, from: rect, format: .RGBA8, colorSpace: colorSpace) else {
                        throw UpscaleError.invalidPrediction
                    }
                    canvas.setBlendMode(.copy)
                    canvas.draw(cg, in: rect)
                }
                completedPixels += width * rowHeight
                await progress(0.96 * Double(completedPixels) / Double(plan.width * plan.height))
                x += width
                await Task.yield()
                // Only thermal/memory distress activates duty-cycle throttling at the smallest tier.
                if constrained && rowSide == 64 {
                    try await Task.sleep(for: .milliseconds(30))
                }
            }
            if constrained || !variantChanged {
                governor.observe(secondsPerPixel: Date().timeIntervalSince(rowStarted) / Double(plan.width * rowHeight), constrained: constrained)
            }
            logger.debug("Adaptive row core=\(rowSide) next=\(governor.coreSide) constrained=\(constrained)")
            y += rowHeight
        }
        try Task.checkCancellation()
        await status("Preparando PNG…")
        guard let output = canvas.makeImage() else { throw UpscaleError.tooLarge }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DefUpscaler", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        do {
            guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw UpscaleError.invalidImage }
            CGImageDestinationAddImage(writer, output, nil)
            guard CGImageDestinationFinalize(writer) else { throw UpscaleError.invalidImage }
            try Task.checkCancellation()
            await progress(1)
            logger.info("Completed mode=\(mode.rawValue) scale=\(scale) seconds=\(Date().timeIntervalSince(started))")
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    private func setPressure(warning: Bool, critical: Bool) { memoryWarning = warning; criticalMemory = critical }
}
