import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        Self.removeTemporaryResults()
    }
    static func removeTemporaryResults() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DefUpscaler", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }
}

@main
struct DefUpscalerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    init() { AppDelegate.removeTemporaryResults() }

    var body: some Scene {
        Window("DefUpscaler", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 580, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Abrir imagen…", action: model.choose).keyboardShortcut("o").disabled(model.running)
                Button("Guardar resultado…", action: model.save).keyboardShortcut("s").disabled(model.resultPreview == nil)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("DefUpscaler").font(.headline)
                Spacer()
                Text("Local · Anime 4×").font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(targeted ? 0.08 : 0.035))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: model.preview == nil ? [5] : []))
                if let preview = (model.showingResult ? model.resultPreview : nil) ?? model.preview {
                    Image(nsImage: preview).resizable().scaledToFit().padding(12)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 30, weight: .light))
                        Text("Arrastra una imagen aquí").font(.system(size: 18))
                        Button("Elegir imagen…", action: model.choose)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 280, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, url.isFileURL, !model.running else { return false }
                model.load(url)
                return true
            } isTargeted: { targeted = $0 }
            .accessibilityLabel("Imagen de entrada y vista previa")

            HStack {
                Picker("Escala", selection: $model.scale) {
                    Text("2×").tag(2)
                    Text("4×").tag(4)
                }.pickerStyle(.segmented).frame(width: 130).disabled(model.running)
                Spacer()
                Toggle("Modo tranquilo", isOn: $model.gentle).toggleStyle(.checkbox).disabled(model.running)
                    .help("Añade pausas entre bloques. No fija un porcentaje de CPU o GPU.")
            }
            Text("Para ilustración y anime · PNG de salida · Transparencia sobre blanco")
                .font(.caption).foregroundStyle(.secondary)
            if model.running {
                ProgressView(value: model.progress)
                Text("\(Int(model.progress * 100)) % · Cancelación entre bloques")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let message = model.message {
                Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Otra imagen…", action: model.choose).disabled(model.running)
                if model.resultPreview != nil {
                    Toggle("Resultado", isOn: $model.showingResult).toggleStyle(.button)
                }
                Spacer()
                if model.running {
                    Button("Cancelar", action: model.cancel).keyboardShortcut(.cancelAction)
                } else if model.resultPreview != nil {
                    Button("Guardar…", action: model.save).buttonStyle(.borderedProminent)
                    Button("Repetir", action: model.start)
                } else {
                    Button("Mejorar", action: model.start).buttonStyle(.borderedProminent).disabled(model.input == nil)
                        .keyboardShortcut(.defaultAction)
                }
            }
            Button("Borrar sesión y temporales", action: model.reset)
                .buttonStyle(.link).font(.caption).disabled(model.running)
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
