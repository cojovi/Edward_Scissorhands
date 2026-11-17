import XCTest
import Foundation
import EdwardDomain
import EdwardPersistence
import EdwardProviders
@testable import EdwardMedia
@testable import EdwardJobs

@MainActor final class JobIntegrationTests: XCTestCase {
    func testRealQueueExportsRestartsAndRerendersEditsWithoutRebilling() async throws {
        let context = try await makeContext(visual: true)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let coordinator = context.coordinator
        let id = try await addFixture(context)
        coordinator.start(); try await idle(coordinator)
        var job = try XCTUnwrap(coordinator.jobs.first { $0.id == id })
        XCTAssertEqual(job.state, .completed, job.error ?? "")
        XCTAssertEqual(job.clips.count, 2); XCTAssertEqual(job.usage.count, 2)
        XCTAssertEqual(context.network.count, 2)
        let originalFiles = job.clips.compactMap(\.outputURL)
        for output in originalFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.deletingPathExtension().appendingPathExtension("srt").path))
            let media = try await coordinator.media.probe(url: output)
            XCTAssertEqual(media.width, 1080); XCTAssertEqual(media.height, 1080); XCTAssertTrue(media.hasAudio)
        }

        // Reconstruct a crash after successful paid responses, before their job-stage checkpoint.
        job.state = .running; job.stage = .select; job.pendingRequest = true
        job.completedStages.removeAll { [.select, .analyze, .render, .verify, .complete].contains($0) }
        job.clips = []; job.visualAssessmentComplete = false
        try await context.store.save(job)
        let reopened = JobCoordinator(store: context.store, providers: context.providers)
        try await reopened.load()
        XCTAssertEqual(reopened.jobs.first?.state, .paused, "Complete provider journals should resume without an unknown-outcome warning")
        try await reopened.resume(id); try await idle(reopened)
        job = try XCTUnwrap(reopened.jobs.first)
        XCTAssertEqual(job.state, .completed, job.error ?? "")
        XCTAssertEqual(context.network.count, 2, "Cached editorial and visual calls must not be billed again")
        XCTAssertEqual(job.usage.count, 2, "Usage replay must retain stable IDs")

        let priorOutput = try XCTUnwrap(job.clips[0].outputURL)
        var transcript = try XCTUnwrap(job.transcript); transcript.words[0].text = "Revised"
        var proposal = job.clips[0].proposal; proposal.ranges[0].start = 0.5
        try await reopened.updateClip(jobID: id, clip: proposal, transcript: transcript, captions: job.configuration.preset.captions, framing: .preserve)
        try await reopened.resume(id); try await idle(reopened)
        job = try XCTUnwrap(reopened.jobs.first)
        XCTAssertEqual(job.state, .completed, job.error ?? "")
        XCTAssertEqual(context.network.count, 2, "Editing captions and cuts must remain local")
        XCTAssertNotEqual(job.clips[0].outputURL, priorOutput)
        XCTAssertTrue(FileManager.default.fileExists(atPath: priorOutput.path), "Previous exports remain intact")
        XCTAssertEqual(job.clips[0].proposal.start, 0.5)
        let persisted = try await context.store.loadJobs()
        XCTAssertEqual(persisted.first?.usage.count, 2)
    }

    func testManualReviewRequiresValidSelectionAndExportsOnlyApprovedClip() async throws {
        let context = try await makeContext(automatic: false)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = try await addFixture(context)
        context.coordinator.start(); try await idle(context.coordinator)
        var job = try XCTUnwrap(context.coordinator.jobs.first)
        XCTAssertEqual(job.state, .awaitingReview)
        XCTAssertTrue(job.clips.allSatisfy { $0.outputURL == nil })
        do { try await context.coordinator.approve(id, clips: [UUID()]); XCTFail("Unknown clip ID accepted") } catch { }
        XCTAssertEqual(context.coordinator.jobs.first?.state, .awaitingReview)
        let selected = try XCTUnwrap(job.clips.first?.id)
        try await context.coordinator.approve(id, clips: [selected]); try await idle(context.coordinator)
        job = try XCTUnwrap(context.coordinator.jobs.first)
        XCTAssertEqual(job.state, .completed, job.error ?? "")
        XCTAssertEqual(job.clips.map(\.id), [selected])
        XCTAssertEqual(context.network.count, 1)
        try await context.coordinator.importTranscript(context.transcriptURL, for: id)
        XCTAssertFalse(context.coordinator.jobs.first!.manuallyApproved)
        XCTAssertFalse(context.coordinator.jobs.first!.visualAssessmentComplete)
        context.coordinator.start(); try await idle(context.coordinator)
        XCTAssertEqual(context.coordinator.jobs.first?.state, .awaitingReview)
        XCTAssertEqual(context.network.count, 1, "The identical transcript may reuse its prior analysis")
    }

    func testRetryWithCurrentConnectionKeepsSavedTranscriptAndOriginalPreset() async throws {
        let context = try await makeContext(automatic: false)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = try await addFixture(context)
        context.coordinator.start(); try await idle(context.coordinator)
        var failed = try XCTUnwrap(context.coordinator.jobs.first)
        XCTAssertEqual(failed.state, .awaitingReview)
        failed.state = .failed; failed.stage = .select; failed.clips = []
        failed.completedStages.removeAll { [.select, .analyze, .render, .verify, .complete].contains($0) }
        try await context.store.save(failed)
        let reopened = JobCoordinator(store: context.store, providers: context.providers)
        try await reopened.load()
        var newSettings = context.configuration
        newSettings.editorial.model = "replacement-model"
        newSettings.preset.clipCount = 1
        try await reopened.resumeWithCurrentConnections(id, configuration: newSettings)
        try await idle(reopened)
        let resumed = try XCTUnwrap(reopened.jobs.first)
        XCTAssertEqual(resumed.state, .awaitingReview, resumed.error ?? "")
        XCTAssertEqual(resumed.configuration.editorial.model, "replacement-model")
        XCTAssertEqual(resumed.configuration.preset.clipCount, 2, "Changing connections must not replace the source's preset")
        XCTAssertEqual(resumed.transcript?.words.count, failed.transcript?.words.count)
        XCTAssertTrue(resumed.completedStages.contains(.transcribe))
        XCTAssertEqual(context.network.count, 2)
    }

    func testUnresolvedRequestIsDetectedEvenOnFailedRecoveredCheckpoint() async throws {
        let context = try await makeContext(automatic: false)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = try await addFixture(context)
        var job = try XCTUnwrap(context.coordinator.jobs.first)
        job.state = .failed; job.stage = .select; job.pendingRequest = false
        try await context.store.save(job)
        let cache = try context.store.paths.directory(for: id).appendingPathComponent("ProviderCache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("uncertain".utf8).write(to: cache.appendingPathComponent("prior.pending"))
        let reopened = JobCoordinator(store: context.store, providers: context.providers)
        try await reopened.load()
        XCTAssertEqual(reopened.jobs.first?.state, .outcomeUnknown)
        try await reopened.resume(id)
        XCTAssertFalse(reopened.isRunning)
        XCTAssertEqual(context.network.count, 0)
    }

    func testFailedSourceDoesNotBlockNextSourceAndMissingTranscriptIsClear() async throws {
        let context = try await makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let bad = try await context.coordinator.add(source: context.root.appendingPathComponent("missing.mp4").path, configuration: context.configuration)
        let good = try await addFixture(context)
        context.coordinator.start(); try await idle(context.coordinator)
        XCTAssertEqual(context.coordinator.jobs.first { $0.id == bad }?.state, .failed)
        XCTAssertEqual(context.coordinator.jobs.first { $0.id == good }?.state, .completed)
        XCTAssertEqual(context.network.count, 1)
        let noTranscript = try await context.coordinator.add(source: context.video.path, configuration: context.configuration)
        context.coordinator.start(); try await idle(context.coordinator)
        let failed = try XCTUnwrap(context.coordinator.jobs.first { $0.id == noTranscript })
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(failed.error?.contains("Import a timed transcript") == true)
        XCTAssertNil(failed.audioURL, "Missing imported transcript must fail before extracting audio")
        XCTAssertEqual(context.network.count, 1)
    }

    func testPauseCompletesCurrentPaidStageAndResumeDoesNotRebill() async throws {
        let context = try await makeContext(delay: 0.3)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = try await addFixture(context)
        context.coordinator.start()
        try await eventually { context.network.count == 1 }
        context.coordinator.pause(); try await idle(context.coordinator)
        let paused = try XCTUnwrap(context.coordinator.jobs.first)
        XCTAssertEqual(paused.state, .paused, paused.error ?? "")
        XCTAssertTrue(paused.completedStages.contains(.select))
        XCTAssertEqual(paused.usage.count, 1)
        try await context.coordinator.resume(id); try await idle(context.coordinator)
        XCTAssertEqual(context.coordinator.jobs.first?.state, .completed)
        XCTAssertEqual(context.network.count, 1)
    }

    func testCancellationDuringPaidRequestPreservesUnknownOutcomeAcrossRestart() async throws {
        let context = try await makeContext(delay: 1)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = try await addFixture(context)
        context.coordinator.start()
        try await eventually { context.network.count == 1 }
        context.coordinator.cancelCurrent(); try await idle(context.coordinator)
        XCTAssertEqual(context.coordinator.jobs.first?.state, .outcomeUnknown)
        XCTAssertTrue(context.coordinator.jobs.first!.clips.isEmpty)
        let restarted = JobCoordinator(store: context.store, providers: context.providers)
        try await restarted.load()
        try await restarted.resume(id)
        XCTAssertFalse(restarted.isRunning)
        XCTAssertEqual(context.network.count, 1)
        try await restarted.resolveUnknown(id)
        XCTAssertEqual(restarted.jobs.first?.state, .paused)
        XCTAssertEqual(context.network.count, 1, "Acknowledgement must not itself dispatch a request")
    }

    func testPublishedVideoBeforeCheckpointIsRecoveredWithoutOverwriteOrInference() async throws {
        let context = try await makeContext(automatic: false)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = try await addFixture(context)
        context.coordinator.start(); try await idle(context.coordinator)
        let first = try XCTUnwrap(context.coordinator.jobs.first?.clips.first?.id)
        try await context.coordinator.approve(id, clips: [first]); try await idle(context.coordinator)
        var job = try XCTUnwrap(context.coordinator.jobs.first)
        let output = try XCTUnwrap(job.clips.first?.outputURL)
        let originalData = try Data(contentsOf: output)
        job.state = .running; job.stage = .render; job.pendingRequest = false
        job.clips[0].outputURL = nil
        job.completedStages.removeAll { [.render, .verify, .complete].contains($0) }
        try await context.store.save(job)
        let reopened = JobCoordinator(store: context.store, providers: context.providers)
        try await reopened.load(); try await reopened.resume(id); try await idle(reopened)
        XCTAssertEqual(reopened.jobs.first?.state, .completed)
        XCTAssertEqual(reopened.jobs.first?.clips.first?.outputURL, output)
        XCTAssertEqual(try Data(contentsOf: output), originalData)
        XCTAssertEqual(context.network.count, 1)
    }

    func testChangedSourceBytesAreRejectedEvenWhenSizeAndModificationDateMatch() async throws {
        let context = try await makeContext(automatic: false)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = try await addFixture(context)
        context.coordinator.start(); try await idle(context.coordinator)
        let analyzed = try XCTUnwrap(context.coordinator.jobs.first)
        XCTAssertEqual(analyzed.state, .awaitingReview)
        XCTAssertEqual(analyzed.sourceFingerprint?.count, 64)
        XCTAssertEqual(context.network.count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: context.video.path)
        let original = try Data(contentsOf: context.video)
        var changed = original; changed[changed.count - 1] ^= 1
        try changed.write(to: context.video)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: context.video.path)
        // Reset selection through the supported transcript-import path so a resume would otherwise use the paid cache.
        try await context.coordinator.importTranscript(context.transcriptURL, for: id)
        context.coordinator.start(); try await idle(context.coordinator)
        let failed = try XCTUnwrap(context.coordinator.jobs.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(failed.error?.contains("contents changed") == true, failed.error ?? "")
        XCTAssertEqual(failed.sourceFingerprint, analyzed.sourceFingerprint)
        XCTAssertEqual(context.network.count, 1)
        XCTAssertTrue(failed.clips.isEmpty)
        XCTAssertEqual(failed.usage.count, 1)
    }

    func testLegacyAnalyzedCheckpointCannotSilentlyAdoptCurrentFileIdentity() async throws {
        let context = try await makeContext(automatic: false)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = try await addFixture(context)
        context.coordinator.start(); try await idle(context.coordinator)
        var old = try XCTUnwrap(context.coordinator.jobs.first)
        old.sourceFingerprint = nil; old.state = .paused
        try await context.store.save(old)
        let restarted = JobCoordinator(store: context.store, providers: context.providers)
        try await restarted.load(); try await restarted.resume(id); try await idle(restarted)
        XCTAssertEqual(restarted.jobs.first?.state, .failed)
        XCTAssertTrue(restarted.jobs.first?.error?.contains("predates source verification") == true)
        XCTAssertEqual(context.network.count, 1)
    }

    private struct Context {
        let root: URL; let video: URL; let transcriptURL: URL
        let configuration: JobConfiguration; let store: ProjectStore; let providers: ProviderService
        let coordinator: JobCoordinator; let network: JobMockState
    }
    private func makeContext(automatic: Bool = true, visual: Bool = false, delay: Double = 0) async throws -> Context {
        guard let ffmpeg = MediaTools.executable("ffmpeg") else { throw XCTSkip("FFmpeg is required only to generate the synthetic integration fixture") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EdwardJobs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("fixture.mp4")
        _ = try await OwnedProcess().run(executable: ffmpeg, arguments: ["-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=640x360:r=30:d=8", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=8", "-c:v", "h264_videotoolbox", "-c:a", "aac", "-t", "8", video.path], directory: root)
        let transcript = TimedTranscript(words: (0..<16).map {
            TimedWord(text: $0 % 4 == 3 ? "idea." : "Complete", start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.45)
        }, engine: "Synthetic fixture")
        let transcriptURL = root.appendingPathComponent("transcript.json")
        try JSONEncoder().encode(transcript).write(to: transcriptURL)
        let host = UUID().uuidString.lowercased() + ".invalid"
        let network = JobMockState(delay: delay)
        JobMockProtocol.register(host: host, state: network)
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [JobMockProtocol.self]
        let providers = ProviderService(session: URLSession(configuration: sessionConfig), credential: { _ in "fixture-not-a-real-key" })
        let provider = ProviderConfiguration(id: host, name: "Fixture", kind: .openAI, baseURL: "https://\(host)/v1", model: "fixture-model",
            capabilities: .init(text: true, images: true, structuredOutput: true), inputCostPerMillion: 1, outputCostPerMillion: 1)
        var configuration = JobConfiguration(outputDirectory: root.appendingPathComponent("Exports"))
        configuration.editorial = provider; configuration.visual = visual ? provider : nil
        configuration.transcription = .importedTranscript; configuration.budgetUSD = 5
        configuration.preset.clipCount = 2; configuration.preset.minDuration = 3; configuration.preset.maxDuration = 6
        configuration.preset.automaticExport = automatic; configuration.preset.framing = .preserve
        configuration.preset.canvas = .square; configuration.preset.quality = .standard
        let store = try ProjectStore(paths: WorkspacePaths(root: root.appendingPathComponent("Library")))
        return .init(root: root, video: video, transcriptURL: transcriptURL, configuration: configuration, store: store, providers: providers,
                     coordinator: JobCoordinator(store: store, providers: providers), network: network)
    }
    private func addFixture(_ context: Context) async throws -> UUID {
        let id = try await context.coordinator.add(source: context.video.path, configuration: context.configuration)
        try await context.coordinator.importTranscript(context.transcriptURL, for: id)
        return id
    }
    private func idle(_ coordinator: JobCoordinator) async throws { try await eventually { !coordinator.isRunning } }
    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out waiting for queue state"); throw EdwardError.invalidInput("Test timeout") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class JobMockState: @unchecked Sendable {
    private let lock = NSLock(); private var calls = 0
    let delay: Double
    init(delay: Double) { self.delay = delay }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func response(for body: Data) throws -> Data {
        lock.lock(); calls += 1; lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let visual = String(decoding: body, as: UTF8.self).contains("\"assessments\"")
        let content: String
        if visual {
            content = "{\"assessments\":[{\"candidate_id\":0,\"keep\":true,\"score\":85,\"reason\":\"Relevant visual content.\"},{\"candidate_id\":1,\"keep\":true,\"score\":80,\"reason\":\"Relevant visual content.\"}]}"
        } else {
            content = "{\"clips\":[{\"title\":\"First idea\",\"reason\":\"Complete thought.\",\"score\":90,\"start_segment\":0,\"end_segment\":1},{\"title\":\"Second idea\",\"reason\":\"Another complete thought.\",\"score\":80,\"start_segment\":2,\"end_segment\":3}]}"
        }
        return try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": content]]]], "usage": ["input_tokens": 100, "output_tokens": 50]])
    }
}
private final class JobMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock(); private static var states: [String: JobMockState] = [:]
    private let stateLock = NSLock(); private var stopped = false
    static func register(host: String, state: JobMockState) { lock.lock(); defer { lock.unlock() }; states[host] = state }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let state = Self.states[request.url?.host ?? ""]; Self.lock.unlock()
        guard let state else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
        }
        let capturedBody = body
        DispatchQueue.global().async { [self] in
            do {
                let data = try state.response(for: capturedBody)
                stateLock.lock(); let cancelled = stopped; stateLock.unlock()
                guard !cancelled else { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}
