import XCTest
import EdwardDomain
import EdwardProviders

/// Opt-in only: talks to an already-running local Ollama server; never downloads or uses cloud models.
final class ProviderLiveTests: XCTestCase {
    func testDownloadedLocalModelWithExplicitSavedTranscript() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EDWARD_RUN_LOCAL_PROVIDER_TEST"] == "1", let path = env["EDWARD_LOCAL_TRANSCRIPT_PATH"] else {
            throw XCTSkip("Set EDWARD_RUN_LOCAL_PROVIDER_TEST=1 and EDWARD_LOCAL_TRANSCRIPT_PATH for the saved-transcript local reproduction")
        }
        let transcript = try JSONDecoder().decode(TimedTranscript.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let model = env["EDWARD_LOCAL_MODEL"] ?? "qwen3.5:2b"
        let provider = ProviderConfiguration(id: "local-saved-transcript", name: "Local Ollama", kind: .ollama,
            baseURL: "http://127.0.0.1:11434", model: model, capabilities: .init(text: true, structuredOutput: true))
        var preset = BatchPreset(); preset.name = "Podcast highlights"; preset.clipCount = 5
        preset.minDuration = 10; preset.maxDuration = 22; preset.topic = ""
        let duration = Double(env["EDWARD_LOCAL_SOURCE_DURATION"] ?? "") ?? transcript.words.last!.end
        let result = try await ProviderService(credential: { _ in nil }).analyze(transcript: transcript,
            duration: duration, preset: preset, configuration: provider, budgetUSD: 0, allowUnknownCost: false, onUsage: { _ in })
        XCTAssertFalse(result.proposals.isEmpty)
        for clip in result.proposals {
            XCTAssertGreaterThanOrEqual(clip.duration, 9.95)
            XCTAssertLessThanOrEqual(clip.duration, 22.05)
            XCTAssertTrue(transcript.words.contains { $0.start == clip.start })
            XCTAssertTrue(transcript.words.contains { $0.end == clip.end })
        }
        let ranges = result.proposals.map { String(format: "%.2f–%.2fs", $0.start, $0.end) }.joined(separator: ", ")
        print("Saved-transcript local smoke: \(model), \(result.proposals.count) valid clips, ranges \(ranges), $0 estimated API cost.")
    }

    func testDownloadedLocalOllamaModelSelectsTimedClips() async throws {
        guard ProcessInfo.processInfo.environment["EDWARD_RUN_LOCAL_PROVIDER_TEST"] == "1" else {
            throw XCTSkip("Set EDWARD_RUN_LOCAL_PROVIDER_TEST=1 to exercise a downloaded local model")
        }
        let model = ProcessInfo.processInfo.environment["EDWARD_LOCAL_MODEL"] ?? "qwen3.5:2b"
        let provider = ProviderConfiguration(id: "local-smoke", name: "Local Ollama", kind: .ollama,
            baseURL: "http://127.0.0.1:11434", model: model, capabilities: .init(text: true, structuredOutput: true))
        let speech = "A simple way to make tutorial clips clearer is to show the result before explaining the steps. Start with the finished effect so viewers understand what they will learn. Then demonstrate one action at a time and keep the controls visible on screen. End by showing the same result again so the lesson feels complete. You can also improve captions by keeping each line short and placing it away from important buttons. Review the exported video once to check that the words remain readable on a small phone screen."
        let words = speech.split(separator: " ").enumerated().map {
            TimedWord(text: String($0.element), start: Double($0.offset) * 0.45, end: Double($0.offset) * 0.45 + 0.42)
        }
        let transcript = TimedTranscript(words: words, language: "en", engine: "Synthetic local inference fixture")
        var preset = BatchPreset(); preset.clipCount = 1; preset.minDuration = 5; preset.maxDuration = 25
        preset.topic = "Choose one useful, self-contained tutorial editing tip."
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("edward-local-provider-smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let result: AnalysisResult
        do {
            result = try await ProviderService(credential: { _ in nil }).analyze(transcript: transcript,
                duration: words.last!.end, preset: preset, configuration: provider, budgetUSD: 0, allowUnknownCost: false,
                cacheDirectory: cache, onUsage: { _ in })
        } catch {
            // Synthetic fixture output only; never print a key or a provider's thinking content.
            for file in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
                if let envelope = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                   let encoded = envelope["response"] as? String, let data = Data(base64Encoded: encoded),
                   let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = response["message"] as? [String: Any], let content = message["content"] as? String {
                    print("Synthetic local smoke structured output: " + content)
                }
            }
            throw error
        }
        XCTAssertEqual(result.proposals.count, 1)
        let clip = try XCTUnwrap(result.proposals.first)
        XCTAssertGreaterThanOrEqual(clip.duration, 5)
        XCTAssertLessThanOrEqual(clip.duration, 25)
        XCTAssertTrue(words.contains { $0.start == clip.start })
        XCTAssertTrue(words.contains { $0.end == clip.end })
        XCTAssertEqual(result.usage.first?.estimatedCost, 0)
        print("Local provider smoke: \(model), \(result.proposals.count) clip, \(clip.start)–\(clip.end)s, \(result.usage.first?.inputTokens ?? 0) input / \(result.usage.first?.outputTokens ?? 0) output tokens, $0 estimated API cost.")
    }
}
