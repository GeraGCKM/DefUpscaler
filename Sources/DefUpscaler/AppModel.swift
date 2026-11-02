import SwiftUI
import AppKit
import ImageIO
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
}

struct LoadedPreview: @unchecked Sendable {
    let image: CGImage
    let metadata: ImageMetadata
}

actor PreviewLoader {
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
        return LoadedPreview(image: cg, metadata: metadata)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [QueueItem] = []
    @Published var selectedID: UUID?
    @Published var preview: NSImage?
    @Published var metadata: ImageMetadata?
    @Published var scale = 4
    @Published var mode: ImageMode = .illustration
    @Published var running = false
    @Published var loading = false
    @Published var saving = false
    @Published var progress = 0.0
    @Published var phase = ""
    @Published var message: String?
    @Published var showingResult = true
    @Published var actualSize = false
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
    var dimensions: String {
        guard let metadata else { return "" }
        if showingResult, selected?.result != nil { return "\(metadata.width) × \(metadata.height)" }
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
    func select(_ id: UUID) { selectedID = id; showingResult = true; refreshPreview() }
    func refreshPreview() {
        guard let selected else { return }
        previewTask?.cancel()
        let token = UUID()
        generation = token
        let url = showingResult ? selected.result ?? selected.input : selected.input
        let full = actualSize
        loading = true
        message = nil
        previewTask = Task {
            do {
                let loaded = try await loader.load(url, full: full)
                guard generation == token, !Task.isCancelled else { return }
                // Keep the old image visible until its replacement is decoded.
                preview = NSImage(cgImage: loaded.image, size: .zero)
                metadata = loaded.metadata
            } catch is CancellationError {} catch {
                guard generation == token else { return }
                message = error.localizedDescription
            }
            if generation == token { loading = false }
        }
    }
    func start() {
        guard !running, hasPending else { return }
        let jobScale = scale
        let jobMode = mode
        running = true
        message = nil
        task = Task {
            defer { running = false; task = nil; phase = "" }
            while let index = items.firstIndex(where: { $0.state == "Pendiente" }) {
                if Task.isCancelled { break }
                let id = items[index].id
                let input = items[index].input
                items[index].state = "En proceso"
                progress = 0
                do {
                    let output = try await engine.process(url: input, scale: jobScale, mode: jobMode,
                        progress: { [weak self] value in await self?.setProgress(value) },
                        status: { [weak self] value in await self?.setPhase(value) })
                    if Task.isCancelled { try? FileManager.default.removeItem(at: output); throw CancellationError() }
                    if let i = items.firstIndex(where: { $0.id == id }) {
                        items[i].result = output
                        items[i].outputScale = jobScale
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
                }
            }
        }
    }
    func cancel() { task?.cancel() }
    private func setProgress(_ value: Double) { progress = value }
    private func setPhase(_ value: String) { phase = value }
    func retryFailed() {
        guard !running else { return }
        for i in items.indices where items[i].result == nil { items[i].state = "Pendiente" }
        start()
    }

    func save() {
        guard !saving, let selected, let result = selected.result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = selected.input.deletingPathExtension().lastPathComponent + "-\(selected.outputScale ?? scale)x.png"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        if target.standardizedFileURL == selected.input.standardizedFileURL {
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
                        let data = try Data(contentsOf: source, options: .mappedIfSafe)
                        try data.write(to: destination, options: .atomic)
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
        items = []; selectedID = nil; preview = nil; metadata = nil; loading = false; message = nil; progress = 0
    }
}
