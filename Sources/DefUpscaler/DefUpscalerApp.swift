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
                    model.setActualSize(false)
                }.keyboardShortcut("0", modifiers: .command)
                Button("Tamaño real") {
                    model.setActualSize(true)
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
    @Namespace private var glassNamespace
    @State private var targeted = false
    @State private var compare = true
    @State private var showQueue = true
    @State private var original: NSImage?
    @State private var originalItemID: UUID?
    @State private var compareToken = UUID()
    @State private var comparisonTask: Task<Void, Never>?
    private var movement: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88) }
    private var canCompare: Bool {
        model.selected?.result != nil && original != nil &&
        model.previewItemID == model.selectedID && model.showingResult
    }

    var body: some View {
        VStack(spacing: 0) {
            workspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            // The control shelf has its own space: glass never covers inspected pixels.
            controls.padding(.horizontal, 16).padding(.vertical, 10)
            if let message = model.message {
                HStack(alignment: .top, spacing: 8) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Cerrar mensaje")
                }.padding(.horizontal, 22).padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showQueue && !model.items.isEmpty {
                queue.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 540, minHeight: 420)
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else { WindowMaterial().overlay(model.ambiance.opacity(scheme == .dark ? 0.13 : 0.06)) }
        }
        .background(WindowAspectObserver(aspect: model.preview == nil ? nil : CGFloat(model.aspect), reduceMotion: reduceMotion))
        .onChange(of: model.selectedID) { _, _ in loadComparison() }
        .onChange(of: model.detailedPreview) { _, _ in loadComparison() }
        .onChange(of: model.actualSize) { _, _ in loadComparison() }
        .onChange(of: model.selected?.result) { _, _ in loadComparison() }
        .onAppear(perform: loadComparison)
        .onDisappear { comparisonTask?.cancel() }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            let files = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
            Task { @MainActor in
                var urls: [URL] = []
                // Preserve drop order and select the last image only once.
                for provider in files {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            continuation.resume(returning: url)
                        }
                    }
                    if let url { urls.append(url) }
                }
                model.add(urls)
            }
            return !files.isEmpty
        }
        .animation(movement, value: showQueue)
        .animation(movement, value: model.previewItemID)
        .animation(movement, value: targeted)
        .animation(movement, value: canCompare)
        .animation(movement, value: model.message)
        .animation(movement, value: model.items.isEmpty)
    }

    private var workspace: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if model.preview != nil && !reduceTransparency {
                // Apple Music-like atmosphere without a live full-image blur:
                // three precomputed area colors drive static system gradients.
                RadialGradient(colors: [
                    model.ambianceSecondary.opacity(scheme == .dark ? 0.35 : 0.19),
                    .clear
                ], center: .topLeading, startRadius: 24, endRadius: 690)
                    .allowsHitTesting(false)
                RadialGradient(colors: [
                    model.ambianceTertiary.opacity(scheme == .dark ? 0.32 : 0.17),
                    .clear
                ], center: .bottomTrailing, startRadius: 16, endRadius: 620)
                    .allowsHitTesting(false)
                RadialGradient(colors: [
                    model.ambiance.opacity(scheme == .dark ? 0.20 : 0.11),
                    .clear
                ], center: .center, startRadius: 0, endRadius: 700)
                    .allowsHitTesting(false)
                    .animation(movement, value: model.previewRevision)
            }
            if let preview = model.preview {
                NativeImageCanvas(
                    result: preview,
                    original: original,
                    comparing: compare && canCompare,
                    identity: model.previewItemID,
                    actualSize: model.actualSize,
                    zoomRevision: model.zoomRevision,
                    imagePixelWidth: model.metadata?.width ?? Int(preview.size.width),
                    reduceMotion: reduceMotion,
                    onRequestDetail: model.requestDetailedPreview,
                    onToggleActualSize: {
                        model.setActualSize(!model.actualSize)
                    }
                )
                // Preserve the same native scroll view across selections: the
                // AppKit canvas performs a real interruptible content transition.
                .accessibilityLabel("Imagen, desplaza con dos dedos o pellizca para ampliar")
                .transition(reduceMotion ? .opacity : .scale(scale: 0.965).combined(with: .opacity))
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
                    .transition(.scale(scale: 0.98).combined(with: .opacity))
            }
        }
        .help(model.dimensions)
    }

    private var progressRow: some View {
        VStack(spacing: 6) {
            ProgressView(value: model.progress)
                .animation(reduceMotion ? nil : .linear(duration: 0.12), value: model.progress)
            HStack {
                Text(model.phase)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Text("\(Int(model.progress * 100)) %")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var controls: some View {
        if #available(macOS 26, *), !reduceTransparency {
            GlassEffectContainer(spacing: 18) {
                HStack(spacing: 12) {
                    actionRow
                        .padding(10)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .glassEffectID("options", in: glassNamespace)
                    actionSurface
                        .padding(10)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 23))
                        // Stable identity makes action → progress → save one surface.
                        .glassEffectID("operation", in: glassNamespace)
                        .glassEffectTransition(.matchedGeometry)
                }
            }
            .animation(movement, value: model.running)
            .animation(movement, value: model.hasPending)
            .animation(movement, value: model.selected?.result)
        } else {
            HStack(spacing: 12) {
                actionRow.padding(10)
                actionSurface.padding(10)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 23))
            .animation(movement, value: model.running)
        }
    }

    private var actionSurface: some View {
        HStack(spacing: 10) {
            if model.running {
                progressRow.frame(minWidth: 80, maxWidth: 220)
                    .transition(.scale(scale: 0.94, anchor: .trailing).combined(with: .opacity))
                Button(action: model.cancel) { Image(systemName: "stop.fill") }
                    .buttonStyle(.plain).frame(width: 28, height: 28)
                    .help("Cancelar").accessibilityLabel("Cancelar procesamiento")
                    .keyboardShortcut(.cancelAction)
            } else if model.hasPending {
                Button(action: model.start) { Label("Reescalar", systemImage: "play.fill") }
                    .modifier(PrimaryAction()).keyboardShortcut(.defaultAction)
                    .disabled(model.saving || model.loading)
            } else if model.selected?.result != nil {
                Button(action: model.save) { Label("Guardar", systemImage: "square.and.arrow.down") }
                    .modifier(PrimaryAction()).disabled(model.saving)
            } else {
                Button("Reescalar", action: model.start).disabled(true)
            }
        }
        .fixedSize(horizontal: !model.running, vertical: false)
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
                    model.setActualSize(true)
                }
                Button("Reescalar de nuevo", action: model.reprocessSelected).disabled(model.running || model.selected == nil)
                Button("Guardar todos…", action: model.saveAll).disabled(!model.hasResults || model.saving)
                Button("Reintentar", action: model.retryFailed).disabled(model.running || model.items.isEmpty)
                Divider()
                Button("Limpiar sesión", action: model.reset).disabled(model.running || model.saving)
            } label: { Image(systemName: "ellipsis").frame(width: 24) }
                .menuStyle(.borderlessButton).accessibilityLabel("Más acciones")

        }
        .controlSize(.regular)
    }

    private var queue: some View {
        ScrollViewReader { proxy in
          ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(model.items) { item in
                    QueueCell(item: item, selected: item.id == model.selectedID, selectionNamespace: glassNamespace) {
                        withAnimation(movement) { model.select(item.id) }
                    }.id(item.id)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
          .scrollIndicators(.hidden)
          .onChange(of: model.selectedID) { _, id in
              if let id { withAnimation(movement) { proxy.scrollTo(id, anchor: .center) } }
          }
        }
        .frame(height: 85)
        .background(.bar)
        .accessibilityLabel("Cola de imágenes")
    }

    private func loadComparison() {
        comparisonTask?.cancel()
        let token = UUID()
        compareToken = token
        if originalItemID != model.selectedID { original = nil }
        guard let selected = model.selected, let url = selected.result else {
            original = nil
            originalItemID = nil
            return
        }
        let full = model.actualSize || model.detailedPreview
        comparisonTask = Task {
            do {
                let cg = try await PreviewDecoder.inspection.image(at: selected.input,
                    maximumDimension: full ? 32768 : 1800)
                guard !Task.isCancelled, compareToken == token,
                      model.selectedID == selected.id, model.selected?.result == url else { return }
                original = NSImage(cgImage: cg, size: .zero)
                originalItemID = selected.id
            } catch is CancellationError {} catch {
                guard compareToken == token else { return }
                original = nil
            }
        }
    }

    private func resetZoom() {
        model.setActualSize(false)
    }
}

private struct QueueCell: View {
    let item: QueueItem
    let selected: Bool
    let selectionNamespace: Namespace.ID
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
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.accentColor.opacity(0.12))
                        .matchedGeometryEffect(id: "queue-selection", in: selectionNamespace)
                }
            }
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
        .onDisappear { thumbnail = nil }
        .task(id: url) {
            do {
                let result = try await PreviewDecoder.thumbnails.image(at: url, maximumDimension: 160)
                guard !Task.isCancelled else { return }
                thumbnail = NSImage(cgImage: result, size: .zero)
            } catch { /* Keep the lightweight placeholder for unreadable files. */ }

        }
    }
}
