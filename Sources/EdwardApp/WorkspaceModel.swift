import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EdwardDomain
import EdwardPersistence
import EdwardJobs
import EdwardProviders

enum WorkspaceSection: String, CaseIterable {
    case queue = "Studio", library = "Library", presets = "Presets", providers = "AI connections", preferences = "Preferences"
    var icon: String {
        switch self { case .queue: return "square.stack.3d.up"; case .library: return "play.rectangle.on.rectangle"; case .presets: return "slider.horizontal.3"; case .providers: return "point.3.connected.trianglepath.dotted"; case .preferences: return "gearshape" }
    }
}
@MainActor final class WorkspaceModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var section: WorkspaceSection = .queue
    @Published var selectedJobID: UUID?
    @Published var selectedClipID: UUID?
    @Published var error: String?
    @Published var showLink = false
    @Published var showStart = false
    @Published var showEditor = false
    @Published var showWelcome = false
    @Published var search = ""
    let coordinator: JobCoordinator
    let store: ProjectStore
    init() throws {
        let override = ProcessInfo.processInfo.environment["EDWARD_WORKSPACE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let paths = try WorkspacePaths(root: override)
        store = try ProjectStore(paths: paths)
        coordinator = JobCoordinator(store: store)
        settings = AppSettings(outputDirectory: WorkspacePaths.defaultExports)
    }
    func load() async {
        do {
            if let saved = try await store.loadSettings() { settings = saved }
            else { showWelcome = true }
            try await coordinator.load()
            selectedJobID = coordinator.jobs.first?.id
        } catch { self.error = error.localizedDescription }
    }
    func saveSettings() { Task { do { try await store.saveSettings(settings) } catch { self.error = error.localizedDescription } } }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "Choose long-form videos to add to your batch."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }
    func add(_ urls: [URL]) {
        Task {
            for url in urls {
                do { selectedJobID = try await coordinator.add(source: url.isFileURL ? url.path : url.absoluteString, configuration: settings.jobConfiguration) }
                catch { self.error = error.localizedDescription }
            }
            section = .queue
        }
    }
    func addLink(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            error = "Enter a complete http or https video URL."; return
        }
        add([url]); showLink = false
    }
    func chooseOutput() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.outputDirectory = url; saveSettings()
    }
    func importTranscript(jobID: UUID) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .plainText, UTType(filenameExtension: "srt") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { try await coordinator.importTranscript(url, for: jobID) } catch { self.error = error.localizedDescription } }
    }
    func copyTranscript(_ job: JobCheckpoint) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(job.transcript?.text ?? "", forType: .string)
    }
    func saveTranscript(_ job: JobCheckpoint) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(job.title)-transcript.txt"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try (job.transcript?.text ?? "").write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
    func saveDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Edward-diagnostics.txt"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = coordinator.jobs.map { "\($0.id): state=\($0.state.rawValue), stage=\($0.stage.rawValue), clips=\($0.clips.count), completed=\($0.completedStages.map(\.rawValue).joined(separator: ","))" }
        let report = "Edward Scissorhands 0.1.0\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nDiagnostics intentionally exclude keys, URLs, paths, prompts, transcripts and server responses.\n" + lines.joined(separator: "\n")
        do { try report.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
    func perform(_ operation: @escaping () async throws -> Void) { Task { do { try await operation() } catch { self.error = error.localizedDescription } } }
}
