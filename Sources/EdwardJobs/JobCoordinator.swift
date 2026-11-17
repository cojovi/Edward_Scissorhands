import Foundation
import Combine
import EdwardDomain
import EdwardPersistence
import EdwardMedia
import EdwardProviders

private struct PauseRequested: Error {}

@MainActor public final class JobCoordinator: ObservableObject {
    @Published public private(set) var jobs: [JobCheckpoint] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var activeJobID: UUID?
    @Published public var notice: String?
    public let store: ProjectStore
    public let media: MediaEngine
    public let providers: ProviderService
    private var runner: Task<Void, Never>?
    private var pauseRequested = false

    public init(store: ProjectStore, media: MediaEngine = MediaEngine(), providers: ProviderService = ProviderService()) {
        self.store = store; self.media = media; self.providers = providers
    }
    public func load() async throws {
        jobs = try await store.loadJobs()
        notice = await store.recoveryNotice
        for index in jobs.indices {
            let unresolved = try hasUnresolvedRequest(jobs[index].id)
            if unresolved && jobs[index].state != .completed {
                jobs[index].pendingRequest = true; jobs[index].state = .outcomeUnknown
                jobs[index].message = "An AI request was interrupted. Check provider usage before retrying."
                try await store.save(jobs[index])
            } else if jobs[index].state == .running {
                jobs[index].pendingRequest = false; jobs[index].state = .paused
                jobs[index].message = "Interrupted session · ready to resume"
                try await store.save(jobs[index])
            }
        }
    }
    public func add(source: String, configuration: JobConfiguration) async throws -> UUID {
        let clean = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw EdwardError.invalidInput("Choose a video or paste a video URL.") }
        if let existing = jobs.first(where: { $0.source == clean && [.queued, .running, .paused].contains($0.state) }) {
            throw EdwardError.invalidInput("This source is already in the queue: \(existing.title)")
        }
        try Self.validate(configuration)
        let job = JobCheckpoint(source: clean, configuration: configuration)
        try await store.save(job); jobs.insert(job, at: 0)
        return job.id
    }
    public static func validate(_ configuration: JobConfiguration) throws {
        let p = configuration.preset
        guard (1...30).contains(p.clipCount), p.minDuration.isFinite, p.maxDuration.isFinite,
              p.minDuration >= 3, p.maxDuration >= p.minDuration, p.maxDuration <= 600 else {
            throw EdwardError.invalidInput("Choose 1–30 clips and a duration between 3 and 600 seconds.")
        }
        guard configuration.budgetUSD.isFinite, configuration.budgetUSD > 0 else {
            throw EdwardError.invalidInput("Set a positive spending ceiling for each source.")
        }
    }
    public func start() {
        guard !isRunning else { return }
        pauseRequested = false; isRunning = true
        runner = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !pauseRequested, let job = jobs.last(where: { $0.state == .queued }) {
                activeJobID = job.id
                await process(job)
            }
            activeJobID = nil; isRunning = false; runner = nil
        }
    }
    public func configureQueued(_ configuration: JobConfiguration) async throws {
        try Self.validate(configuration)
        for i in jobs.indices where jobs[i].state == .queued && !jobs[i].completedStages.contains(.select) {
            let changedEngine = jobs[i].configuration.transcription != configuration.transcription || jobs[i].configuration.transcriptionModel != configuration.transcriptionModel
            jobs[i].configuration = configuration
            if changedEngine && configuration.transcription != .importedTranscript {
                jobs[i].transcript = nil; jobs[i].completedStages.removeAll { $0 == .transcribe }
            }
            try await store.save(jobs[i])
        }
    }
    public func pause() { pauseRequested = true; notice = "The queue will pause after the current stage." }
    public func cancelCurrent() { runner?.cancel() }
    public func resume(_ id: UUID) async throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .outcomeUnknown else { return }
        guard jobs[i].state != .running else { return }
        if try hasUnresolvedRequest(id) {
            jobs[i].state = .outcomeUnknown; jobs[i].pendingRequest = true
            jobs[i].message = "An AI request was interrupted. Check provider usage before retrying."
            try await store.save(jobs[i]); return
        }
        jobs[i].state = .queued; jobs[i].error = nil
        try await store.save(jobs[i]); start()
    }
    /// Explicitly use the user's current AI connections while preserving this project's transcript and preset.
    public func resumeWithCurrentConnections(_ id: UUID, configuration: JobConfiguration) async throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .failed,
              [.select, .analyze].contains(jobs[i].stage) else {
            throw EdwardError.invalidInput("Choose a failed AI analysis to retry with the current connections.")
        }
        if try hasUnresolvedRequest(id) {
            jobs[i].state = .outcomeUnknown; jobs[i].pendingRequest = true
            jobs[i].message = "An AI request was interrupted. Check provider usage before retrying."
            try await store.save(jobs[i]); return
        }
        guard configuration.budgetUSD.isFinite, configuration.budgetUSD > 0 else { throw EdwardError.invalidInput("Set a positive spending ceiling for each source.") }
        jobs[i].configuration.editorial = configuration.editorial
        jobs[i].configuration.visual = configuration.visual
        jobs[i].configuration.budgetUSD = configuration.budgetUSD
        jobs[i].configuration.allowUnknownCost = configuration.allowUnknownCost
        jobs[i].state = .queued; jobs[i].error = nil; jobs[i].pendingRequest = false
        try await store.save(jobs[i]); start()
    }
    public func remove(_ id: UUID) async throws {
        guard jobs.first(where: { $0.id == id })?.state != .running else { throw EdwardError.invalidInput("Pause or cancel this job before removing it.") }
        try await store.deleteJob(id); jobs.removeAll { $0.id == id }
    }
    public func rename(_ id: UUID, title: String) async throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }), !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        jobs[i].title = title; jobs[i].updatedAt = Date(); try await store.save(jobs[i])
    }
    public func importTranscript(_ url: URL, for id: UUID) async throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .running, jobs[i].state != .outcomeUnknown else { throw EdwardError.invalidInput("Pause this source and resolve any uncertain AI request before importing its transcript.") }
        let transcript = try TranscriptEditing.importFile(url)
        if let duration = jobs[i].asset?.duration { try TranscriptEditing.validate(transcript, duration: duration) }
        jobs[i].transcript = transcript; jobs[i].clips = []
        jobs[i].completedStages.removeAll { [.transcribe, .select, .analyze, .render, .verify, .complete].contains($0) }
        jobs[i].configuration.transcription = .importedTranscript
        jobs[i].manuallyApproved = false; jobs[i].visualAssessmentComplete = false
        jobs[i].state = .queued; jobs[i].error = nil; jobs[i].pendingRequest = false
        try await store.save(jobs[i])
    }
    public func approve(_ id: UUID, clips: Set<UUID>) async throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .awaitingReview,
              !clips.isEmpty, clips.isSubset(of: Set(jobs[i].clips.map(\.id))) else {
            throw EdwardError.invalidInput("Select at least one available clip from a source awaiting review.")
        }
        jobs[i].clips.removeAll { !clips.contains($0.id) }
        jobs[i].manuallyApproved = true; jobs[i].state = .queued
        try await store.save(jobs[i]); start()
    }
    public func updateClip(jobID: UUID, clip: ClipProposal, transcript: TimedTranscript, captions: CaptionStyle, framing: FramingMode) async throws {
        guard let i = jobs.firstIndex(where: { $0.id == jobID }), jobs[i].state != .running, jobs[i].state != .outcomeUnknown,
              let c = jobs[i].clips.firstIndex(where: { $0.id == clip.id }) else { return }
        guard clip.duration > 0 else { throw EdwardError.invalidInput("Keep at least one sentence.") }
        if let asset = jobs[i].asset {
            try TranscriptEditing.validate(transcript, duration: asset.duration)
            guard clip.ranges.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= asset.duration + 0.05 }) else {
                throw EdwardError.invalidInput("Keep clip ranges within the source video's duration.")
            }
        }
        jobs[i].clips[c] = ClipResult(proposal: clip)
        // Caption/speaker changes affect the shared transcript/style. Invalidate local outputs, never AI selection.
        for index in jobs[i].clips.indices { jobs[i].clips[index].outputURL = nil; jobs[i].clips[index].plan = nil }
        jobs[i].transcript = transcript; jobs[i].configuration.preset.captions = captions
        jobs[i].configuration.preset.framing = framing
        jobs[i].completedStages.removeAll { [.analyze, .render, .verify, .complete].contains($0) }
        jobs[i].manuallyApproved = true; jobs[i].state = .queued
        jobs[i].message = "Edits saved · ready to render"
        try await store.save(jobs[i])
    }
    /// User explicitly acknowledges provider-side outcome before clearing only unresolved request journals.
    public func resolveUnknown(_ id: UUID) async throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .outcomeUnknown else { return }
        let cache = try store.paths.directory(for: id).appendingPathComponent("ProviderCache")
        if FileManager.default.fileExists(atPath: cache.path) {
            for file in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) where file.pathExtension == "pending" {
                // Keep an audit copy instead of deleting history.
                try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("acknowledged-\(UUID().uuidString)"))
            }
        }
        jobs[i].pendingRequest = false; jobs[i].state = .paused; jobs[i].error = nil
        jobs[i].message = "Request outcome acknowledged · resume when ready"
        try await store.save(jobs[i])
    }
    private func hasUnresolvedRequest(_ id: UUID) throws -> Bool {
        let cache = try store.paths.directory(for: id).appendingPathComponent("ProviderCache")
        guard FileManager.default.fileExists(atPath: cache.path) else { return false }
        return try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).contains {
            $0.pathExtension == "pending" && !FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("json").path)
        }
    }
    private func publish(_ value: JobCheckpoint) async throws {
        var job = value; job.updatedAt = Date()
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job }
        try await store.save(job)
    }
    private func usage(_ usage: UsageRecord, jobID: UUID) async throws {
        guard let i = jobs.firstIndex(where: { $0.id == jobID }) else { throw EdwardError.invalidInput("The project is unavailable; AI usage could not be saved.") }
        if !jobs[i].usage.contains(where: { $0.id == usage.id }) { jobs[i].usage.append(usage) }
        try await store.save(jobs[i])
    }
    private func selectionProgress(jobID: UUID, part: Int, total: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == jobID }), jobs[i].state == .running else { return }
        jobs[i].message = "Finding moments · part \(part) of \(total) · completed parts are saved"
    }
    private func boundary() throws {
        try Task.checkCancellation()
        if pauseRequested { throw PauseRequested() }
    }
    private func begin(_ stage: JobStage, job: inout JobCheckpoint) async throws {
        try boundary(); job.stage = stage; job.state = .running; job.message = stage.title
        job.progress = Double(JobStage.allCases.firstIndex(of: stage) ?? 0) / 8
        try await publish(job)
    }
    private func finish(_ stage: JobStage, job: inout JobCheckpoint) async throws {
        if !job.completedStages.contains(stage) { job.completedStages.append(stage) }
        try await publish(job); try boundary()
    }
    private func process(_ initial: JobCheckpoint) async {
        var job = initial; job.error = nil
        do {
            let directory = try store.paths.directory(for: job.id)
            if !job.completedStages.contains(.ingest) {
                try await begin(.ingest, job: &job)
                job.ingestedURL = try await media.ingest(source: job.source, directory: directory, quality: job.configuration.preset.quality)
                try await finish(.ingest, job: &job)
            }
            guard let input = job.ingestedURL else { throw EdwardError.invalidInput("The source file is missing. Import it again.") }
            guard FileManager.default.fileExists(atPath: input.path) else { throw EdwardError.invalidInput("The source file has moved or is unavailable: \(input.lastPathComponent)") }
            try boundary()
            job.state = .running; job.message = "Verifying source identity"
            try await publish(job)
            // Hash once per run, before either probing or trusting any completed analysis stages.
            let fingerprint = try await SourceIdentity.fingerprint(input)
            if let expected = job.sourceFingerprint {
                guard fingerprint == expected else {
                    throw EdwardError.invalidInput("The source video's contents changed after this project was created. Reimport the changed video as a new project so its transcript and AI analysis match. Existing exports are preserved.")
                }
            } else {
                guard job.asset == nil, !job.completedStages.contains(.probe) else {
                    throw EdwardError.invalidInput("This analyzed project predates source verification. Reimport its video as a new project before reusing its transcript or AI results. Existing exports are preserved.")
                }
                job.sourceFingerprint = fingerprint
                try await publish(job)
            }
            if !job.completedStages.contains(.probe) {
                try await begin(.probe, job: &job)
                job.asset = try await media.probe(url: input)
                job.title = job.asset?.title ?? job.title
                try await finish(.probe, job: &job)
            }
            guard let asset = job.asset else { throw EdwardError.media("Could not read this video's properties.") }
            if !job.completedStages.contains(.transcribe) {
                try await begin(.transcribe, job: &job)
                if job.transcript == nil {
                    guard job.configuration.transcription != .importedTranscript else { throw EdwardError.invalidInput("Import a timed transcript for this source before starting it.") }
                    guard asset.hasAudio else { throw EdwardError.invalidInput("This video has no audio. Import a timed transcript to continue.") }
                    job.audioURL = try await media.extractAudio(asset: asset, directory: directory)
                    try await publish(job)
                    job.message = "Transcribing locally · first use may download the selected model"
                    try await publish(job)
                    job.transcript = try await media.transcribe(audioURL: job.audioURL!, engine: job.configuration.transcription, model: job.configuration.transcriptionModel, recognizeSpeakers: job.configuration.preset.recognizeSpeakers)
                }
                guard var transcript = job.transcript else { throw EdwardError.media("No transcript was produced.") }
                if !job.configuration.preset.recognizeSpeakers {
                    transcript.words = transcript.words.map { var w = $0; w.speaker = nil; return w }
                }
                try TranscriptEditing.validate(transcript, duration: asset.duration)
                job.transcript = transcript
                job.speakerTrack = .init(intervals: transcript.words.compactMap { w in w.speaker.map { .init(speaker: $0, start: w.start, end: w.end) } })
                try JSONEncoder().encode(transcript).write(to: directory.appendingPathComponent("transcript.json"), options: .atomic)
                try await finish(.transcribe, job: &job)
            }
            guard let transcript = job.transcript else { throw EdwardError.media("Transcript is unavailable.") }
            let cache = directory.appendingPathComponent("ProviderCache", isDirectory: true)
            if !job.completedStages.contains(.select) {
                try await begin(.select, job: &job)
                job.pendingRequest = !job.configuration.editorial.isLocal; try await publish(job)
                let id = job.id
                let result = try await providers.analyze(transcript: transcript, duration: asset.duration, preset: job.configuration.preset, configuration: job.configuration.editorial, frames: [], budgetUSD: job.configuration.budgetUSD, allowUnknownCost: job.configuration.allowUnknownCost, previousUsage: job.usage, cacheDirectory: cache,
                    onProgress: { [weak self] part, total in await self?.selectionProgress(jobID: id, part: part, total: total) },
                    onUsage: { [weak self] u in
                        guard let self else { throw EdwardError.invalidInput("The project closed before AI usage could be saved.") }
                        try await self.usage(u, jobID: id)
                    })
                job.usage = jobs.first(where: { $0.id == job.id })?.usage ?? result.usage
                job.pendingRequest = false
                job.clips = result.proposals.map { proposal in
                    let p = job.configuration.preset.removeFillersAndPauses ? TranscriptEditing.removingFillersAndPauses(from: proposal, transcript: transcript) : proposal
                    return ClipResult(proposal: p)
                }.filter { $0.proposal.duration > 0 }
                guard !job.clips.isEmpty else { throw EdwardError.provider("No complete moments matched this preset. Try a shorter duration or a broader topic.") }
                try await finish(.select, job: &job)
            }
            if !job.configuration.preset.automaticExport && !job.manuallyApproved {
                job.state = .awaitingReview; job.message = "Choose the moments to export"; try await publish(job); return
            }
            if !job.completedStages.contains(.analyze) {
                try await begin(.analyze, job: &job)
                if let visual = job.configuration.visual, !job.visualAssessmentComplete {
                    let times = job.clips.flatMap { [$0.proposal.start, ($0.proposal.start + $0.proposal.end) / 2] }
                    let frames = try await media.frames(asset: asset, times: times)
                    job.pendingRequest = !visual.isLocal; try await publish(job)
                    let id = job.id
                    let result = try await providers.assessVisual(proposals: job.clips.map(\.proposal), transcript: transcript, duration: asset.duration, preset: job.configuration.preset, configuration: visual, frames: frames, budgetUSD: job.configuration.budgetUSD, allowUnknownCost: job.configuration.allowUnknownCost, previousUsage: job.usage, cacheDirectory: cache, onUsage: { [weak self] u in
                        guard let self else { throw EdwardError.invalidInput("The project closed before AI usage could be saved.") }
                        try await self.usage(u, jobID: id)
                    })
                    job.usage = jobs.first(where: { $0.id == job.id })?.usage ?? job.usage
                    job.pendingRequest = false
                    job.clips = result.proposals.map { ClipResult(proposal: $0) }
                    guard !job.clips.isEmpty else { throw EdwardError.provider("Visual review rejected all proposed clips. Disable visual review or adjust the selection preset.") }
                    job.visualAssessmentComplete = true
                }
                let output = job.configuration.outputDirectory.appendingPathComponent("\(safeName(job.title))-\(job.id.uuidString.prefix(8))", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                for i in job.clips.indices {
                    try boundary()
                    let proposal = job.clips[i].proposal
                    let keys = job.configuration.preset.framing == .speaker ? try await media.track(asset: asset, clip: proposal, transcript: transcript) : []
                    let revision = UUID().uuidString.prefix(8)
                    var plan = RenderPlan(sourceURL: asset.url, outputURL: output.appendingPathComponent(String(format: "%02d-", i + 1) + safeName(proposal.title) + "-\(revision).mp4"), clip: proposal, transcript: transcript, canvas: job.configuration.preset.canvas, framing: job.configuration.preset.framing, cropKeyframes: keys, captions: job.configuration.preset.captions)
                    plan.quality = job.configuration.preset.quality
                    job.clips[i].plan = plan
                }
                try await finish(.analyze, job: &job)
            }
            if !job.completedStages.contains(.render) {
                try await begin(.render, job: &job)
                for i in job.clips.indices {
                    try boundary()
                    if let output = job.clips[i].outputURL, FileManager.default.fileExists(atPath: output.path) { continue }
                    guard var plan = job.clips[i].plan else { throw EdwardError.media("The render plan is missing.") }
                    // A crash may occur after atomic file publication and before the SQLite checkpoint.
                    if FileManager.default.fileExists(atPath: plan.outputURL.path) {
                        do {
                            try await media.verify(url: plan.outputURL, expectedDuration: plan.clip.duration)
                            job.clips[i].outputURL = plan.outputURL; job.clips[i].error = nil
                            try await publish(job); continue
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            plan.outputURL = plan.outputURL.deletingPathExtension().appendingPathExtension("retry-\(UUID().uuidString.prefix(8)).mp4")
                            job.clips[i].plan = plan
                        }
                    }
                    let id = job.id; let clipNumber = i + 1; let count = job.clips.count
                    job.message = "Rendering clip \(clipNumber) of \(count)"; try await publish(job)
                    do {
                        let output = try await media.render(plan: plan, progress: { [weak self] fraction in
                            Task { @MainActor in
                                guard let self, let index = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                                self.jobs[index].progress = 0.625 + (Double(clipNumber - 1) + fraction) / Double(count) * 0.25
                            }
                        })
                        job.clips[i].outputURL = output; job.clips[i].error = nil
                    } catch is CancellationError { throw CancellationError() }
                    catch { job.clips[i].error = error.localizedDescription }
                    try await publish(job)
                }
                if job.clips.contains(where: { $0.outputURL == nil }) { throw EdwardError.media("Some clips could not render. Completed clips are saved; resume to retry the failed clips.") }
                try await finish(.render, job: &job)
            }
            if !job.completedStages.contains(.verify) {
                try await begin(.verify, job: &job)
                for i in job.clips.indices {
                    guard let output = job.clips[i].outputURL else {
                        job.completedStages.removeAll { [.render, .verify, .complete].contains($0) }
                        throw EdwardError.media("An export is missing. Resume to render it again.")
                    }
                    do { try await media.verify(url: output, expectedDuration: job.clips[i].proposal.duration) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        job.clips[i].outputURL = nil; job.clips[i].error = error.localizedDescription
                        job.completedStages.removeAll { [.render, .verify, .complete].contains($0) }
                        throw EdwardError.media("An export failed verification. Resume to render it again; completed clips remain saved.")
                    }
                }
                try await finish(.verify, job: &job)
            }
            job.state = .completed; job.stage = .complete; job.progress = 1; job.message = "\(job.clips.count) clips ready"
            if !job.completedStages.contains(.complete) { job.completedStages.append(.complete) }
            try await publish(job)
        } catch {
            job.usage = jobs.first(where: { $0.id == job.id })?.usage ?? job.usage
            if error is PauseRequested { job.state = .paused; job.message = "Paused · completed stages are saved" }
            else if error is CancellationError {
                job.state = job.pendingRequest ? .outcomeUnknown : .cancelled
                job.message = job.pendingRequest ? "Check provider usage before retrying this interrupted request" : "Cancelled · completed stages are saved"
            } else {
                if case EdwardError.outcomeUnknown = error { job.state = .outcomeUnknown }
                else { job.state = .failed; job.pendingRequest = false }
                job.error = error.localizedDescription; job.message = error.localizedDescription
            }
            do { try await publish(job) } catch { notice = "Could not save job state: \(error.localizedDescription)" }
        }
    }
    private func safeName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let value = String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.prefix(70)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "clip" : value
    }
}
