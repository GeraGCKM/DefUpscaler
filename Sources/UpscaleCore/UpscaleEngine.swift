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
    private let suppliedModelScale: Int
    public init(modelURL: URL? = nil, modelScale: Int = 4) {
        suppliedModelURL = modelURL
        suppliedModelScale = modelScale
    }

    public func process(url: URL, scale: Int, mode: ImageMode = .illustration,
                        neuralWeight: Double = 1,
                        progress: @escaping @Sendable (Double) async -> Void,
                        status: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        guard !busy else { throw UpscaleError.busy }
        busy = true
        defer { busy = false; context.clearCaches() }
        try Task.checkCancellation()
        guard neuralWeight.isFinite, neuralWeight > 0, neuralWeight <= 1 else {
            throw UpscaleError.invalidPrediction
        }
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
        // Native 2× photo inference is preferred when its verified profile is bundled.
        // Explicitly supplied test models retain their declared native scale.
        let descriptor = ModelCatalog.select(mode: mode, requestedScale: scale,
            hasNativePhoto2x: Bundle.main.url(forResource: "Photo2x", withExtension: "mlmodelc") != nil)
        let nativeScale = suppliedModelURL == nil ? descriptor.nativeScale : suppliedModelScale
        let usesWebPhoto = mode == .photoDetail
        guard let modelURL = suppliedModelURL ?? Bundle.main.url(forResource: descriptor.resource, withExtension: "mlmodelc") else {
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
        // In Pro, the source image contributes 75% of the final RGB.
        // The finite guard contains Lanczos ringing at image borders; alpha is
        // always resampled separately, as in the standard pipeline.
        let sourceReference: CIImage? = neuralWeight < 1
            ? rgb.cropped(to: CGRect(x: -8, y: -8, width: plan.width + 16, height: plan.height + 16))
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: Double(scale), kCIInputAspectRatioKey: 1.0
                ])
            : nil
        var governor = ResourceGovernor()
        var y = 0
        var completedPixels = 0
        let started = Date()
        while y < plan.height {
            try Task.checkCancellation()
            let thermalState = ProcessInfo.processInfo.thermalState
            let rowSide = usesWebPhoto
                ? (memoryWarning || thermalState == .serious || thermalState == .critical ? 256 : 384)
                : governor.coreSide
            let requestedSide = usesWebPhoto ? 512 : rowSide + 2 * JobPlan.padding
            let variantChanged = loadedSide != requestedSide
            if variantChanged {
                model = nil
                context.clearCaches()
                let variantURL = usesWebPhoto || requestedSide == 96 ? modelURL : modelURL.deletingLastPathComponent()
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
                    let side = requestedSide
                    let padding = (side - rowSide) / 2
                    var buffer: CVPixelBuffer?
                    guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
                        let buffer else { throw UpscaleError.tooLarge }
                    let region = CGRect(x: x - padding, y: y - padding, width: side, height: side)
                    let patch = rgb.cropped(to: region).transformed(by: .init(translationX: -region.minX, y: -region.minY))
                    context.render(patch, to: buffer, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: colorSpace)
                    let features = try MLDictionaryFeatureProvider(dictionary: [
                        usesWebPhoto ? "image" : "input": MLFeatureValue(pixelBuffer: buffer)
                    ])
                    let prediction = try activeModel.prediction(from: features)
                    let neural: CIImage
                    if usesWebPhoto {
                        guard let pixels = prediction.featureValue(for: "upscaled")?.imageBufferValue,
                              CVPixelBufferGetWidth(pixels) == side * nativeScale,
                              CVPixelBufferGetHeight(pixels) == side * nativeScale else {
                            throw UpscaleError.invalidPrediction
                        }
                        neural = CIImage(cvPixelBuffer: pixels, options: [.colorSpace: colorSpace])
                    } else {
                        guard let array = prediction.featureValue(for: "output")?.multiArrayValue else {
                            throw UpscaleError.invalidPrediction
                        }
                        neural = try TensorImage.makeFloating(array, side: side * nativeScale,
                                                               colorSpace: colorSpace)
                    }
                    // Avoid interpolating a native-resolution prediction. Other scales
                    // resample with context *before* cropping, preventing edge seams.
                    let resized = (scale == nativeScale ? neural : neural.applyingFilter("CILanczosScaleTransform", parameters: [
                        kCIInputScaleKey: Double(scale) / Double(nativeScale), kCIInputAspectRatioKey: 1.0
                    ])).transformed(by: .init(translationX: CGFloat((x - padding) * scale), y: CGFloat((y - padding) * scale)))
                    let rect = CGRect(x: x * scale, y: y * scale, width: width * scale, height: rowHeight * scale)
                    let neuralOrBlend: CIImage
                    if let sourceReference {
                        // Mask luminance (rather than mask alpha) controls the
                        // blend: gray 0.25 means 25% neural and 75% original.
                        let mask = CIImage(color: CIColor(
                            red: neuralWeight, green: neuralWeight, blue: neuralWeight, alpha: 1
                        )).cropped(to: rect)
                        neuralOrBlend = resized.applyingFilter("CIBlendWithMask", parameters: [
                            kCIInputBackgroundImageKey: sourceReference,
                            kCIInputMaskImageKey: mask
                        ])
                    } else {
                        neuralOrBlend = resized
                    }
                    let restored = neuralOrBlend.applyingFilter("CIBlendWithAlphaMask", parameters: [
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
            if !usesWebPhoto && (constrained || !variantChanged) {
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
            logger.info("Completed mode=\(mode.rawValue) neuralWeight=\(neuralWeight) nativeScale=\(nativeScale) scale=\(scale) seconds=\(Date().timeIntervalSince(started))")
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    private func setPressure(warning: Bool, critical: Bool) { memoryWarning = warning; criticalMemory = critical }
}
