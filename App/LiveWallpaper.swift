import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class Screen: ObservableObject {
    @Published var pair: WallpaperPair?
    @Published var source: String?
    @Published var busy = false
    @Published var importing = false
    @Published var imported = false
    @Published var problem: String?
    @Published var notice: String?
    @Published var preview: NSImage?
    @Published var dragging = false
    @Published var help = false
    @Published var details = false

    func pick() {
        guard !busy, !importing else { return }
        let panel = NSOpenPanel()
        panel.title = "Video auswählen"
        panel.prompt = "Umwandeln"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { start(url) }
    }

    func start(_ input: URL) {
        guard !busy, !importing else { return }
        guard let ffmpeg = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg"),
              let profile = Bundle.main.url(forResource: "Wallpaper-Profil", withExtension: "mov") else {
            problem = "Die App-Dateien sind unvollständig. Öffne die unveränderte Live Wallpaper.app."
            return
        }
        if let old = pair { try? FileManager.default.removeItem(at: old.folder) }
        pair = nil
        preview = nil
        source = input.lastPathComponent
        problem = nil
        notice = nil
        busy = true
        imported = false

        Task {
            defer { busy = false }
            var staged: WallpaperPair?
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try Converter.build(video: input, ffmpeg: ffmpeg, template: profile)
                }.value
                staged = output
                try await PhotosBridge.validate(output)
                preview = NSImage(contentsOf: output.image)
                pair = output
            } catch {
                if let staged { try? FileManager.default.removeItem(at: staged.folder) }
                problem = error.localizedDescription
            }
        }
    }

    func addToPhotos() {
        guard let pair, !imported, !importing else { return }
        importing = true
        problem = nil
        notice = nil
        Task {
            defer { importing = false }
            do {
                try await PhotosBridge.add(pair)
                imported = true
                notice = "Als Live Photo in Fotos gesichert."
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func saveFiles() {
        guard let pair else { return }
        let panel = NSOpenPanel()
        panel.title = "Ordner für das Live Photo wählen"
        panel.prompt = "Hier sichern"
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let output = try pair.export(to: destination)
            problem = nil
            notice = "Dateipaar im Finder gesichert."
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            problem = "Die Dateien konnten dort nicht gesichert werden. \(error.localizedDescription)"
        }
    }
}

private struct Home: View {
    @StateObject private var screen = Screen()
    private let blue = Color(red: 0.11, green: 0.34, blue: 0.83)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if screen.busy {
                    processing
                } else if screen.pair != nil {
                    result
                } else {
                    input
                }
                if let error = screen.problem {
                    if error.count > 190 {
                        DisclosureGroup(isExpanded: $screen.details) {
                            Text(error).font(.caption.monospaced()).textSelection(.enabled)
                        } label: {
                            Label("Das Video oder die Aktion konnte nicht verarbeitet werden.", systemImage: "exclamationmark.circle")
                        }
                        .foregroundStyle(.red)
                    } else {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    }
                } else if let message = screen.notice {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
                footer
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(maxWidth: 750)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 535, minHeight: 407)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first, url.isFileURL, !screen.busy, !screen.importing else { return false }
            screen.start(url)
            return true
        } isTargeted: { screen.dragging = $0 }
        .onOpenURL { screen.start($0) }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(blue.gradient)
                Image(systemName: "livephoto").font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
            }
            .frame(width: 48, height: 48).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Live Wallpaper").font(.system(size: 27, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text("Aus einem Video wird dein iPhone-Hintergrund.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var input: some View {
        VStack(spacing: 10) {
            Image(systemName: "film").font(.system(size: 35, weight: .light))
                .foregroundStyle(blue).accessibilityHidden(true)
            Text("Video hierher ziehen").font(.title3.weight(.semibold))
            Text("Das letzte Bild wird zum Standbild.").font(.callout).foregroundStyle(.secondary)
            Button("Video auswählen…", action: screen.pick)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut("o", modifiers: [.command])
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, minHeight: 206)
        .padding(12)
        .background(screen.dragging ? blue.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(screen.dragging ? blue : Color(nsColor: .separatorColor),
                          style: StrokeStyle(lineWidth: screen.dragging ? 2 : 1, dash: [5, 5])))
    }

    private var processing: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("Live Photo wird erstellt …").font(.title3.weight(.semibold))
            Text(screen.source ?? "Video").font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 214)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var result: some View {
        HStack(alignment: .center, spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .underPageBackgroundColor))
                if let preview = screen.preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "livephoto").font(.title)
                }
            }
            .frame(width: 91, height: 198)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .accessibilityLabel("Vorschau des Standbilds")
            VStack(alignment: .leading, spacing: 10) {
                Label("Live Photo fertig", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                Text(screen.source ?? "Video").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Button(screen.importing ? "Wird gesichert …" : (screen.imported ? "In Fotos gesichert" : "In Fotos sichern"),
                       action: screen.addToPhotos)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(screen.importing || screen.imported)
                HStack(spacing: 10) {
                    Button("Dateien sichern…", action: screen.saveFiles)
                    Button("Neues Video…", action: screen.pick).keyboardShortcut("o", modifiers: [.command])
                }
                .controlSize(.regular)
                .disabled(screen.importing)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var footer: some View {
        HStack {
            Label("Offline auf deinem Mac", systemImage: "lock")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Aufs iPhone übertragen", systemImage: "iphone") { screen.help.toggle() }
                .buttonStyle(.borderless)
                .popover(isPresented: $screen.help, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Aufs iPhone übertragen").font(.headline)
                        Text("Sichere das Live Photo in Fotos. Über iCloud-Fotos erscheint es auf deinem iPhone, wenn die Synchronisierung bereits aktiv ist. Du kannst es auch als einzelnen Live-Photo-Eintrag aus Fotos teilen.")
                        Text("Auf dem iPhone: Einstellungen → Hintergrundbild → Fotos → Live Photo. Aktiviere die Wiedergabetaste und prüfe die Bewegung beim Aufwecken.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(18).frame(width: 325)
                }
        }
    }
}

@main
struct LiveWallpaperApp: App {
    var body: some Scene {
        Window("Live Wallpaper", id: "live-wallpaper") { Home() }
            .defaultSize(width: 565, height: 430)
            .windowResizability(.contentMinSize)
    }
}
