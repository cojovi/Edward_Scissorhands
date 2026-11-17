import XCTest
import Foundation
import EdwardDomain
@testable import EdwardMedia

final class MediaTranscriptionTests: XCTestCase {
    func testDiarizationFailureRetainsSuccessfulTranscript() async throws {
        let original = TimedTranscript(words: [.init(text: "Retain this", start: 0, end: 1)], engine: "ASR")
        let result = try await LocalTranscriber.attachSpeakers(to: original) { throw EdwardError.media("Model unavailable") }
        XCTAssertEqual(result.words, original.words)
        XCTAssertTrue(result.engine.contains("speaker recognition unavailable"))
    }
    func testDiarizationCancellationIsNotSilentlySwallowed() async {
        do {
            _ = try await LocalTranscriber.attachSpeakers(to: .init(words: [], engine: "ASR")) { throw CancellationError() }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testWhisperWorkerWithSyntheticSpeech() async throws {
        guard ProcessInfo.processInfo.environment["EDWARD_TEST_WHISPER"] == "1" else { throw XCTSkip("Set EDWARD_TEST_WHISPER=1 to run WhisperKit inference.") }
        try await runSpeech(engine: .whisperKit, model: "openai_whisper-base.en")
    }
    func testLocalSpeechWorkerWithSyntheticSpeech() async throws {
        guard ProcessInfo.processInfo.environment["EDWARD_TEST_MODELS"] == "1" else {
            throw XCTSkip("Set EDWARD_TEST_MODELS=1 to download upstream model weights and run local inference.")
        }
        try await runSpeech(engine: .fluidAudio, model: "v3")
    }
    private func runSpeech(engine: TranscriptionEngine, model: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edward-speech-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("speech.aiff")
        let script = "Welcome to Edward Scissorhands. We are testing accurate video captions. The quick brown fox jumps over the lazy dog. This program turns long interviews into useful short clips. Every word should have a timestamp. Local transcription keeps this recording on your computer."
        _ = try await OwnedProcess().run(executable: URL(fileURLWithPath: "/usr/bin/say"), arguments: ["-o", audio.path, "-r", "165", script], directory: directory)
        let transcript = try await MediaEngine().transcribe(audioURL: audio, engine: engine, model: model)
        XCTAssertGreaterThan(transcript.words.count, 30)
        XCTAssertTrue(transcript.text.lowercased().contains("captions"))
        XCTAssertTrue(transcript.words.allSatisfy { $0.start >= 0 && $0.end > $0.start })
        XCTAssertTrue(transcript.words.contains { $0.speaker != nil })
    }
}
