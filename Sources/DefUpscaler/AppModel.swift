import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import UpscaleCore
import OSLog

@MainActor
final class AppModel: ObservableObject {
    @Published var input: URL?
    @Published var preview: NSImage?
    @Published var resultPreview: NSImage?
    @Published var scale = 4
    @Published var gentle = true
    @Published var running = false
    @Published var progress = 0.0
    @Published var message: String?
    @Published var showingResult = true
    private(set) var result: URL?
    private var task: Task<Void, Never>?
    private let engine = UpscaleEngine()
    private let logger = Logger(subsystem: "io.geragckm.DefUpscaler", category: "ui")

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        guard !running else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let thumbnail = Self.thumbnail(url) else {
            message = UpscaleError.invalidImage.localizedDescription
            return
        }
        clearResult()
        input = url
        preview = thumbnail
        message = nil
        progress = 0
    }

    func start() {
        guard let input, !running else { return }
        clearResult()
        running = true
        message = nil
        progress = 0
        let scale = scale
        let gentle = gentle
        task = Task {
            defer { running = false; task = nil }
            do {
                let output = try await engine.process(url: input, scale: scale, gentle: gentle) { [weak self] value in
                    await self?.setProgress(value)
                }
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: output)
                    throw CancellationError()
                }
                result = output
                resultPreview = Self.thumbnail(output)
                showingResult = true
                message = "Listo. Guarda el resultado para conservarlo."
            } catch is CancellationError {
                message = "Cancelado."
            } catch {
                logger.error("Job failed: \(String(reflecting: error), privacy: .public)")
                message = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }
    private func setProgress(_ value: Double) { progress = value }

    func save() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (input?.deletingPathExtension().lastPathComponent ?? "imagen") + "-upscaled.png"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            // Atomic write preserves an existing destination if writing fails.
            let data = try Data(contentsOf: result, options: .mappedIfSafe)
            try data.write(to: target, options: .atomic)
            message = "Imagen guardada."
        } catch { message = error.localizedDescription }
    }

    func clearResult() {
        if let result { try? FileManager.default.removeItem(at: result) }
        result = nil
        resultPreview = nil
    }

    func reset() {
        guard !running else { return }
        clearResult()
        input = nil
        preview = nil
        progress = 0
        message = nil
    }

    static func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 900
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}
