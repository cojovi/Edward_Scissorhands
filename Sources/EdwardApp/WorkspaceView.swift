import SwiftUI
import AppKit
import AVKit
import EdwardDomain
import EdwardJobs

struct WorkspaceView: View {
    @State private var model: WorkspaceModel?
    @State private var failure: String?
    var body: some View {
        Group {
            if let model { LoadedWorkspace(model: model, coordinator: model.coordinator) }
            else if let failure { ContentUnavailableView("The library could not open", systemImage: "externaldrive.badge.exclamationmark", description: Text(failure)) }
            else { ProgressView("Opening your studio…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(Studio.background)
            .task {
                guard model == nil else { return }
                do { let m = try WorkspaceModel(); model = m; await m.load() } catch { failure = error.localizedDescription }
            }
    }
}

struct LoadedWorkspace: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var coordinator: JobCoordinator
    @State private var dropTarget = false
    @State private var link = ""
    @State private var excludedReview: Set<UUID> = []
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var transcriptJob: JobCheckpoint?
    @State private var unknownJob: UUID?
    @State private var currentConnectionsJob: UUID?
    @State private var completedIDs: Set<UUID> = []
    var selectedJob: JobCheckpoint? { coordinator.jobs.first { $0.id == model.selectedJobID } }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Studio.line.opacity(0.55)).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Studio.line.opacity(0.55)).frame(height: 1)
                Group {
                    switch model.section {
                    case .providers: ProviderSettingsView(model: model)
                    case .preferences: PreferencesView(model: model)
                    case .presets: PresetsView(model: model)
                    case .queue, .library: studioContent
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        }.background(Studio.background).foregroundStyle(Studio.white).tint(Studio.green)
            .sheet(isPresented: $model.showLink) { linkSheet }
            .sheet(isPresented: $model.showStart) { BatchReviewSheet(model: model, coordinator: coordinator) }
            .sheet(isPresented: $model.showWelcome) { WelcomeSheet(model: model) }
            .sheet(item: $transcriptJob) { job in TranscriptSheet(model: model, job: job) }
            .sheet(isPresented: $model.showEditor) {
                if let job = selectedJob, let clip = job.clips.first(where: { $0.id == model.selectedClipID }) {
                    ClipEditorView(model: model, job: job, clip: clip)
                }
            }
            .alert("Needs your attention", isPresented: Binding(get: { model.error != nil || coordinator.notice != nil }, set: { if !$0 { model.error = nil; coordinator.notice = nil } })) {
                Button("OK") { model.error = nil; coordinator.notice = nil }
            } message: { Text(model.error ?? coordinator.notice ?? "") }
            .alert("Resolve interrupted AI request", isPresented: Binding(get: { unknownJob != nil }, set: { if !$0 { unknownJob = nil } })) {
                Button("Cancel", role: .cancel) { unknownJob = nil }
                Button("I checked usage · allow retry") {
                    if let id = unknownJob { model.perform { try await coordinator.resolveUnknown(id) } }; unknownJob = nil
                }
            } message: { Text("The provider may have billed the interrupted request. Check its dashboard first. A retry may incur another charge; completed cached responses will be reused.") }
            .alert("Resume with current AI connections?", isPresented: Binding(get: { currentConnectionsJob != nil }, set: { if !$0 { currentConnectionsJob = nil } })) {
                Button("Cancel", role: .cancel) { currentConnectionsJob = nil }
                Button("Resume") {
                    if let id = currentConnectionsJob {
                        let configuration = model.settings.jobConfiguration
                        model.perform { try await coordinator.resumeWithCurrentConnections(id, configuration: configuration) }
                    }
                    currentConnectionsJob = nil
                }
            } message: {
                let configuration = model.settings.jobConfiguration
                Text("The saved transcript and source settings will be kept. Analysis will use \(configuration.editorial.name) / \(configuration.editorial.model); \(configuration.visual == nil ? "visual review is off" : "visual review may also send selected frames"). The selected connections may receive transcript text and may charge for new requests. Your current spending settings apply.")
            }
            .alert("Rename source", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { if let id = renaming { model.perform { try await coordinator.rename(id, title: renameText) } }; renaming = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: .edwardSettings)) { _ in model.section = .preferences }
            .onChange(of: coordinator.jobs.filter { $0.state == .completed }.map(\.id)) { _, ids in
                let new = Set(ids).subtracting(completedIDs)
                if coordinator.isRunning && !new.isEmpty {
                    if model.settings.soundWhenFinished { NSSound.beep() }
                    if model.settings.revealWhenFinished, let job = coordinator.jobs.first(where: { new.contains($0.id) }), let url = job.clips.first?.outputURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                completedIDs = Set(ids)
            }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                BrandMark(size: 44)
                VStack(alignment: .leading, spacing: 3) { Text("EDWARD").font(.system(size: 15, weight: .black)).tracking(2); Text("SCISSORHANDS").font(Studio.mono(8)).tracking(2.1).foregroundStyle(Studio.muted) }
            }.padding(.top, 26).padding(.bottom, 38).padding(.horizontal, 22)
            Eyebrow(text: "Workspace").padding(.horizontal, 24).padding(.bottom, 14)
            ForEach([WorkspaceSection.queue, .library, .presets], id: \.self) { nav($0) }
            Eyebrow(text: "Engine").padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 14)
            nav(.providers); nav(.preferences)
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack { Circle().fill(Studio.green).frame(width: 6, height: 6); Text("LOCAL FIRST").font(Studio.mono(9)).tracking(1.7) }
                Text("Your footage.\nYour models. Your cut.").font(.system(size: 13, weight: .medium)).lineSpacing(4).foregroundStyle(Studio.muted)
                Rectangle().fill(Studio.line).frame(height: 1).padding(.vertical, 4)
                HStack { Text("PRIVATE STUDIO").font(Studio.mono(8)).tracking(1.2); Spacer(); Text("v0.1").font(Studio.mono(9)) }.foregroundStyle(Studio.muted)
            }.padding(20).background(Studio.pine).overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
        }.frame(width: 220).background(Studio.pine)
    }
    private func nav(_ section: WorkspaceSection) -> some View {
        Button { model.section = section } label: {
            HStack(spacing: 12) {
                Image(systemName: section.icon).font(.system(size: 15)).frame(width: 20)
                Text(section.rawValue).font(.system(size: 13, weight: model.section == section ? .semibold : .regular))
                Spacer()
                if section == .queue { Text("\(coordinator.jobs.filter { $0.state != .completed }.count)").font(Studio.mono(10)).foregroundStyle(model.section == section ? Studio.green : Studio.muted) }
            }.foregroundStyle(model.section == section ? Studio.white : Studio.muted).padding(.horizontal, 14).padding(.vertical, 12)
                .background(model.section == section ? Studio.raised : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) { if model.section == section { RoundedRectangle(cornerRadius: 2).fill(Studio.green).frame(width: 3, height: 18).offset(x: -1) } }
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow(text: "Edward / \(model.section.rawValue)")
                Text(model.section == .queue ? "Make the cut." : model.section.rawValue).font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-0.8)
            }
            Spacer()
            if coordinator.isRunning {
                Button { coordinator.pause() } label: { Label("Pause", systemImage: "pause") }.buttonStyle(SignalButton())
                Button { coordinator.cancelCurrent() } label: { Image(systemName: "stop.fill") }.buttonStyle(SignalButton()).help("Cancel current job")
            } else {
                Button { model.showLink = true } label: { Label("Paste link", systemImage: "link") }.buttonStyle(SignalButton()).keyboardShortcut("l", modifiers: .command)
                Button { model.chooseFiles() } label: { Label("Add footage", systemImage: "plus") }.buttonStyle(SignalButton(prominent: true)).keyboardShortcut("o", modifiers: .command)
            }
        }.padding(.horizontal, 28).padding(.vertical, 23)
    }
    private var studioContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Eyebrow(text: model.section == .library ? "Your finished work" : "Production queue")
                    Text(String(format: "%02d", coordinator.jobs.count)).font(Studio.mono(10)).padding(.horizontal, 6).padding(.vertical, 3).background(Studio.raised, in: Capsule())
                    Spacer()
                    if !coordinator.jobs.isEmpty {
                        TextField("Search sources", text: $model.search).textFieldStyle(.plain).font(.system(size: 12)).frame(width: 150)
                    }
                }
                if coordinator.jobs.isEmpty { emptyStudio }
                else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(coordinator.jobs.filter { (model.search.isEmpty || $0.title.localizedCaseInsensitiveContains(model.search)) && (model.section != .library || $0.state == .completed || $0.state == .awaitingReview) }) { job in jobCard(job) }
                        }
                    }
                    if let job = selectedJob { resultStrip(job) }
                }
                Spacer(minLength: 0)
                if !coordinator.jobs.isEmpty {
                    HStack {
                        Text("\(coordinator.jobs.filter { $0.state == .queued }.count) sources ready").font(.system(size: 12)).foregroundStyle(Studio.muted)
                        Spacer()
                        Button { model.showStart = true } label: { Label("Start batch", systemImage: "play.fill") }.buttonStyle(SignalButton(prominent: true)).disabled(coordinator.isRunning || !coordinator.jobs.contains { $0.state == .queued })
                    }
                }
            }.padding(28).frame(maxWidth: .infinity)
                .dropDestination(for: URL.self) { urls, _ in model.add(urls); return true } isTargeted: { dropTarget = $0 }
                .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).strokeBorder(Studio.green, style: StrokeStyle(lineWidth: 2, dash: [8])).padding(12).allowsHitTesting(false) } }
            Rectangle().fill(Studio.line.opacity(0.5)).frame(width: 1)
            PresetInspector(model: model).frame(width: 286)
        }
    }
    private var emptyStudio: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Eyebrow(text: "Long form → Short form", color: Studio.green); Spacer(); Image(systemName: "viewfinder").font(.system(size: 22, weight: .ultraLight)).foregroundStyle(Studio.muted) }
            Spacer(minLength: 35)
            Text("Long stories.\nSharp moments.").font(.system(size: 43, weight: .semibold, design: .rounded)).tracking(-1.5).lineSpacing(-2)
            Text("Turn your recordings into a collection of\nready-to-share clips. Start with a video.").font(.system(size: 14)).lineSpacing(5).foregroundStyle(Studio.muted).padding(.top, 18)
            EmptyTimeline().padding(.top, 28).padding(.bottom, 24)
            HStack {
                Image(systemName: "arrow.down.doc").font(.system(size: 20, weight: .light)).foregroundStyle(Studio.green)
                VStack(alignment: .leading, spacing: 4) { Text("Drop your footage here").font(.system(size: 13, weight: .semibold)); Text("Video files or a downloadable video link").font(.system(size: 11)).foregroundStyle(Studio.muted) }
                Spacer()
                Button("Browse") { model.chooseFiles() }.buttonStyle(SignalButton())
            }.padding(18).background(Studio.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Studio.line, style: StrokeStyle(lineWidth: 1, dash: [5])))
            Spacer(minLength: 20)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Studio.panel, Studio.pine], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Studio.line.opacity(0.7)))
    }
    private func jobCard(_ job: JobCheckpoint) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                ZStack { RoundedRectangle(cornerRadius: 9).fill(Studio.background); Image(systemName: job.state == .completed ? "checkmark" : "film.stack").font(.system(size: 21, weight: .light)).foregroundStyle(job.state == .completed ? Studio.green : Studio.muted) }.frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 8) { Text(job.asset.map { timecode($0.duration) } ?? "Not analyzed yet"); Text("/"); Text(job.configuration.preset.name) }.font(Studio.mono(9)).foregroundStyle(Studio.muted)
                }
                Spacer()
                Text(job.state.rawValue.replacingOccurrences(of: "awaitingReview", with: "REVIEW").uppercased()).font(Studio.mono(8)).tracking(1).foregroundStyle(stateColor(job.state)).padding(.horizontal, 8).padding(.vertical, 5).background(stateColor(job.state).opacity(0.08), in: Capsule())
            }
            if job.state == .running {
                ProgressView(value: job.progress).tint(Studio.green)
            }
            HStack {
                Text(job.message).font(.system(size: 11)).foregroundStyle(job.state == .failed ? Studio.amber : Studio.muted).lineLimit(2)
                Spacer()
                if [.paused, .failed, .cancelled].contains(job.state) {
                    Button("Resume") { model.perform { try await coordinator.resume(job.id) } }.font(.system(size: 11, weight: .semibold)).buttonStyle(.plain).foregroundStyle(Studio.green)
                }
                if job.state == .outcomeUnknown { Button("Resolve") { unknownJob = job.id }.font(.system(size: 11)).foregroundStyle(Studio.amber) }
            }
        }.padding(16).background(model.selectedJobID == job.id ? Studio.raised : Studio.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(model.selectedJobID == job.id ? Studio.green.opacity(0.5) : Studio.line.opacity(0.5)))
            .contentShape(Rectangle()).onTapGesture { model.selectedJobID = job.id }
            .contextMenu {
                Button("Rename…") { renaming = job.id; renameText = job.title }
                if job.state == .failed && [.select, .analyze].contains(job.stage) {
                    Button("Resume with current AI connections…") { currentConnectionsJob = job.id }
                }
                Button("Import transcript…") { model.importTranscript(jobID: job.id) }.disabled(job.state == .running)
                Button("Copy transcript") { model.copyTranscript(job) }.disabled(job.transcript == nil)
                Button("Save transcript…") { model.saveTranscript(job) }.disabled(job.transcript == nil)
                Button("Read transcript") { transcriptJob = job }.disabled(job.transcript == nil)
                if let url = URL(string: job.source), ["http", "https"].contains(url.scheme ?? "") {
                    Button("Open source link") { NSWorkspace.shared.open(url) }
                    Button("Copy source link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                }
                Button("Run again with current preset") { model.add([URL(string: job.source)?.scheme != nil ? URL(string: job.source)! : URL(fileURLWithPath: job.source)]) }
                if let output = job.clips.first?.outputURL { Button("Reveal exports") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
                Divider()
                Button("Remove from library", role: .destructive) { model.perform { try await coordinator.remove(job.id) } }.disabled(job.state == .running)
            }
    }
    private func resultStrip(_ job: JobCheckpoint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Eyebrow(text: "\(job.clips.count) moments"); Spacer(); if job.transcript != nil { Button("Read transcript") { transcriptJob = job }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Studio.muted) } }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(job.clips) { clip in
                        VStack(alignment: .leading, spacing: 8) {
                        Button {
                            model.selectedClipID = clip.id; model.showEditor = true
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(Studio.background)
                                    if clip.outputURL == nil { BrandMark(size: 72) }
                                    else { Image(systemName: "play.circle").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(Studio.green) }
                                }.frame(height: 90)
                                Text(clip.proposal.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(height: 32, alignment: .topLeading)
                                HStack { Text(timecode(clip.proposal.duration)); Spacer(); Text(clip.outputURL == nil ? "PROPOSED" : "EXPORTED") }.font(Studio.mono(8)).foregroundStyle(Studio.muted)
                            }.padding(10).frame(width: 165).background(Studio.panel, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(job.state == .running)
                        if job.state == .awaitingReview {
                            Toggle("Include clip", isOn: Binding(get: { !excludedReview.contains(clip.id) }, set: { if $0 { excludedReview.remove(clip.id) } else { excludedReview.insert(clip.id) } })).font(.system(size: 11)).toggleStyle(.checkbox)
                        }
                        }
                    }
                }
            }
            if job.state == .awaitingReview {
                Button("Render \(job.clips.filter { !excludedReview.contains($0.id) }.count) selected clips") { model.perform { try await coordinator.approve(job.id, clips: Set(job.clips.map(\.id)).subtracting(excludedReview)) } }.buttonStyle(SignalButton(prominent: true)).disabled(job.clips.allSatisfy { excludedReview.contains($0.id) })
            }
        }.frame(maxHeight: 270)
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(coordinator.isRunning ? Studio.green : Studio.muted).frame(width: 5, height: 5)
            Text(coordinator.isRunning ? "PROCESSING" : "STUDIO READY").font(Studio.mono(8)).tracking(1.4)
            Spacer()
            Text("ON-DEVICE VIDEO  /  YOUR AI CONNECTIONS").font(Studio.mono(8)).tracking(1.1)
        }.foregroundStyle(Studio.muted).padding(.horizontal, 28).padding(.vertical, 12).background(Studio.pine)
    }
    private var linkSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Eyebrow(text: "Import a source", color: Studio.green)
            Text("Bring a link.").font(.system(size: 28, weight: .semibold))
            Text("Paste a supported, downloadable video URL. Protected or unavailable videos will show a clear import error.").font(.system(size: 13)).foregroundStyle(Studio.muted)
            TextField("https://…", text: $link).textFieldStyle(.roundedBorder).onSubmit { model.addLink(link) }
            HStack { Button("Cancel") { model.showLink = false }.buttonStyle(SignalButton()); Spacer(); Button("Add to queue") { model.addLink(link) }.buttonStyle(SignalButton(prominent: true)) }
        }.padding(30).frame(width: 510).background(Studio.panel)
    }
    private func stateColor(_ state: JobState) -> Color {
        switch state { case .completed, .running: return Studio.green; case .failed, .outcomeUnknown, .awaitingReview: return Studio.amber; default: return Studio.muted }
    }
}
