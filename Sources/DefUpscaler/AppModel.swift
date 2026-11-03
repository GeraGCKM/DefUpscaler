import SwiftUI
import AppKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import UpscaleCore
import OSLog

struct QueueItem: Identifiable {
    let id = UUID()
    let input: URL
    var result: URL?
    var saved = false
    var state = "Pendiente"
    var outputScale: Int?
    var proFidelity = false
}

struct LoadedPreview: @unchecked Sendable {
    let image: CGImage
    let metadata: ImageMetadata
    let averageColor: (Double, Double, Double)
    let secondaryColor: (Double, Double, Double)
    let tertiaryColor: (Double, Double, Double)
}

actor PreviewLoader {
    private let colorContext = CIContext(options: [.cacheIntermediates: false])
    func load(_ url: URL, full: Bool) throws -> LoadedPreview {
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let metadata = try ImageInspector.read(url)
        guard metadata.width <= 32768, metadata.height <= 32768,
              UInt64(metadata.width) * UInt64(metadata.height) <= 64_000_000 else { throw UpscaleError.tooLarge }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: full ? max(metadata.width, metadata.height) : 1400
              ] as CFDictionary) else { throw UpscaleError.invalidImage }
        try Task.checkCancellation()
        // Only three one-pixel reductions per import, off the main thread.
        // The ambient scene uses gradients, never a continuously blurred image.
        let image = CIImage(cgImage: cg)
        let whole = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let upper = CGRect(x: 0, y: CGFloat(cg.height) * 0.45,
                           width: CGFloat(cg.width) * 0.65, height: CGFloat(cg.height) * 0.55)
        let lower = CGRect(x: CGFloat(cg.width) * 0.35, y: 0,
                           width: CGFloat(cg.width) * 0.65, height: CGFloat(cg.height) * 0.55)
        func sample(_ region: CGRect) -> (Double, Double, Double) {
            let average = image.applyingFilter("CIAreaAverage", parameters: [
                kCIInputExtentKey: CIVector(cgRect: region)
            ])
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { raw in
                guard let pointer = raw.baseAddress else { return }
                colorContext.render(average, toBitmap: pointer, rowBytes: 4,
                                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    format: .RGBA8,
                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return (Double(pixel[0]) / 255, Double(pixel[1]) / 255,
                    Double(pixel[2]) / 255)
        }
        return LoadedPreview(image: cg, metadata: metadata, averageColor: sample(whole),
                             secondaryColor: sample(upper), tertiaryColor: sample(lower))
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [QueueItem] = []
    @Published var selectedID: UUID?
    @Published var preview: NSImage?
    @Published var ambiance: Color = Color.gray
    @Published var ambianceSecondary: Color = Color.gray
    @Published var ambianceTertiary: Color = Color.gray
    @Published var previewItemID: UUID?
    @Published var metadata: ImageMetadata?
    @Published var previewRevision = UUID()
    @Published var scale = 4
    @Published var mode: ImageMode = .illustration
    @Published var proFidelity = false
    @Published var running = false
    @Published var loading = false
    @Published var saving = false
    @Published var progress = 0.0
    @Published var phase = ""
    @Published var message: String?
    @Published var showingResult = true
    @Published var actualSize = false
    @Published private(set) var zoomRevision = UUID()
    @Published private(set) var detailedPreview = false
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var generation = UUID()
    private let loader = PreviewLoader()
    private let engine = UpscaleEngine()
    private let logger = Logger(subsystem: "io.geragckm.DefUpscaler", category: "ui")
    var selected: QueueItem? { items.first { $0.id == selectedID } }
    var hasUnsaved: Bool { items.contains { $0.result != nil && !$0.saved } }
    var hasPending: Bool { items.contains { $0.state == "Pendiente" } }
    var hasResults: Bool { items.contains { $0.result != nil } }
    var aspect: Double { metadata?.aspectRatio ?? 1.4 }
    var pixelViewSize: CGSize {
        guard let metadata else { return .zero }
        let multiplier = !showingResult && selected?.result != nil ? selected?.outputScale ?? 1 : 1
        return CGSize(width: metadata.width * multiplier, height: metadata.height * multiplier)
    }
    var estimatedMemory: String {
        guard let metadata else { return "" }
        let resultVisible = showingResult && selected?.result != nil
        let sourceScale = resultVisible ? (selected?.outputScale ?? scale) : 1
        let sourceWidth = metadata.width / max(1, sourceScale)
        let sourceHeight = metadata.height / max(1, sourceScale)
        let outputScale = resultVisible ? (selected?.outputScale ?? scale) : scale
        let bytes = Int64(sourceWidth) * Int64(sourceHeight) * Int64(outputScale * outputScale) * 24 + 768 * 1024 * 1024
        return "Presupuesto estimado: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory) + ". No es una medición del pico real."
    }
    var dimensions: String {
        guard let metadata else { return "" }
        if showingResult, selected?.result != nil {
            let multiplier = max(1, selected?.outputScale ?? 1)
            return "\(metadata.width / multiplier) × \(metadata.height / multiplier) → \(metadata.width) × \(metadata.height)"
        }
        return "\(metadata.width) × \(metadata.height) → \(metadata.width * scale) × \(metadata.height * scale)"
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func add(_ urls: [URL]) {
        let valid = urls.filter(\.isFileURL)
        guard !valid.isEmpty else { return }
        // Existing results remain in the queue, including unsaved ones.
        items.append(contentsOf: valid.map { QueueItem(input: $0) })
        select(items.last!.id)
    }
    func select(_ id: UUID) { detailedPreview = false; actualSize = false; selectedID = id; showingResult = true; refreshPreview() }
    func setActualSize(_ enabled: Bool) {
        actualSize = enabled
        zoomRevision = UUID()
        refreshPreview()
    }
    func requestDetailedPreview() {
        guard !detailedPreview else { return }
        detailedPreview = true
        refreshPreview()
    }
    func refreshPreview() {
        guard let selected else { return }
        previewTask?.cancel()
        let token = UUID()
        generation = token
        let url = showingResult ? selected.result ?? selected.input : selected.input
        let full = actualSize || detailedPreview
        loading = true
        message = nil
        previewTask = Task {
            do {
                let loaded = try await loader.load(url, full: full)
                guard generation == token, !Task.isCancelled else { return }
                // Keep the old image visible until its replacement is decoded.
                preview = NSImage(cgImage: loaded.image, size: .zero)
                ambiance = Color(red: loaded.averageColor.0, green: loaded.averageColor.1,
                                  blue: loaded.averageColor.2)
                ambianceSecondary = Color(red: loaded.secondaryColor.0, green: loaded.secondaryColor.1,
                                          blue: loaded.secondaryColor.2)
                ambianceTertiary = Color(red: loaded.tertiaryColor.0, green: loaded.tertiaryColor.1,
                                         blue: loaded.tertiaryColor.2)
                previewItemID = selected.id
                metadata = loaded.metadata
                previewRevision = UUID()
                if loaded.metadata.depth > 8 {
                    message = UpscaleError.unsupportedColor.localizedDescription
                } else if url.pathExtension.lowercased() == "heic" {
                    message = "Salida SDR sRGB. Si la imagen tiene HDR, no se conservará esa mejora."
                }
            } catch is CancellationError {} catch {
                guard generation == token else { return }
                preview = nil; previewItemID = nil; metadata = nil; previewRevision = UUID()
                message = error.localizedDescription
            }
            if generation == token { loading = false }
        }
    }
    func start() {
        guard !running, hasPending else { return }
        let jobScale = scale
        let quality = QualityPlanner.make(
            mode: mode, scale: scale, pro: proFidelity,
            hasWebPhoto: Bundle.main.url(forResource: "WebPhoto4x", withExtension: "mlmodelc") != nil
        )
        running = true
        message = nil
        task = Task(priority: .utility) {
            defer { running = false; task = nil; phase = "" }
            while let index = items.firstIndex(where: { $0.state == "Pendiente" }) {
                if Task.isCancelled { break }
                let id = items[index].id
                let input = items[index].input
                items[index].state = "En proceso"
                progress = 0
                do {
                    let output = try await engine.process(
                        url: input, scale: jobScale, mode: quality.mode,
                        neuralWeight: quality.neuralWeight,
                        progress: { [weak self] value in await self?.setProgress(value) },
                        status: { [weak self] value in await self?.setPhase(value) })
                    if Task.isCancelled { try? FileManager.default.removeItem(at: output); throw CancellationError() }
                    if let i = items.firstIndex(where: { $0.id == id }) {
                        items[i].result = output
                        items[i].outputScale = jobScale
                        items[i].proFidelity = quality.isPro
                        items[i].state = "Listo"
                    }
                    if selectedID == id { showingResult = true; refreshPreview() }
                } catch is CancellationError {
                    if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = "Pendiente" }
                    message = "Cancelado. Los resultados terminados se conservan."
                    break
                } catch {
                    if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = error.localizedDescription }
                    logger.error("Inference failed: \(String(reflecting: error), privacy: .private)")
                    message = error.localizedDescription
                    if let failure = error as? UpscaleError, case .memoryPressure = failure { break }
                }
            }
        }
    }
    func reprocessSelected() {
        guard !running, let selected else { return }
        // A new queue entry preserves the earlier result, even if it was not exported.
        let item = QueueItem(input: selected.input)
        items.append(item)
        select(item.id)
        start()
    }
    func cancel() { task?.cancel() }
    private func setProgress(_ value: Double) {
        if value >= 1 || abs(value - progress) >= 0.002 { progress = value }
    }
    private func setPhase(_ value: String) {
        if phase != value { phase = value }
    }
    func retryFailed() {
        guard !running else { return }
        for i in items.indices where items[i].result == nil { items[i].state = "Pendiente" }
        start()
    }

    func save() {
        guard !saving, let selected, let result = selected.result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.message = "PNG conserva transparencia; JPEG utiliza un fondo blanco y compresión de alta calidad."
        panel.nameFieldStringValue = selected.input.deletingPathExtension().lastPathComponent + "-\(selected.outputScale ?? scale)x.png"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        if target.resolvingSymlinksInPath().standardizedFileURL == selected.input.resolvingSymlinksInPath().standardizedFileURL {
            message = "Elige otro nombre para conservar el original."; return
        }
        export([(selected.id, result, target)])
    }
    func saveAll() {
        guard !saving, hasResults else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        var used = Set<String>()
        let jobs: [(UUID, URL, URL)] = items.compactMap { item in
            guard let result = item.result else { return nil }
            let base = item.input.deletingPathExtension().lastPathComponent + "-\(item.outputScale ?? scale)x"
            var name = base + ".png"
            var suffix = 2
            while used.contains(name) || FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                name = "\(base)-\(suffix).png"; suffix += 1
            }
            used.insert(name)
            return (item.id, result, directory.appendingPathComponent(name))
        }
        export(jobs)
    }
    private func export(_ jobs: [(UUID, URL, URL)]) {
        saving = true
        Task {
            defer { saving = false }
            var failures = 0
            for (id, source, destination) in jobs {
                do {
                    try await Task.detached(priority: .utility) {
                        try ImageExportWriter.write(from: source, to: destination)
                    }.value
                    if let i = items.firstIndex(where: { $0.id == id }) { items[i].saved = true }
                } catch { failures += 1; message = error.localizedDescription }
            }
            if failures == 0 { message = jobs.count == 1 ? "Imagen guardada." : "Imágenes guardadas." }
        }
    }
    func confirmDiscard() -> Bool {
        guard hasUnsaved else { return true }
        let alert = NSAlert()
        alert.messageText = "Hay resultados sin guardar"
        alert.informativeText = "Si continúas, se eliminarán los resultados temporales. Tus imágenes originales y exportadas se conservan."
        alert.addButton(withTitle: "Volver")
        alert.addButton(withTitle: "Descartar")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func reset() {
        guard !running, !saving, confirmDiscard() else { return }
        previewTask?.cancel(); generation = UUID()
        for item in items { if let result = item.result { try? FileManager.default.removeItem(at: result) } }
        items = []; selectedID = nil; preview = nil; previewItemID = nil; metadata = nil; loading = false; message = nil; progress = 0
    }
}
