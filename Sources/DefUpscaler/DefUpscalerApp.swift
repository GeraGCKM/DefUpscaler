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
                Button("Guardar todos…", action: model.saveAll)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.hasResults || model.saving)
                Button("Ajustar a ventana") {
                    model.actualSize = false
                    model.refreshPreview()
                }.keyboardShortcut("0", modifiers: .command)
                Button("Tamaño real") {
                    model.actualSize = true
                    model.refreshPreview()
                }.keyboardShortcut("1", modifiers: .command).disabled(model.preview == nil)
                Button("Mostrar u ocultar resultados") {
                    model.showingResult.toggle()
                    model.refreshPreview()
                }.keyboardShortcut("d", modifiers: .command).disabled(model.selected?.result == nil)
            }
        }
        Settings {
            Form {
                Picker("Apariencia", selection: $appearance) {
                    Text("Sistema").tag("system")
                    Text("Clara").tag("light")
                    Text("Oscura").tag("dark")
                }
                Toggle("Mezcla conservadora para fotografía", isOn: $model.proFidelity)
                    .help("Conserva 75 % del remuestreo tradicional y 25 % de inferencia neuronal. No garantiza mayor fidelidad; compárala con el modo estándar.")
                    .disabled(model.running)
                Text("La mezcla conservadora evita algunos cambios de textura, pero no recupera más detalle real. Para uso normal, déjala desactivada.")
                    .font(.caption).foregroundStyle(.secondary)
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var targeted = false
    @State private var compare = true
    @State private var divider = 0.5
     @State private var showQueue = true
    @State private var original: NSImage?
    @State private var compareToken = UUID()
    @State private var dividerDragStart: CGFloat?
    private var movement: Animation? { reduceMotion ? nil : .smooth(duration: 0.24) }
    private var canCompare: Bool {
        model.selected?.result != nil && original != nil &&
        model.previewItemID == model.selectedID && model.showingResult
    }

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
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if model.preview != nil && !reduceTransparency {
                RadialGradient(colors: [
                    model.ambiance.opacity(scheme == .dark ? 0.4 : 0.22),
                    model.ambiance.opacity(scheme == .dark ? 0.1 : 0.06),
                    .clear
                ], center: .center, startRadius: 0, endRadius: 620)
                .animation(movement, value: model.previewRevision)
                .allowsHitTesting(false)
            }
            if let preview = model.preview {
                NativeImageCanvas(
                    result: preview,
                    original: original,
                    comparing: compare && canCompare,
                    identity: model.selectedID,
                    actualSize: model.actualSize,
                    imagePixelWidth: model.metadata?.width ?? Int(preview.size.width),
                    reduceMotion: reduceMotion,
                    onToggleActualSize: {
                        model.actualSize.toggle()
                        model.refreshPreview()
                    }
                )
                .id(model.selectedID)
                .accessibilityLabel("Imagen, desplaza con dos dedos o pellizca para ampliar")
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
            if model.loading {
                ProgressView().controlSize(.small).padding(12)
                    .background(.regularMaterial, in: Capsule())
                    .allowsHitTesting(false)
            }
            if targeted {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(.tint, lineWidth: 2).padding(6)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if model.preview != nil {
                HStack(spacing: 8) {
                    Text(model.dimensions).monospacedDigit()
                    if model.actualSize {
                        Button("Ajustar", action: resetZoom)
                            .buttonStyle(.plain).foregroundStyle(.primary)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(10)
                .background(.regularMaterial, in: Capsule())
                .padding(16)
            }
        }
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
                ForEach(ImageMode.allCases.filter {
                    $0 != .photoDetail ||
                    Bundle.main.url(forResource: "WebPhoto4x", withExtension: "mlmodelc") != nil
                }, id: \.self) { Text($0.title).tag($0) }
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
                    model.actualSize = true
                    model.refreshPreview()
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
            LazyHStack(spacing: 8) {
                ForEach(model.items) { item in
                    QueueCell(item: item, selected: item.id == model.selectedID) {
                        model.select(item.id)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .frame(height: 85)
        .background(.bar)
        .accessibilityLabel("Cola de imágenes")
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
        model.actualSize = false
        model.refreshPreview()
    }
}

private struct QueueCell: View {
    let item: QueueItem
    let selected: Bool
    let onSelect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 5) {
                QueueThumbnail(url: item.input)
                    .frame(width: 68, height: 47)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovered ? 0.26 : 0), lineWidth: selected ? 2 : 1)
                    }
                HStack(spacing: 3) {
                    if item.result != nil {
                        Image(systemName: item.proFidelity ? "sparkles" : "checkmark.circle.fill")
                    } else if item.state == "En proceso" {
                        Image(systemName: "hourglass")
                    }
                    Text(item.input.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10, weight: selected ? .medium : .regular))
                .frame(width: 68)
            }
            .padding(5)
            .background(selected ? Color.accentColor.opacity(0.09) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 13))
            .scaleEffect(hovered ? 1.035 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.19), value: hovered)
        .animation(reduceMotion ? nil : .smooth(duration: 0.23), value: selected)
        .help(item.input.lastPathComponent + " · " + item.state)
        .accessibilityLabel(item.input.lastPathComponent + ", " + item.state)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
