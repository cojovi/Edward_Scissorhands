import XCTest
import Foundation
import CryptoKit
import EdwardDomain
@testable import EdwardProviders

final class ProviderTests: XCTestCase {
    private func transcript() -> TimedTranscript {
        .init(words: (0..<18).map { .init(text: $0 % 2 == 1 ? "point." : "Useful", start: Double($0) * 5, end: Double($0) * 5 + 4) }, engine: "fixture")
    }
    private func preset() -> BatchPreset {
        var p = BatchPreset(); p.minDuration = 5; p.maxDuration = 30; p.clipCount = 3; return p
    }
    private let valid = "{\"clips\":[{\"title\":\"A complete idea\",\"reason\":\"A hook and useful payoff.\",\"score\":88,\"start_segment\":0,\"end_segment\":1}]}"

    private func setup(_ kind: ProviderKind = .openAI, response: @escaping (URLRequest) throws -> (Int, Data)) -> (ProviderService, ProviderConfiguration, ProviderMockState) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = ProviderMockState { request in
            if kind == .ollama, request.url?.path.hasSuffix("/api/tags") == true {
                return (200, Data("{\"models\":[{\"name\":\"fixture-model\"}]}".utf8))
            }
            if kind == .ollama, request.url?.path.hasSuffix("/api/show") == true {
                return (200, Data("{\"details\":{\"format\":\"gguf\"},\"capabilities\":[\"completion\",\"vision\"],\"thinking\":{\"values\":[false,true],\"default\":true}}".utf8))
            }
            return try response(request)
        }
        ProviderMockProtocol.register(host: host, state: state)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProviderMockProtocol.self]
        let session = URLSession(configuration: config)
        let service = ProviderService(session: session, credential: { _ in "test-key-not-real" })
        let base = kind == .ollama ? "http://localhost:11434" : "https://\(host)/v1"
        if kind == .ollama { ProviderMockProtocol.register(host: "localhost", state: state) }
        let configuration = ProviderConfiguration(id: host, name: "Fixture", kind: kind, baseURL: base, model: "fixture-model",
                                                  capabilities: .init(text: true, images: true, structuredOutput: true), inputCostPerMillion: 1, outputCostPerMillion: 1)
        return (service, configuration, state)
    }
    private func envelope(_ kind: ProviderKind, content: String) throws -> Data {
        let object: [String: Any]
        switch kind {
        case .openAI: object = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": content]]]], "usage": ["input_tokens": 100, "output_tokens": 50]]
        case .anthropic: object = ["stop_reason": "tool_use", "content": [["type": "tool_use", "name": "editorial_result", "input": try JSONSerialization.jsonObject(with: Data(content.utf8))]], "usage": ["input_tokens": 100, "output_tokens": 50]]
        case .gemini: object = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": content]]]]], "usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 50]]
        case .openAICompatible: object = ["choices": [["finish_reason": "stop", "message": ["content": content]]], "usage": ["prompt_tokens": 100, "completion_tokens": 50]]
        case .ollama: object = ["done": true, "done_reason": "stop", "message": ["content": content], "prompt_eval_count": 100, "eval_count": 50]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func run(_ service: ProviderService, _ config: ProviderConfiguration, budget: Double = 1, cache: URL? = nil) async throws -> AnalysisResult {
        try await service.analyze(transcript: transcript(), duration: 90, preset: preset(), configuration: config,
                                  budgetUSD: budget, allowUnknownCost: false, cacheDirectory: cache, onUsage: { _ in })
    }

    func testAllProviderAdaptersUseStructuredRequestsAndSourceBoundaries() async throws {
        for kind in ProviderKind.allCases {
            let data = try envelope(kind, content: valid)
            let (service, config, state) = setup(kind) { _ in (200, data) }
            let result = try await run(service, config)
            XCTAssertEqual(result.proposals.count, 1)
            XCTAssertEqual(result.proposals[0].start, 0)
            XCTAssertEqual(result.proposals[0].end, 19)
            XCTAssertEqual(result.usage[0].inputTokens, 100)
            let request = try XCTUnwrap(state.requests.first { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/api/show") != true })
            let body = try XCTUnwrap(request.httpBody)
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            switch kind {
            case .openAI: XCTAssertNotNil(payload["text"]); XCTAssertTrue(request.url!.path.hasSuffix("responses"))
            case .anthropic: XCTAssertNotNil(payload["tool_choice"]); XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key-not-real")
            case .gemini: XCTAssertNotNil(payload["generationConfig"]); XCTAssertNil(request.url!.query); XCTAssertNotNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
            case .openAICompatible: XCTAssertNotNil(payload["response_format"])
            case .ollama:
                XCTAssertNotNil(payload["format"]); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(payload["think"] as? Bool, false)
                XCTAssertEqual((payload["options"] as? [String: Any])?["num_ctx"] as? Int, 16384)
                let schema = try XCTUnwrap(payload["format"] as? [String: Any])
                let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
                let clips = try XCTUnwrap(properties["clips"] as? [String: Any])
                XCTAssertEqual(clips["maxItems"] as? Int, 3)
                let item = try XCTUnwrap(clips["items"] as? [String: Any])
                let fields = try XCTUnwrap(item["properties"] as? [String: Any])
                XCTAssertEqual((fields["start_segment"] as? [String: Any])?["enum"] as? [Int], Array(0..<9))
            }
        }
    }

    func testUnknownPricingAndBudgetRejectBeforeRequest() async throws {
        let data = try envelope(.openAI, content: valid)
        let (service, original, state) = setup { _ in (200, data) }
        var config = original; config.inputCostPerMillion = nil
        do { _ = try await run(service, config); XCTFail("Unknown pricing accepted") } catch EdwardError.budget { } catch { XCTFail("\(error)") }
        do { _ = try await run(service, original, budget: 0.000001); XCTFail("Budget accepted") } catch EdwardError.budget { } catch { XCTFail("\(error)") }
        XCTAssertEqual(state.requests.count, 0)
    }

    func testMixedDurationResultsKeepValidSourceCutsWithoutWideningAnyClip() throws {
        let segments = ProviderService.segments(transcript(), maximumDuration: 22)
        var p = preset(); p.minDuration = 10; p.maxDuration = 22; p.clipCount = 5
        let short = "{\"title\":\"Too short\",\"reason\":\"A short idea.\",\"score\":95,\"start_segment\":2,\"end_segment\":2}"
        let good = "{\"title\":\"Valid idea\",\"reason\":\"A complete idea.\",\"score\":88,\"start_segment\":0,\"end_segment\":1}"
        let long = "{\"title\":\"Too long\",\"reason\":\"Too much context.\",\"score\":92,\"start_segment\":3,\"end_segment\":5}"
        let result = try ProviderService.decodeClips(Data("{\"clips\":[\(short),\(good),\(long)]}".utf8), segments: segments, duration: 90, preset: p)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[0].end, 19)
        XCTAssertEqual(result[0].title, "Valid idea")
        XCTAssertThrowsError(try ProviderService.decodeClips(Data("{\"clips\":[\(short),\(long)]}".utf8), segments: segments, duration: 90, preset: p)) { error in
            XCTAssertTrue(error.localizedDescription.contains("None of the proposed clips"))
        }
        let fabricated = good.replacingOccurrences(of: "\"end_segment\":1", with: "\"end_segment\":999")
        XCTAssertThrowsError(try ProviderService.decodeClips(Data("{\"clips\":[\(good),\(fabricated)]}".utf8), segments: segments, duration: 90, preset: p))
        let guidance = ProviderService.legalBoundaryGuidance(segments, preset: p)
        XCTAssertTrue(guidance.contains("start_segment 0: allowed end_segment values [1]"))
        XCTAssertFalse(guidance.contains("start_segment 0: allowed end_segment values [0"))
    }

    func testUnknownPricingRequiresExplicitOverride() async throws {
        let data = try envelope(.openAI, content: valid)
        let (service, original, state) = setup { _ in (200, data) }
        var config = original; config.inputCostPerMillion = nil
        let result = try await service.analyze(transcript: transcript(), duration: 90, preset: preset(), configuration: config,
                                               budgetUSD: 1, allowUnknownCost: true, onUsage: { _ in })
        XCTAssertNil(result.usage.first?.estimatedCost)
        XCTAssertEqual(state.requests.count, 1)
    }

    func testHistoricalSpendIsCountedAndCachedUsageIsNotDoubleCounted() async throws {
        let data = try envelope(.openAI, content: valid)
        let (service, config, state) = setup { _ in (200, data) }
        let prior = UsageRecord(providerID: "another-provider", model: "previous-model", estimatedCost: 0.9999)
        do {
            _ = try await service.analyze(transcript: transcript(), duration: 90, preset: preset(), configuration: config,
                budgetUSD: 1, allowUnknownCost: false, previousUsage: [prior], onUsage: { _ in })
            XCTFail("Prior paid usage ignored")
        } catch EdwardError.budget { } catch { XCTFail("\(error)") }
        XCTAssertEqual(state.requests.count, 0)
        let cache = temporaryCache(); defer { try? FileManager.default.removeItem(at: cache) }
        let first = try await run(service, config, cache: cache)
        let second = try await service.analyze(transcript: transcript(), duration: 90, preset: preset(), configuration: config,
            budgetUSD: first.usage[0].estimatedCost!, allowUnknownCost: false, previousUsage: first.usage,
            cacheDirectory: cache, onUsage: { _ in })
        XCTAssertEqual(second.proposals.count, 1)
        XCTAssertEqual(state.requests.count, 1)
    }

    func testLoopbackCompatibleEndpointIsFreeByDefaultButHonorsExplicitPrices() async throws {
        let data = try envelope(.openAICompatible, content: valid)
        let state = ProviderMockState { _ in (200, data) }
        ProviderMockProtocol.register(host: "127.0.0.1", state: state)
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [ProviderMockProtocol.self]
        let provider = ProviderService(session: URLSession(configuration: session), credential: { _ in nil })
        var config = ProviderConfiguration(id: "local-compatible", name: "Local endpoint", kind: .openAICompatible,
            baseURL: "http://127.0.0.1:1234/v1", model: "local-model", capabilities: .init())
        XCTAssertTrue(config.isLocal)
        let pastUnknown = UsageRecord(providerID: "previous-cloud", model: "other-model", estimatedCost: nil)
        let local = try await provider.analyze(transcript: transcript(), duration: 90, preset: preset(), configuration: config,
            budgetUSD: 0, allowUnknownCost: false, previousUsage: [pastUnknown], onUsage: { _ in })
        XCTAssertEqual(local.usage.first?.estimatedCost, 0)
        XCTAssertNil(state.requests.first?.value(forHTTPHeaderField: "Authorization"))
        config.inputCostPerMillion = 1; config.outputCostPerMillion = 1
        do { _ = try await run(provider, config, budget: 0); XCTFail("Explicit local-gateway pricing ignored") }
        catch EdwardError.budget { } catch { XCTFail("\(error)") }
        XCTAssertEqual(state.requests.count, 1)
        let metered = try await run(provider, config, budget: 1)
        XCTAssertEqual(metered.usage.first?.estimatedCost ?? 0, 0.00015, accuracy: 0.000001)
        XCTAssertEqual(state.requests.count, 2)
    }

    func testOllamaCloudTagsAndRemoteAliasesAreRejectedBeforeInference() async throws {
        let data = try envelope(.ollama, content: valid)
        let (service, original, state) = setup(.ollama) { _ in (200, data) }
        for name in ["minimax-m2.7:cloud", "gpt-oss:120b-cloud"] {
            var config = original; config.model = name
            do { _ = try await run(service, config); XCTFail("Cloud model accepted") } catch EdwardError.invalidInput { } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(state.requests.count, 0)
        let remoteState = ProviderMockState { _ in (200, Data("{\"models\":[{\"name\":\"fixture-model\",\"remote_host\":\"https://ollama.com\",\"remote_model\":\"some-model\"}]}".utf8)) }
        ProviderMockProtocol.register(host: "localhost", state: remoteState)
        do { _ = try await run(service, original); XCTFail("Remote model alias accepted") } catch EdwardError.invalidInput { } catch { XCTFail("\(error)") }
        XCTAssertEqual(remoteState.requests.count, 1)
        XCTAssertTrue(remoteState.requests.allSatisfy { $0.url?.path.hasSuffix("/api/tags") == true })
    }

    func testOllamaOmitsThinkingOptionWhenModelDoesNotAdvertiseFalseSupport() async throws {
        let data = try envelope(.ollama, content: valid)
        let (service, config, _) = setup(.ollama) { _ in (200, data) }
        let state = ProviderMockState { request in
            if request.url?.path.hasSuffix("/api/tags") == true {
                return (200, Data("{\"models\":[{\"name\":\"fixture-model\"}]}".utf8))
            }
            if request.url?.path.hasSuffix("/api/show") == true {
                return (200, Data("{\"details\":{\"format\":\"gguf\"},\"capabilities\":[\"completion\"],\"thinking\":{\"values\":[\"low\",\"high\"]}}".utf8))
            }
            return (200, data)
        }
        ProviderMockProtocol.register(host: "localhost", state: state)
        _ = try await run(service, config)
        let body = try XCTUnwrap(state.requests.last?.httpBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(payload["think"])
    }

    func testCredentialAndRateErrorsAreSanitizedAndNotRetried() async throws {
        for code in [401, 403, 429] {
            let (service, config, state) = setup { _ in (code, Data("sensitive-server-message test-key-not-real".utf8)) }
            do { _ = try await run(service, config); XCTFail("HTTP \(code) accepted") }
            catch {
                XCTAssertFalse(error.localizedDescription.contains("sensitive-server-message"))
                XCTAssertFalse(error.localizedDescription.contains("test-key-not-real"))
                if case EdwardError.outcomeUnknown = error { XCTFail("Explicit HTTP rejection should be known") }
            }
            XCTAssertEqual(state.requests.count, 1)
        }
    }

    func testInvalidSourceIDAndNumericTimestampAreRejected() async throws {
        for invalid in [valid.replacingOccurrences(of: "\"end_segment\":1", with: "\"end_segment\":999"),
                        valid.replacingOccurrences(of: "\"start_segment\":0", with: "\"start_segment\":0.5"),
                        valid.replacingOccurrences(of: "\"start_segment\":0", with: "\"start\":0"),
                        valid.replacingOccurrences(of: "\"score\":88", with: "\"score\":true")] {
            let data = try envelope(.openAI, content: invalid)
            let (service, config, _) = setup { _ in (200, data) }
            do { _ = try await run(service, config); XCTFail("Invalid boundary accepted") } catch EdwardError.provider { } catch { XCTFail("\(error)") }
        }
    }

    func testMalformedJSONIsCheckpointedInsteadOfRepeated() async throws {
        let (service, config, state) = setup { _ in (200, Data("{broken".utf8)) }
        let cache = temporaryCache(); defer { try? FileManager.default.removeItem(at: cache) }
        for _ in 0..<2 {
            do { _ = try await run(service, config, cache: cache); XCTFail("Malformed JSON accepted") } catch { }
        }
        XCTAssertEqual(state.requests.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.count, 1)
    }

    func testCompletedChunksResumeWithoutRepayingIncludingPriceCorrection() async throws {
        let data = try envelope(.openAI, content: valid)
        let (service, config, state) = setup { _ in (200, data) }
        let cache = temporaryCache(); defer { try? FileManager.default.removeItem(at: cache) }
        let first = try await run(service, config, cache: cache)
        var changed = config; changed.inputCostPerMillion = 2
        let second = try await run(service, changed, cache: cache)
        XCTAssertEqual(state.requests.count, 1)
        XCTAssertEqual(first.usage[0].id, second.usage[0].id)
        XCTAssertEqual(first.proposals[0].ranges, second.proposals[0].ranges)
    }

    func testTimeoutLeavesPendingRequestAndResumeDoesNotSubmitAgain() async throws {
        let (service, config, state) = setup { _ in throw URLError(.timedOut) }
        let cache = temporaryCache(); defer { try? FileManager.default.removeItem(at: cache) }
        for _ in 0..<2 {
            do { _ = try await run(service, config, cache: cache); XCTFail("Timeout accepted") }
            catch EdwardError.outcomeUnknown { } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(state.requests.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).contains { $0.pathExtension == "pending" })
    }

    func testRemoteHTTPUserInfoAndQueryEndpointsAreRejected() async throws {
        let (service, original, state) = setup { _ in XCTFail("Should never send"); return (200, Data()) }
        for endpoint in ["http://example.com/v1", "https://secret:password@example.com/v1", "https://example.com/v1?api_key=secret", "file:///tmp/fake"] {
            var config = original; config.baseURL = endpoint
            do { _ = try await run(service, config); XCTFail("Unsafe endpoint accepted") } catch EdwardError.invalidInput { } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(state.requests.count, 0)
    }

    func testCapabilitiesAndUnorderedTranscriptFailBeforeNetworking() async throws {
        let (service, original, state) = setup { _ in XCTFail("Should never send"); return (200, Data()) }
        var config = original; config.capabilities.structuredOutput = false
        do { _ = try await run(service, config); XCTFail("Capability mismatch accepted") } catch { }
        var t = transcript(); t.words.swapAt(0, 1)
        do { _ = try await service.analyze(transcript: t, duration: 90, preset: preset(), configuration: original, budgetUSD: 1, allowUnknownCost: false, onUsage: { _ in }); XCTFail("Invalid timing accepted") } catch { }
        XCTAssertEqual(state.requests.count, 0)
    }

    func testGlobalRankingDeduplicatesOverlappingChunks() {
        let clips = [ClipProposal(title: "lower", reason: "", score: 70, start: 2, end: 25),
                     ClipProposal(title: "repeated material", reason: "", score: 75, start: 15, end: 40),
                     ClipProposal(title: "best", reason: "", score: 90, start: 0, end: 30),
                     ClipProposal(title: "different", reason: "", score: 80, start: 50, end: 70)]
        let result = ProviderService.rankedUnique(clips, limit: 5)
        XCTAssertEqual(result.map(\.title), ["best", "different"])
    }

    func testReadOnlyConnectionTestUsesGETModelListing() async throws {
        let data = Data("{\"data\":[{\"id\":\"fixture-model\"},{\"id\":\"second\"}]}".utf8)
        let (service, config, state) = setup { _ in (200, data) }
        let result = try await service.testConnection(configuration: config)
        XCTAssertTrue(result.selectedModelListed)
        XCTAssertEqual(result.models.count, 2)
        XCTAssertEqual(state.requests.first?.httpMethod, "GET")
        XCTAssertNil(state.requests.first?.httpBody)
    }

    func testLongTranscriptResumeReusesCompletedChunkBeforePendingChunk() async throws {
        let data = try envelope(.openAI, content: valid)
        let counter = ProviderRequestCounter()
        let (service, config, state) = setup { _ in
            if counter.next() == 1 { return (200, data) }
            throw URLError(.timedOut)
        }
        let transcript = TimedTranscript(words: (0..<500).map {
            TimedWord(text: $0 % 2 == 1 ? "point." : "Useful", start: Double($0) * 5, end: Double($0) * 5 + 4)
        }, engine: "fixture")
        let cache = temporaryCache(); defer { try? FileManager.default.removeItem(at: cache) }
        for _ in 0..<2 {
            do {
                _ = try await service.analyze(transcript: transcript, duration: 2500, preset: preset(), configuration: config,
                                              budgetUSD: 1, allowUnknownCost: false, cacheDirectory: cache, onUsage: { _ in })
                XCTFail("Interrupted chunk accepted")
            } catch EdwardError.outcomeUnknown { } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(state.requests.count, 2)
    }

    func testGeminiResumesLegacyChunksAndRetriesOnlyTheTruncatedPart() async throws {
        let (service, original, state) = setup(.gemini) { request in
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let generation = try XCTUnwrap(payload["generationConfig"] as? [String: Any])
            XCTAssertEqual(generation["maxOutputTokens"] as? Int, 16_384)
            XCTAssertEqual((generation["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String, "low")
            let schema = try XCTUnwrap(generation["responseJsonSchema"] as? [String: Any])
            let clips = try XCTUnwrap((schema["properties"] as? [String: Any])?["clips"] as? [String: Any])
            let fields = try XCTUnwrap((clips["items"] as? [String: Any])?["properties"] as? [String: Any])
            let ids = try XCTUnwrap((fields["start_segment"] as? [String: Any])?["enum"] as? [Int])
            let result = "{\"clips\":[{\"title\":\"Recovered\",\"reason\":\"Complete.\",\"score\":90,\"start_segment\":\(ids[0]),\"end_segment\":\(ids[1])}]}"
            return (200, try self.geminiEnvelope(reason: "STOP", content: result, thoughts: 20, candidates: 30))
        }
        var config = original; config.model = "gemini-3.7-flash"
        let long = TimedTranscript(words: (0..<180).map {
            .init(text: $0 % 2 == 1 ? "point." : "Useful", start: Double($0) * 5, end: Double($0) * 5 + 4)
        }, engine: "fixture")
        let segments = ProviderService.segments(long, maximumDuration: preset().maxDuration)
        let chunks = ProviderService.chunks(segments, overlapSeconds: preset().maxDuration)
        XCTAssertEqual(chunks.count, 2)
        let cache = temporaryCache(); defer { try? FileManager.default.removeItem(at: cache) }
        let first = "{\"clips\":[{\"title\":\"Saved\",\"reason\":\"Complete.\",\"score\":85,\"start_segment\":\(chunks[0][0].id),\"end_segment\":\(chunks[0][1].id)}]}"
        let saved = try writeLegacyGeminiCache(cache, config: config, chunk: chunks[0], response: geminiEnvelope(reason: "STOP", content: first, thoughts: 50, candidates: 20))
        let truncated = try writeLegacyGeminiCache(cache, config: config, chunk: chunks[1], response: geminiEnvelope(reason: "MAX_TOKENS", content: "{", thoughts: 4096, candidates: 0))
        let result = try await service.analyze(transcript: long, duration: 900, preset: preset(), configuration: config,
            budgetUSD: 1, allowUnknownCost: false, previousUsage: [saved, truncated], cacheDirectory: cache, onUsage: { _ in })
        XCTAssertEqual(state.requests.count, 1, "The first successful chunk must not be sent or billed again")
        XCTAssertEqual(result.proposals.count, 2)
        XCTAssertEqual(Set(result.usage.map(\.id)).count, 3)
        XCTAssertEqual(result.usage[0].id, saved.id)
        XCTAssertEqual(result.usage[1].id, truncated.id)
    }

    func testGeminiOutputLimitRetriesOnceAndCachesBothUsages() async throws {
        let counter = ProviderRequestCounter()
        let (service, original, state) = setup(.gemini) { _ in
            if counter.next() == 1 { return (200, try self.geminiEnvelope(reason: "MAX_TOKENS", content: "", thoughts: 3000, candidates: nil)) }
            return (200, try self.geminiEnvelope(reason: "STOP", content: self.valid, thoughts: 20, candidates: 50))
        }
        var config = original; config.model = "gemini-3.7-flash"
        let cache = temporaryCache(); defer { try? FileManager.default.removeItem(at: cache) }
        let first = try await run(service, config, cache: cache)
        XCTAssertEqual(state.requests.count, 2)
        XCTAssertEqual(first.usage.count, 2)
        XCTAssertEqual(first.usage[0].outputTokens, 3000, "Thought-only usage must be accounted for")
        let limits = try state.requests.map { request -> Int in
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            return try XCTUnwrap((payload["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int)
        }
        XCTAssertEqual(limits, [16_384, 32_768])
        let again = try await service.analyze(transcript: transcript(), duration: 90, preset: preset(), configuration: config,
            budgetUSD: 1, allowUnknownCost: false, previousUsage: first.usage, cacheDirectory: cache, onUsage: { _ in })
        XCTAssertEqual(state.requests.count, 2)
        XCTAssertEqual(again.usage.map(\.id), first.usage.map(\.id))
    }

    func testGeminiRetryHonorsRemainingBudgetAndDoesNotRetrySafetyBlocks() async throws {
        let (service, original, state) = setup(.gemini) { _ in
            (200, try self.geminiEnvelope(reason: "MAX_TOKENS", content: "", thoughts: 3000, candidates: nil))
        }
        var config = original; config.model = "gemini-3.7-flash"
        let cache = temporaryCache(); defer { try? FileManager.default.removeItem(at: cache) }
        do { _ = try await run(service, config, budget: 0.03, cache: cache); XCTFail("Retry exceeded the budget") }
        catch EdwardError.budget { } catch { XCTFail("\(error)") }
        XCTAssertEqual(state.requests.count, 1)

        let (blocked, blockedOriginal, blockedState) = setup(.gemini) { _ in
            (200, try self.geminiEnvelope(reason: "SAFETY", content: "", thoughts: 30, candidates: 0))
        }
        var blockedConfig = blockedOriginal; blockedConfig.model = "gemini-3.7-flash"
        let blockedCache = temporaryCache(); defer { try? FileManager.default.removeItem(at: blockedCache) }
        for _ in 0..<2 {
            do { _ = try await run(blocked, blockedConfig, cache: blockedCache); XCTFail("Safety block accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("blocked")) }
        }
        XCTAssertEqual(blockedState.requests.count, 1)
    }

    func testGeminiDoesNotBypassLegacyPendingRequestOrRetryAfterUsageSaveFails() async throws {
        let (service, original, state) = setup(.gemini) { _ in XCTFail("Uncertain request must not be resent"); return (500, Data()) }
        var config = original; config.model = "gemini-3.7-flash"
        let cache = temporaryCache(); defer { try? FileManager.default.removeItem(at: cache) }
        let chunk = ProviderService.chunks(ProviderService.segments(transcript(), maximumDuration: preset().maxDuration), overlapSeconds: preset().maxDuration)[0]
        let request = try legacyGeminiRequest(config: config, chunk: chunk)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("pending".utf8).write(to: cache.appendingPathComponent(legacyDigest(request, config: config) + ".pending"))
        do { _ = try await run(service, config, cache: cache); XCTFail("Pending request bypassed") }
        catch EdwardError.outcomeUnknown { } catch { XCTFail("\(error)") }
        XCTAssertEqual(state.requests.count, 0)

        let (failing, failingOriginal, failingState) = setup(.gemini) { _ in
            (200, try self.geminiEnvelope(reason: "MAX_TOKENS", content: "", thoughts: 3000, candidates: nil))
        }
        var failingConfig = failingOriginal; failingConfig.model = "gemini-3.7-flash"
        let failingCache = temporaryCache(); defer { try? FileManager.default.removeItem(at: failingCache) }
        do {
            _ = try await failing.analyze(transcript: transcript(), duration: 90, preset: preset(), configuration: failingConfig,
                budgetUSD: 1, allowUnknownCost: false, cacheDirectory: failingCache,
                onUsage: { _ in throw EdwardError.invalidInput("fixture storage failure") })
            XCTFail("Usage persistence failure was ignored")
        } catch { XCTAssertTrue(error.localizedDescription.contains("fixture storage failure")) }
        XCTAssertEqual(failingState.requests.count, 1)
    }

    /// Optional private checkpoint replay: the caller supplies a disposable copy; every request is mocked.
    func testSavedGeminiCheckpointReplayWithMockTransport() async throws {
        guard let path = ProcessInfo.processInfo.environment["EDWARD_RECOVERY_FIXTURE"] else { throw XCTSkip("No private recovery fixture supplied") }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let job = try JSONDecoder().decode(JobCheckpoint.self, from: Data(contentsOf: root.appendingPathComponent("job.json")))
        let transcript = try XCTUnwrap(job.transcript)
        let asset = try XCTUnwrap(job.asset)
        let config = job.configuration.editorial
        XCTAssertEqual(config.kind, .gemini)
        let host = try XCTUnwrap(URL(string: config.baseURL)?.host)
        let response = try geminiEnvelope(reason: "STOP", content: "{\"clips\":[]}", thoughts: 10, candidates: 10)
        let state = ProviderMockState { _ in (200, response) }
        ProviderMockProtocol.register(host: host, state: state)
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [ProviderMockProtocol.self]
        let service = ProviderService(session: URLSession(configuration: session), credential: { _ in "fixture-not-a-real-key" })
        let chunks = ProviderService.chunks(ProviderService.segments(transcript, maximumDuration: job.configuration.preset.maxDuration), overlapSeconds: job.configuration.preset.maxDuration)
        let result = try await service.analyze(transcript: transcript, duration: asset.duration, preset: job.configuration.preset,
            configuration: config, budgetUSD: job.configuration.budgetUSD, allowUnknownCost: job.configuration.allowUnknownCost,
            previousUsage: job.usage, cacheDirectory: root.appendingPathComponent("ProviderCache"), onUsage: { _ in })
        XCTAssertEqual(state.requests.count, chunks.count - 1, "The successful old chunk should be reused without another request")
        XCTAssertFalse(result.proposals.isEmpty, "The saved successful chunk's valid clips must survive")
        XCTAssertTrue(Set(job.usage.map(\.id)).isSubset(of: Set(result.usage.map(\.id))))
    }

    private func geminiEnvelope(reason: String, content: String, thoughts: Int, candidates: Int?) throws -> Data {
        var usage: [String: Any] = ["promptTokenCount": 100, "thoughtsTokenCount": thoughts]
        if let candidates { usage["candidatesTokenCount"] = candidates }
        return try JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": reason, "content": ["parts": [["text": content]]]]], "usageMetadata": usage])
    }
    private struct LegacyCache: Codable { let version: Int; let response: Data; let usage: UsageRecord }
    private func legacyGeminiRequest(config: ProviderConfiguration, chunk: [ProviderService.EvidenceSegment]) throws -> URLRequest {
        try ProviderWire.request(configuration: config, credential: "test-key-not-real", prompt: ProviderService.editorialPrompt(chunk, preset: preset()),
            frames: [], schema: ProviderService.clipSchema(segments: chunk, limit: preset().clipCount), outputLimit: 4096)
    }
    private func legacyDigest(_ request: URLRequest, config: ProviderConfiguration) -> String {
        var identity = Data("edward-provider-v1|\(config.id)|\(request.url!.absoluteString)|".utf8)
        identity.append(request.httpBody ?? Data())
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
    private func writeLegacyGeminiCache(_ cache: URL, config: ProviderConfiguration, chunk: [ProviderService.EvidenceSegment], response: Data) throws -> UsageRecord {
        let request = try legacyGeminiRequest(config: config, chunk: chunk)
        let usage = UsageRecord(providerID: config.id, model: config.model, inputTokens: 100, outputTokens: 100, estimatedCost: 0.0002)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try JSONEncoder().encode(LegacyCache(version: 1, response: response, usage: usage)).write(to: cache.appendingPathComponent(legacyDigest(request, config: config) + ".json"))
        return usage
    }

    func testVisualPassPreservesCutsAndRejectsUnknownCandidateIDs() async throws {
        let content = "{\"assessments\":[{\"candidate_id\":0,\"keep\":true,\"score\":80,\"reason\":\"Relevant slide is visible.\"}]}"
        let data = try envelope(.openAI, content: content)
        let (service, config, _) = setup { _ in (200, data) }
        let clip = ClipProposal(title: "A point", reason: "Complete thought", score: 90, start: 0, end: 19)
        let result = try await service.assessVisual(proposals: [clip], transcript: transcript(), duration: 90, preset: preset(),
            configuration: config, frames: [.init(timestamp: 5, jpegData: Data([0xff, 0xd8, 0xff, 0xd9]))],
            budgetUSD: 1, allowUnknownCost: false, onUsage: { _ in })
        XCTAssertEqual(result.proposals.first?.id, clip.id)
        XCTAssertEqual(result.proposals.first?.ranges, clip.ranges)
        XCTAssertEqual(result.proposals.first?.score, 85)
        XCTAssertThrowsError(try ProviderService.decodeVisual(Data(content.replacingOccurrences(of: "\"candidate_id\":0", with: "\"candidate_id\":9").utf8), count: 1))
    }

    func testCancelledNetworkCompletionIsUnknownAndNotAutomaticallyRepeated() async throws {
        let (service, config, state) = setup { _ in throw URLError(.cancelled) }
        let cache = temporaryCache(); defer { try? FileManager.default.removeItem(at: cache) }
        for _ in 0..<2 {
            do { _ = try await run(service, config, cache: cache); XCTFail("Ambiguous cancellation accepted") }
            catch EdwardError.outcomeUnknown { } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(state.requests.count, 1)
    }

    private func temporaryCache() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("EdwardProviderTests-" + UUID().uuidString) }
}

private final class ProviderRequestCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

private final class ProviderMockState: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let handler: (URLRequest) throws -> (Int, Data)
    init(handler: @escaping (URLRequest) throws -> (Int, Data)) { self.handler = handler }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; recorded.append(request) }
}

private final class ProviderMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var states: [String: ProviderMockState] = [:]
    static func register(host: String, state: ProviderMockState) { lock.lock(); defer { lock.unlock() }; states[host] = state }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let state = Self.states[request.url?.host ?? ""]; Self.lock.unlock()
        guard let state else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            request.httpBody = data
        }
        state.append(request)
        do {
            let (status, data) = try state.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "x-request-id": "fixture-request"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
