import SwiftUI
import AppKit
import UpscaleCore
import ImageIO

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.saving == true { return .terminateCancel }
        if model?.running == true {
            let alert = NSAlert()
            alert.messageText = "¿Cancelar el procesamiento y salir?"
            alert.addButton(withTitle: "Continuar trabajando")
            alert.addButton(withTitle: "Salir")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        guard model?.confirmDiscard() != false else { return .terminateCancel }
        model?.cancel()
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { Self.removeTemporaryResults() }
    static func removeTemporaryResults() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("DefUpscaler", isDirectory: true))
    }
}

@main
struct DefUpscalerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @AppStorage("appearance") private var appearance = "system"
    init() { AppDelegate.removeTemporaryResults() }
    var body: some Scene {
        Window("DefUpscaler", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .onAppear {
                    delegate.model = model
                    if let index = CommandLine.arguments.firstIndex(of: "--preview-fixture"),
                       CommandLine.arguments.indices.contains(index + 1), model.items.isEmpty {
                        model.add([URL(fileURLWithPath: CommandLine.arguments[index + 1])])
                    }
                }
        }
        .defaultSize(width: 860, height: 670)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Añadir imágenes…", action: model.choose).keyboardShortcut("o")
                Button("Guardar resultado…", action: model.save).keyboardShortcut("s").disabled(model.selected?.result == nil || model.saving)
            }
        }
        Settings {
            Form {
                Picker("Apariencia", selection: $appearance) {
                    Text("Sistema").tag("system")
                    Text("Clara").tag("light")
                    Text("Oscura").tag("dark")
                }
                Text("Salida: PNG SDR sRGB de 8 bits, con transparencia. HDR no se conserva. Las imágenes de más de 8 bits se rechazan; HEIC con mapa HDR usa su imagen base SDR.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 400)
        }
    }
}

struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct PrimaryAction: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.buttonStyle(.glassProminent)
        } else { content.buttonStyle(.borderedProminent) }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var targeted = false
    @State private var compare = true
    @State private var divider = 0.5
    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1
    @State private var showQueue = true
    @State private var original: NSImage?
    @State private var compareToken = UUID()
    @State private var dividerDragStart: CGFloat?
    @State private var canvasSize: CGSize = CGSize(width: 860, height: 600)
    private var movement: Animation? { reduceMotion ? nil : .smooth(duration: 0.24) }
    private var canCompare: Bool { model.selected?.result != nil && original != nil }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                workspace
                VStack(spacing: 12) {
                    Spacer()
                    if model.running {
                        VStack(spacing: 5) {
                            ProgressView(value: model.progress)
                            HStack {
                                Text(model.phase)
                                Spacer()
                                Text("\(Int(model.progress * 100)) %").monospacedDigit()
                            }.font(.caption)
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 32)
                    }
                    controls
                }.padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showQueue && !model.items.isEmpty { queue }
        }
        .frame(minWidth: 540, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowAspectObserver(aspect: model.preview == nil ? nil : CGFloat(model.aspect)))
        .onChange(of: model.selectedID) { _, _ in loadComparison(); resetZoom() }
        .onChange(of: model.selected?.result) { _, _ in loadComparison() }
        .onChange(of: model.previewRevision) { _, _ in
            loadComparison()
            if model.actualSize, let preview = model.preview {
                zoom = actualZoom(preview: preview, size: canvasSize)
            }
        }
        .onAppear(perform: loadComparison)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            var accepted = false
            for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.add([url]) } }
                }
            }
            return accepted
        }
        .animation(movement, value: showQueue)
        .animation(movement, value: model.selectedID)
    }

    private var workspace: some View {
        GeometryReader { bounds in
            let width = max(1, bounds.size.width)
            let height = max(1, bounds.size.height)
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if let preview = model.preview {
                    ScrollView([.horizontal, .vertical]) {
                        GeometryReader { area in
                            let fitted = fit(image: preview, in: CGSize(width: width, height: height))
                            let displayed = CGSize(width: fitted.width * zoom * gestureZoom,
                                                   height: fitted.height * zoom * gestureZoom)
                            ZStack(alignment: .topLeading) {
                                previewContent(preview, size: displayed)
                                    .frame(width: displayed.width, height: displayed.height)
                                    .id(model.previewRevision)
                                    .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.99)))
                            }
                            .frame(width: max(area.size.width, displayed.width),
                                   height: max(area.size.height, displayed.height))
                        }
                        .frame(width: max(width, fit(image: preview, in: bounds.size).width * zoom * gestureZoom),
                               height: max(height, fit(image: preview, in: bounds.size).height * zoom * gestureZoom))
                    }
                    .scrollIndicators(.hidden)
                    .magnificationGestureCompat(zoom: $zoom, gestureZoom: $gestureZoom)
                    .onTapGesture(count: 2) {
                        if model.actualSize { resetZoom() }
                        else { showActualSize(preview: preview) }
                    }
                    .accessibilityLabel("Vista previa ampliable")
                    .accessibilityAction(named: "Ajustar a ventana") { resetZoom() }
                    .accessibilityAction(named: "Tamaño real") {
                        showActualSize(preview: preview)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 38, weight: .ultraLight))
                        Text("Suelta tus imágenes aquí").font(.title3.weight(.medium))
                        Button("Elegir imágenes", action: model.choose)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: model.choose)
                }
                if model.loading { ProgressView().controlSize(.small).padding(12).background(.regularMaterial, in: Capsule()) }
                if targeted { RoundedRectangle(cornerRadius: 15).strokeBorder(.tint, lineWidth: 2).padding(6) }
            }
            .onAppear { canvasSize = bounds.size }
            .onChange(of: bounds.size) { _, value in canvasSize = value }
            .overlay(alignment: .topLeading) {
                if model.preview != nil {
                    HStack(spacing: 8) {
                        Text(model.dimensions).monospacedDigit()
                        if zoom != 1 {
                            Button("Ajustar") { resetZoom() }
                                .buttonStyle(.plain).foregroundStyle(.primary)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10).background(.regularMaterial, in: Capsule()).padding(16)
                }
            }
        }
    }

    private func previewContent(_ image: NSImage, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            if compare, canCompare, let original {
                Image(nsImage: original).resizable().interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: size.width * divider)
                    }
                    .allowsHitTesting(false)
                // Full-surface clicks ease rapidly to the cursor; the independent
                // 32-point handle cancels that animation on the first drag update.
                Color.clear.contentShape(Rectangle())
                    .frame(width: size.width, height: size.height)
                    .onTapGesture { location in
                        if dividerDragStart == nil {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.13)) {
                                divider = min(1, max(0, location.x / max(1, size.width)))
                            }
                        }
                    }
                Rectangle().fill(.white.opacity(0.9)).frame(width: 1.8, height: size.height)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .position(x: size.width * divider, y: size.height / 2)
                    .allowsHitTesting(false)
                Circle().fill(.regularMaterial)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .semibold)))
                    .frame(width: 30, height: 30)
                    .position(x: size.width * divider, y: size.height / 2)
                    .allowsHitTesting(false)
                Color.clear.contentShape(Rectangle())
                    .frame(width: 32, height: size.height)
                    .position(x: size.width * divider, y: size.height / 2)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dividerDragStart == nil { dividerDragStart = divider }
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                divider = min(1, max(0,
                                    (dividerDragStart ?? divider) + value.translation.width / max(1, size.width)))
                            }
                        }
                        .onEnded { _ in dividerDragStart = nil })
                    .accessibilityLabel("Divisor de comparación")
                    .accessibilityHint("Arrastra para comparar las dos versiones")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder private var controls: some View {
        if #available(macOS 26, *), !reduceTransparency {
            GlassEffectContainer(spacing: 10) {
                actionRow.padding(10)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            }
        } else {
            actionRow.padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 18).fill(
                        reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor)
                    )
                }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 9) {
            Picker("Tipo", selection: $model.mode) {
                ForEach(ImageMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().frame(maxWidth: 160).disabled(model.running)
            Picker("Escala", selection: $model.scale) {
                ForEach([2,4,8,16], id: \.self) { Text("\($0)×").tag($0) }
            }.labelsHidden().frame(width: 64).disabled(model.running)
            Spacer(minLength: 0)
            if canCompare {
                Toggle(isOn: $compare) {
                    Image(systemName: "square.split.2x1").accessibilityLabel("Comparar original y resultado")
                }.toggleStyle(.button).help("Comparador")
            }
            Menu {
                Button("Añadir…", action: model.choose)
                Button(showQueue ? "Ocultar cola" : "Mostrar cola") { showQueue.toggle() }
                Button("Ajustar a ventana") { resetZoom() }
                Button("Ver al 100 %") {
                    if let preview = model.preview {
                        showActualSize(preview: preview)
                    }
                }
                Button("Reescalar de nuevo", action: model.reprocessSelected).disabled(model.running || model.selected == nil)
                Button("Guardar todos…", action: model.saveAll).disabled(!model.hasResults || model.saving)
                Button("Reintentar", action: model.retryFailed).disabled(model.running || model.items.isEmpty)
                Divider()
                Button("Limpiar sesión", action: model.reset).disabled(model.running || model.saving)
            } label: { Image(systemName: "ellipsis").frame(width: 24) }
                .menuStyle(.borderlessButton).accessibilityLabel("Más acciones")
            if model.running {
                Button("Cancelar", action: model.cancel)
            } else if model.hasPending {
                Button("Reescalar", action: model.start).modifier(PrimaryAction())
                    .keyboardShortcut(.defaultAction).disabled(model.saving || model.loading)
            } else if model.selected?.result != nil {
                Button("Guardar", action: model.save).modifier(PrimaryAction()).disabled(model.saving)
            } else {
                Button("Reescalar", action: model.start).disabled(true)
            }
        }
        .controlSize(.regular)
    }

    private var queue: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(model.items) { item in
                    Button { model.select(item.id) } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                                QueueThumbnail(url: item.input)
                            }
                            .frame(width: 62, height: 47).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                                item.id == model.selectedID ? Color.accentColor : .clear, lineWidth: 2))
                            HStack(spacing: 3) {
                                if item.result != nil { Image(systemName: "checkmark.circle.fill") }
                                else if item.state == "En proceso" { Image(systemName: "hourglass") }
                                Text(item.input.deletingPathExtension().lastPathComponent)
                                    .lineLimit(1).frame(width: 48)
                            }.font(.system(size: 9))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(item.input.lastPathComponent + " · " + item.state)
                    .accessibilityLabel(item.input.lastPathComponent + ", " + item.state)
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .frame(height: 87)
        .background(.bar)
    }

    private func loadComparison() {
        original = nil
        guard let selected = model.selected, let url = selected.result else { return }
        let token = UUID()
        compareToken = token
        Task.detached(priority: .userInitiated) {
            let source = CGImageSourceCreateWithURL(selected.input as CFURL, nil)
            let cg = source.flatMap {
                CGImageSourceCreateThumbnailAtIndex($0, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1800
                ] as CFDictionary)
            }
            await MainActor.run {
                guard compareToken == token, model.selected?.result == url else { return }
                original = cg.map { NSImage(cgImage: $0, size: .zero) }
            }
        }
    }
    private func resetZoom() {
        zoom = 1; gestureZoom = 1; model.actualSize = false
        model.refreshPreview()
    }

    private func showActualSize(preview: NSImage) {
        model.actualSize = true
        zoom = actualZoom(preview: preview, size: canvasSize)
        model.refreshPreview()
    }
    private func fit(image: NSImage, in bounds: CGSize) -> CGSize {
        let w = max(1, image.size.width), h = max(1, image.size.height)
        let scale = min(bounds.width / w, bounds.height / h)
        return CGSize(width: w * scale, height: h * scale)
    }
    private func actualZoom(preview: NSImage, size: CGSize) -> CGFloat {
        let fitted = fit(image: preview, in: size)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let actualWidth = CGFloat(model.metadata?.width ?? Int(preview.size.width))
        return max(1, (actualWidth / scale) / max(1, fitted.width))
    }
}

private struct MagnifyCompat: ViewModifier {
    @Binding var zoom: CGFloat
    @Binding var gestureZoom: CGFloat
    func body(content: Content) -> some View {
        content.gesture(MagnificationGesture().onChanged { gestureZoom = $0 }
            .onEnded { value in
                zoom = min(16, max(0.5, zoom * value))
                gestureZoom = 1
            })
    }
}
private extension View {
    func magnificationGestureCompat(zoom: Binding<CGFloat>, gestureZoom: Binding<CGFloat>) -> some View {
        modifier(MagnifyCompat(zoom: zoom, gestureZoom: gestureZoom))
    }
}

private struct QueueThumbnail: View {
    let url: URL
    @State private var thumbnail: NSImage?
    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
                    .frame(width: 62, height: 47).clipped()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            let result: CGImage? = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160
                ] as CFDictionary)
            }.value
            thumbnail = result.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}
