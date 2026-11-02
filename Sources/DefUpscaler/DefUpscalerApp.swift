import SwiftUI
import AppKit
import UpscaleCore

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
        .defaultSize(width: 640, height: 570)
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var targeted = false
    private var background: Color { scheme == .dark ? Color(red: 0.105, green: 0.115, blue: 0.13) : Color(red: 0.955, green: 0.955, blue: 0.945) }
    private var panel: Color { scheme == .dark ? Color(red: 0.145, green: 0.155, blue: 0.17) : Color(red: 0.99, green: 0.99, blue: 0.98) }
    private var accent: Color { scheme == .dark ? Color(red: 0.48, green: 0.64, blue: 0.79) : Color(red: 0.27, green: 0.43, blue: 0.59) }
    private var animation: Animation? { reduceMotion ? nil : .smooth(duration: 0.25) }

    var body: some View {
        VStack(spacing: 14) {
            previewArea
            if model.items.count > 1 {
                HStack(spacing: 10) {
                    Picker("Cola", selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.select(id) } })) {
                        ForEach(model.items) { item in
                            Text("\(item.input.lastPathComponent) · \(item.state)").tag(Optional(item.id))
                        }
                    }.labelsHidden().accessibilityLabel("Imagen seleccionada de la cola")
                    Text("\(model.items.count) imágenes").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Picker("Tipo", selection: $model.mode) {
                    ForEach(ImageMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(maxWidth: 180).disabled(model.running)
                Picker("Escala", selection: $model.scale) {
                    ForEach([2, 4, 8, 16], id: \.self) { Text("\($0)×").tag($0) }
                }.labelsHidden().frame(width: 68).disabled(model.running)
                Spacer(minLength: 4)
                Menu {
                    Button("Añadir imágenes…", action: model.choose)
                    if model.selected?.result != nil {
                        Button(model.showingResult ? "Ver original" : "Ver resultado") {
                            model.showingResult.toggle(); model.refreshPreview()
                        }
                    }
                    Button(model.actualSize ? "Ajustar a ventana" : "Ver al 100 %") {
                        model.actualSize.toggle(); model.refreshPreview()
                    }.disabled(model.preview == nil)
                    Button("Guardar todos…", action: model.saveAll).disabled(!model.hasResults || model.saving)
                    Button("Reintentar pendientes o fallidos", action: model.retryFailed).disabled(model.running || model.items.isEmpty)
                    Divider()
                    Button("Borrar sesión y temporales", action: model.reset).disabled(model.running || model.saving)
                    SettingsLink { Text("Ajustes…") }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Más opciones")
                if model.running {
                    Button("Cancelar", action: model.cancel).keyboardShortcut(.cancelAction)
                } else if model.hasPending {
                    Button("Reescalar", action: model.start).modifier(PrimaryAction()).keyboardShortcut(.defaultAction)
                        .disabled(model.saving || model.loading)
                } else if model.selected?.result != nil {
                    Button("Guardar…", action: model.save).modifier(PrimaryAction()).disabled(model.saving)
                } else {
                    Button("Reescalar", action: model.start).modifier(PrimaryAction()).disabled(true)
                }
            }
            .controlSize(.large)
            .padding(12)
            .background {
                if reduceTransparency { RoundedRectangle(cornerRadius: 16).fill(panel) }
                else { RoundedRectangle(cornerRadius: 16).fill(.thinMaterial) }
            }
            if model.metadata != nil {
                HStack {
                    Text(model.dimensions).font(.system(.caption, design: .monospaced)).textSelection(.enabled).help(model.estimatedMemory)
                    Spacer()
                    if model.scale > 4 { Text("IA 4× + interpolación").font(.caption) }
                    else if model.actualSize { Text("100 %").font(.system(.caption, design: .monospaced)) }
                }.foregroundStyle(.secondary)
            }
            if model.running {
                ProgressView(value: model.progress)
                HStack {
                    Text(model.phase)
                    Spacer()
                    Text("\(Int(model.progress * 100)) %").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
            } else if model.saving { ProgressView("Guardando…").controlSize(.small) }
            if let message = model.message {
                Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 460)
        .tint(accent)
        .background {
            ZStack {
                if !reduceTransparency { WindowMaterial() }
                background.opacity(reduceTransparency ? 1 : 0.91)
            }.ignoresSafeArea()
        }
    }

    private var previewArea: some View {
        GeometryReader { geometry in
            let maxWidth = max(1, geometry.size.width - 12)
            let maxHeight = max(1, geometry.size.height - 12)
            let width = min(maxWidth, maxHeight * model.aspect)
            let height = width / model.aspect
            ZStack {
                if model.actualSize, let preview = model.preview, model.metadata != nil {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: preview).resizable().interpolation(.none)
                            .frame(width: model.pixelViewSize.width / (NSScreen.main?.backingScaleFactor ?? 2),
                                   height: model.pixelViewSize.height / (NSScreen.main?.backingScaleFactor ?? 2))
                    }.background(panel).clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(panel)
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(targeted ? accent : Color.primary.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: model.preview == nil ? [5, 5] : []))
                        if let preview = model.preview {
                            Image(nsImage: preview).resizable().scaledToFit().padding(6)
                                .id(model.previewRevision).transition(.opacity)
                        } else {
                            VStack(spacing: 14) {
                                Image(systemName: "photo.badge.plus").font(.system(size: 30, weight: .light))
                                Text("Arrastra una imagen aquí").font(.system(size: 18, weight: .medium))
                                Button("Elegir imagen…", action: model.choose).controlSize(.large)
                            }.foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: model.preview == nil ? maxWidth : width, height: model.preview == nil ? maxHeight : height)
                    .animation(animation, value: model.previewRevision)
                    .animation(animation, value: model.aspect)
                    .animation(animation, value: model.preview == nil)
                }
                if model.loading { ProgressView().controlSize(.small).padding(12).background(panel, in: Capsule()) }
                if model.selected?.result != nil {
                    VStack {
                        HStack {
                            Spacer()
                            Button(model.showingResult ? "Resultado" : "Original") {
                                model.showingResult.toggle(); model.refreshPreview()
                            }.buttonStyle(.bordered).controlSize(.small).padding(12)
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: model.choose)
            .dropDestination(for: URL.self) { urls, _ in
                guard urls.contains(where: \.isFileURL) else { return false }
                model.add(urls); return true
            } isTargeted: { targeted = $0 }
            .accessibilityLabel("Vista previa. Arrastra imágenes o usa Abrir imagen.")
            .accessibilityAction(named: "Elegir imagen", model.choose)
        }.frame(minHeight: 260)
    }
}
