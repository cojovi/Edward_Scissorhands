import XCTest
import Foundation
import EdwardDomain
@testable import EdwardMedia

/// Explicitly opt-in research against the user-selected installed app, never packaged as fixtures.
final class MediaResearchTests: XCTestCase {
    func testAuthorizedTwoPersonResearchFootage() async throws {
        guard ProcessInfo.processInfo.environment["EDWARD_TEST_CLOTH"] == "1" else { throw XCTSkip("Read-only Cloth research inputs require EDWARD_TEST_CLOTH=1") }
        let resources = URL(fileURLWithPath: "/Applications/Setapp/Cloth.app/Contents/Resources")
        let source = resources.appendingPathComponent("onboarding-source.mp4")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Selected Cloth research artifact is not installed") }
        struct SuppliedWord: Decodable { var t: String; var s: Double; var e: Double; var p: String? }
        struct SuppliedTranscript: Decodable { var duration: Double; var words: [SuppliedWord] }
        let supplied = try JSONDecoder().decode(SuppliedTranscript.self, from: Data(contentsOf: resources.appendingPathComponent("onboarding-source.json")))
        let transcript = TimedTranscript(words: supplied.words.map { .init(text: $0.t, start: $0.s, end: $0.e, speaker: $0.p) }, engine: "Cloth supplied research transcript; not new ASR")
        let engine = MediaEngine(), asset = try await MediaEngine().probe(url: source)
        XCTAssertFalse(asset.hasAudio, "This fixture cannot establish real two-person diarization quality")
        let clip = ClipProposal(title: "Two-person research", reason: "Local framing validation", start: 0, end: min(asset.duration, supplied.duration))
        let keyframes = try await engine.track(asset: asset, clip: clip, transcript: transcript)
        XCTAssertFalse(keyframes.isEmpty)
        XCTAssertTrue(keyframes.allSatisfy { $0.centerX.isFinite && $0.centerX >= 0 && $0.centerX <= 1 })
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-artifacts/media-research")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(keyframes).write(to: directory.appendingPathComponent("two-person-framing.json"), options: .atomic)
        let destination = directory.appendingPathComponent("two-person-framing.mp4")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let sidecar = destination.deletingPathExtension().appendingPathExtension("srt")
        if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        var captions = CaptionStyle(); captions.enabled = false
        let plan = RenderPlan(sourceURL: source, outputURL: destination, clip: clip, transcript: transcript, framing: .speaker, cropKeyframes: keyframes, captions: captions)
        _ = try await engine.render(plan: plan, progress: { _ in })
        print("Research framing: \(keyframes.count) samples, \(keyframes.filter(\.preserve).count) preserve-frame fallbacks; not a speaker identity accuracy score.")
    }

    func testAuthorizedSingleSpeakerAudioDemo() async throws {
        guard ProcessInfo.processInfo.environment["EDWARD_TEST_CLOTH"] == "1" else { throw XCTSkip("Read-only Cloth research inputs require EDWARD_TEST_CLOTH=1") }
        let source = URL(fileURLWithPath: "/Applications/Setapp/Cloth.app/Contents/Resources/01 Three principles for a positive AI future.mp4")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Selected Cloth research artifact is not installed") }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-artifacts/media-research/audio-demo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = MediaEngine(), asset = try await MediaEngine().probe(url: source)
        let audio = try await engine.extractAudio(asset: asset, directory: directory)
        defer { try? FileManager.default.removeItem(at: audio) }
        let transcript = try await engine.transcribe(audioURL: audio, engine: .fluidAudio, model: "v3")
        XCTAssertGreaterThan(transcript.words.count, 40)
        XCTAssertTrue(transcript.words.contains { $0.speaker != nil })
        XCTAssertLessThan(transcript.words.last?.end ?? .infinity, asset.duration + 0.5)
        try JSONEncoder().encode(transcript).write(to: directory.appendingPathComponent("transcript.json"), options: .atomic)
        print("Real audio demo: \(transcript.words.count) words, \(Set(transcript.words.compactMap(\.speaker)).count) speaker labels.")
    }
}
