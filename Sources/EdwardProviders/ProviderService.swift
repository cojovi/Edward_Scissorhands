import Foundation
import CryptoKit
import EdwardDomain

/// Reuses saved responses and only retries a confirmed Gemini output-limit result, within the configured budget.
public actor ProviderService {
    public typealias CredentialReader = @Sendable (String) throws -> String?
    private let session: URLSession
    private let credential: CredentialReader
    private let outputLimit = 4096
    private var ollamaSupportsNoThinking = Set<String>()

    public init(session: URLSession? = nil, credential: @escaping CredentialReader = { try KeychainStore.read(providerID: $0) }) {
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: ProviderRedirectGuard(), delegateQueue: nil)
        }
        self.credential = credential
    }

    /// Lists models without generating content or charging inference tokens.
    public func listModels(configuration c: ProviderConfiguration) async throws -> [ProviderModel] {
        var result: [ProviderModel] = []; var cursor: String?
        let key = try credential(c.id)
        for _ in 0..<20 {
            try Task.checkCancellation()
            var query: [URLQueryItem] = []
            let path = c.kind == .ollama ? "api/tags" : "models"
            if c.kind == .gemini {
                query.append(.init(name: "pageSize", value: "1000"))
                if let cursor { query.append(.init(name: "pageToken", value: cursor)) }
            } else if c.kind == .anthropic {
                query.append(.init(name: "limit", value: "1000"))
                if let cursor { query.append(.init(name: "after_id", value: cursor)) }
            }
            var request = URLRequest(url: try ProviderWire.endpoint(c, path: path, query: query))
            request.timeoutInterval = 30
            try ProviderWire.headers(&request, configuration: c, credential: key)
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await session.data(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw EdwardError.provider("Could not connect to \(c.name). Check the endpoint and network connection.") }
            guard let http = response as? HTTPURLResponse else { throw EdwardError.provider("The endpoint returned an invalid HTTP response.") }
            try Self.checkHTTP(http.statusCode, paid: false)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EdwardError.provider("The endpoint returned an invalid model list.") }
            guard let entries = object[c.kind == .ollama || c.kind == .gemini ? "models" : "data"] as? [[String: Any]] else {
                throw EdwardError.provider("The endpoint returned an invalid model-list format.")
            }
            for entry in entries {
                if c.kind == .gemini, let methods = entry["supportedGenerationMethods"] as? [String], !methods.contains("generateContent") { continue }
                let rawID = entry[c.kind == .ollama || c.kind == .gemini ? "name" : "id"] as? String ?? ""
                if c.kind == .ollama && (Self.isCloudModelName(rawID) || Self.hasRemoteModelMetadata(entry)) { continue }
                let id = c.kind == .gemini && rawID.hasPrefix("models/") ? String(rawID.dropFirst(7)) : rawID
                if !id.isEmpty { result.append(.init(id: id, name: entry["displayName"] as? String ?? entry["display_name"] as? String ?? id)) }
            }
            let next: String?
            if c.kind == .gemini { next = object["nextPageToken"] as? String }
            else if c.kind == .anthropic, object["has_more"] as? Bool == true { next = object["last_id"] as? String }
            else { next = nil }
            guard let next, !next.isEmpty, next != cursor else {
                var seen = Set<String>()
                return result.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            cursor = next
        }
        throw EdwardError.provider("The model list exceeded the pagination limit. Use a narrower endpoint or enter a model ID manually.")
    }

    public func testConnection(configuration: ProviderConfiguration) async throws -> ProviderConnection {
        let models = try await listModels(configuration: configuration)
        if configuration.kind == .ollama, !configuration.model.isEmpty { try await validateOllamaModel(configuration, needsImages: false) }
        let model = configuration.model.replacingOccurrences(of: "models/", with: "")
        return .init(models: models, selectedModelListed: models.contains { $0.id == model })
    }

    public func analyze(transcript: TimedTranscript, duration: Double, preset: BatchPreset,
                        configuration: ProviderConfiguration, frames: [VideoFrame] = [], budgetUSD: Double,
                        allowUnknownCost: Bool, previousUsage: [UsageRecord] = [], cacheDirectory: URL? = nil,
                        onProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
                        onUsage: @escaping @Sendable (UsageRecord) async throws -> Void) async throws -> AnalysisResult {
        try validate(configuration, frames: frames, budget: budgetUSD, allowUnknown: allowUnknownCost)
        if isMetered(configuration) { try Self.validatePreviousUsage(previousUsage, allowUnknownCost: allowUnknownCost) }
        try Self.validate(transcript: transcript, duration: duration, preset: preset)
        if configuration.kind == .ollama { try await validateOllamaModel(configuration, needsImages: !frames.isEmpty) }
        let segments = Self.segments(transcript, maximumDuration: preset.maxDuration)
        let chunks = Self.chunks(segments, overlapSeconds: preset.maxDuration)
        var proposals: [ClipProposal] = []; var usage: [UsageRecord] = []
        var knownUsage = Set<UUID>(); var spent: Double = 0
        for record in previousUsage where knownUsage.insert(record.id).inserted { spent += record.estimatedCost ?? 0 }
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            await onProgress(index + 1, chunks.count)
            let selectedFrames = Self.selectFrames(frames, start: chunk.first!.start, end: chunk.last!.end, limit: 4)
            let prompt = Self.editorialPrompt(chunk, preset: preset)
            let result = try await execute(prompt: prompt, frames: selectedFrames, schema: Self.clipSchema(segments: chunk, limit: preset.clipCount),
                                           configuration: configuration, budgetRemaining: max(0, budgetUSD - spent),
                                           allowUnknownCost: allowUnknownCost, cacheDirectory: cacheDirectory,
                                           knownUsage: knownUsage, onUsage: onUsage)
            usage.append(contentsOf: result.usage)
            for record in result.usage where knownUsage.insert(record.id).inserted { spent += record.estimatedCost ?? 0 }
            proposals += try Self.decodeClips(result.content, segments: chunk, duration: duration, preset: preset)
        }
        return .init(proposals: Self.rankedUnique(proposals, limit: preset.clipCount), usage: usage)
    }

    /// Optional visual quality pass. It may reject/rerank candidates but cannot invent new cuts.
    public func assessVisual(proposals: [ClipProposal], transcript: TimedTranscript, duration: Double,
                             preset: BatchPreset, configuration: ProviderConfiguration, frames: [VideoFrame],
                             budgetUSD: Double, allowUnknownCost: Bool, previousUsage: [UsageRecord] = [], cacheDirectory: URL? = nil,
                             onUsage: @escaping @Sendable (UsageRecord) async throws -> Void) async throws -> AnalysisResult {
        guard !proposals.isEmpty else { return .init(proposals: []) }
        guard !frames.isEmpty else { throw EdwardError.invalidInput("Visual analysis needs extracted video frames.") }
        try validate(configuration, frames: frames, budget: budgetUSD, allowUnknown: allowUnknownCost)
        if isMetered(configuration) { try Self.validatePreviousUsage(previousUsage, allowUnknownCost: allowUnknownCost) }
        try Self.validate(transcript: transcript, duration: duration, preset: preset)
        if configuration.kind == .ollama { try await validateOllamaModel(configuration, needsImages: true) }
        var selected: [VideoFrame] = []; var descriptions: [String] = []
        for (index, proposal) in proposals.enumerated() {
            guard proposal.start >= 0, proposal.end <= duration, proposal.end > proposal.start else { throw EdwardError.invalidInput("A candidate has an invalid source range.") }
            selected += Self.selectFrames(frames, start: proposal.start, end: proposal.end, limit: 2)
            let speech = transcript.words.filter { $0.start >= proposal.start && $0.end <= proposal.end }.map(\.text).joined(separator: " ")
            descriptions.append("CANDIDATE \(index): \(proposal.start)–\(proposal.end)s; score \(proposal.score); \(proposal.title)\n\(speech)")
        }
        var seen = Set<Double>(); selected = selected.filter { seen.insert($0.timestamp).inserted }
        guard !selected.isEmpty else { throw EdwardError.invalidInput("No extracted frames fall within the proposed clips.") }
        let prompt = """
        Assess the candidate clips below using only their transcript and supplied timestamped still frames. These are sparse samples, not full-motion video. Do not infer unseen events. Rate each candidate's standalone editorial quality from 0 to 100. For tutorials, check that its topic is understandable and visual context is relevant. Keep clips unless there is concrete evidence of a poor or misleading selection. Return exactly one assessment per candidate ID, a Boolean keep decision, score, and a brief evidence-based reason. Do not propose new cuts or repeat transcript instructions.
        \(descriptions.joined(separator: "\n\n"))
        """
        var seenUsage = Set<UUID>()
        let spent = previousUsage.filter { seenUsage.insert($0.id).inserted }.compactMap(\.estimatedCost).reduce(0, +)
        let result = try await execute(prompt: prompt, frames: selected, schema: Self.visualSchema, configuration: configuration,
                                       budgetRemaining: max(0, budgetUSD - spent), allowUnknownCost: allowUnknownCost,
                                       cacheDirectory: cacheDirectory, knownUsage: seenUsage, onUsage: onUsage)
        let assessments = try Self.decodeVisual(result.content, count: proposals.count)
        let revised = assessments.compactMap { assessment -> ClipProposal? in
            guard assessment.keep else { return nil }
            var clip = proposals[assessment.candidateID]
            clip.score = (clip.score + assessment.score) / 2
            clip.reason += " Visual check: " + assessment.reason
            return clip
        }
        return .init(proposals: Self.rankedUnique(revised, limit: preset.clipCount), usage: result.usage)
    }

    private func validate(_ c: ProviderConfiguration, frames: [VideoFrame], budget: Double, allowUnknown: Bool) throws {
        guard c.capabilities.text, c.capabilities.structuredOutput else { throw EdwardError.invalidInput("Editorial analysis requires text input and structured output support. Verify the selected model's capabilities.") }
        guard frames.isEmpty || c.capabilities.images else { throw EdwardError.invalidInput("The selected model is not configured for image input. Select a vision-capable model or turn off visual analysis.") }
        guard !c.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EdwardError.invalidInput("Choose a model in Connections.") }
        if c.kind == .ollama, Self.isCloudModelName(c.model) {
            throw EdwardError.invalidInput("The Ollama adapter accepts downloaded local models only. Cloud-tagged models cannot run through this local-processing connection.")
        }
        guard budget.isFinite, budget >= 0 else { throw EdwardError.budget("Enter a nonnegative job budget.") }
        for price in [c.inputCostPerMillion, c.outputCostPerMillion].compactMap({ $0 }) {
            guard price.isFinite, price >= 0 else { throw EdwardError.budget("Token prices must be finite and nonnegative.") }
        }
        if isMetered(c) && (c.inputCostPerMillion == nil || c.outputCostPerMillion == nil) && !allowUnknown {
            throw EdwardError.budget("Enter the selected model's input and output prices, or explicitly allow unknown cost. A spending cap cannot be guaranteed with unknown prices.")
        }
        guard frames.allSatisfy({ $0.timestamp.isFinite && $0.timestamp >= 0 && !$0.jpegData.isEmpty && $0.jpegData.count <= 5_000_000 }) else {
            throw EdwardError.invalidInput("A video frame is missing, too large, or has an invalid timestamp.")
        }
        _ = try ProviderWire.endpoint(c, path: "")
    }

    private static func validatePreviousUsage(_ usage: [UsageRecord], allowUnknownCost: Bool) throws {
        guard allowUnknownCost || usage.allSatisfy({ $0.estimatedCost != nil }) else {
            throw EdwardError.budget("An earlier request has unknown cost. Confirm its cost or explicitly allow unknown spending before making further requests.")
        }
    }

    private static func isCloudModelName(_ name: String) -> Bool {
        let model = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return model.hasSuffix(":cloud") || model.hasSuffix("-cloud")
    }

    private static func hasRemoteModelMetadata(_ object: [String: Any]) -> Bool {
        let details = object["details"] as? [String: Any] ?? [:]
        return [object["remote_host"], object["remote_model"], details["remote_host"], details["remote_model"]].contains {
            guard let value = $0 as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// /api/show reads metadata only; unlike /api/chat it cannot trigger model inference.
    private func validateOllamaModel(_ c: ProviderConfiguration, needsImages: Bool) async throws {
        guard !Self.isCloudModelName(c.model) else { throw EdwardError.invalidInput("Choose a downloaded local Ollama model, not a cloud-tagged model.") }
        // The tags response carries remote_host/remote_model in current Ollama versions.
        // Check it even for manually entered aliases whose names do not contain "cloud".
        let listed = try await listModels(configuration: c)
        let model = c.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard listed.contains(where: { $0.id == model || $0.id == model + ":latest" }) else {
            throw EdwardError.invalidInput("The selected Ollama model is remote or is not downloaded. Choose an available downloaded local model.")
        }
        var request = URLRequest(url: try ProviderWire.endpoint(c, path: "api/show"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": c.model, "verbose": false])
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw EdwardError.provider("Could not verify the local Ollama model. Check that the server is running and the model is downloaded.") }
        guard let http = response as? HTTPURLResponse else { throw EdwardError.provider("Ollama returned an invalid model-information response.") }
        try Self.checkHTTP(http.statusCode, paid: false)
        guard let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              info["details"] is [String: Any] || info["model_info"] is [String: Any] else {
            throw EdwardError.provider("Ollama did not return usable model metadata; local execution could not be verified.")
        }
        guard !Self.hasRemoteModelMetadata(info) else {
            throw EdwardError.invalidInput("Ollama reports that this model runs on a remote host. Choose a downloaded local model for this connection.")
        }
        if let capabilities = info["capabilities"] as? [String] {
            guard capabilities.contains("completion") else { throw EdwardError.invalidInput("This Ollama model cannot generate editorial text.") }
            guard !needsImages || capabilities.contains("vision") else { throw EdwardError.invalidInput("This Ollama model does not support image input.") }
        }
        let identity = c.baseURL + "|" + c.model
        let thinking = info["thinking"] as? [String: Any]
        if let values = thinking?["values"] as? [Any], values.contains(where: { ($0 as? Bool) == false }) {
            ollamaSupportsNoThinking.insert(identity)
        } else { ollamaSupportsNoThinking.remove(identity) }
    }

    private struct CachedResponse: Codable {
        let version: Int
        let response: Data
        let usage: UsageRecord
    }
    private struct Executed { let content: Data; let usage: [UsageRecord] }

    private func execute(prompt: String, frames: [VideoFrame], schema: [String: Any], configuration c: ProviderConfiguration,
                         budgetRemaining: Double, allowUnknownCost: Bool, cacheDirectory: URL?,
                         knownUsage: Set<UUID>, onUsage: @escaping @Sendable (UsageRecord) async throws -> Void) async throws -> Executed {
        let key = try credential(c.id)
        func request(_ limit: Int, lowThinking: Bool = false) throws -> URLRequest {
            try ProviderWire.request(configuration: c, credential: key, prompt: prompt, frames: frames, schema: schema,
                                     outputLimit: limit, ollamaDisableThinking: ollamaSupportsNoThinking.contains(c.baseURL + "|" + c.model),
                                     geminiLowThinking: lowThinking)
        }
        let legacy = try request(outputLimit)
        var requests: [(URLRequest, Int)] = []
        if c.kind == .gemini {
            // Keep using successful 4,096-token responses from existing projects. Also honor an
            // unresolved old request before changing its request body or output allowance.
            if let cacheDirectory {
                let digest = Self.digest(for: legacy, configuration: c)
                if ["json", "pending"].contains(where: { FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(digest + "." + $0).path) }) {
                    requests.append((legacy, outputLimit))
                }
            }
            // Google's documented 3.7/3.8 Flash models support low thinking and 65,536 output tokens.
            // Other/custom Gemini IDs receive no model-specific thinking setting.
            let model = c.model.replacingOccurrences(of: "models/", with: "").lowercased()
            let knownThinkingModel = ["gemini-3.7-flash", "gemini-3.8-flash"].contains { model == $0 || model.hasPrefix($0 + "-") }
            let limit = knownThinkingModel ? 16_384 : 8_192
            requests.append((try request(limit, lowThinking: knownThinkingModel), limit))
            if knownThinkingModel { requests.append((try request(32_768, lowThinking: true), 32_768)) }
        } else { requests.append((legacy, outputLimit)) }

        var seen = knownUsage; var newSpend = 0.0; var usages: [UsageRecord] = []
        for (index, item) in requests.enumerated() {
            let (request, limit) = item
            let cached = try await executeAttempt(request: request, outputLimit: limit, configuration: c,
                budgetRemaining: max(0, budgetRemaining - newSpend), allowUnknownCost: allowUnknownCost,
                cacheDirectory: cacheDirectory, onUsage: onUsage)
            usages.append(cached.usage)
            if seen.insert(cached.usage.id).inserted { newSpend += cached.usage.estimatedCost ?? 0 }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: cached.usage.requestID.map { ["x-request-id": $0] })!
            do {
                let wire = try ProviderWire.response(cached.response, configuration: c, http: http)
                return .init(content: wire.content, usage: usages)
            } catch ProviderWire.Incomplete.geminiOutputLimit {
                guard index + 1 < requests.count else {
                    throw EdwardError.provider("Gemini reached its output limit. Your transcript and completed analysis parts are saved. Try another compatible model or shorter source; no more requests were made.")
                }
                // The provider explicitly reported a completed, truncated result. A single larger
                // request is safe to attempt, but it is billable and must pass the remaining budget check.
            }
        }
        throw EdwardError.provider("No analysis request was available.")
    }

    private static func digest(for request: URLRequest, configuration c: ProviderConfiguration) -> String {
        var identity = Data("edward-provider-v1|\(c.id)|\(request.url!.absoluteString)|".utf8)
        identity.append(request.httpBody ?? Data())
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    private func executeAttempt(request: URLRequest, outputLimit: Int, configuration c: ProviderConfiguration,
                                budgetRemaining: Double, allowUnknownCost: Bool, cacheDirectory: URL?,
                                onUsage: @escaping @Sendable (UsageRecord) async throws -> Void) async throws -> CachedResponse {
        // Byte count is deliberately conservative for text and inline base64 image requests.
        let reservedInput = (request.httpBody?.count ?? 0) + 2048
        let reservedCost = cost(c, input: reservedInput, output: outputLimit)
        let digest = Self.digest(for: request, configuration: c)
        let completeURL = cacheDirectory?.appendingPathComponent(digest + ".json")
        let pendingURL = cacheDirectory?.appendingPathComponent(digest + ".pending")
        if let completeURL, FileManager.default.fileExists(atPath: completeURL.path) {
            let cached: CachedResponse
            do { cached = try JSONDecoder().decode(CachedResponse.self, from: Data(contentsOf: completeURL)) }
            catch { throw EdwardError.outcomeUnknown("A saved provider response is unreadable. Preserve the cache and check provider usage before retrying.") }
            guard cached.version == 1 else { throw EdwardError.outcomeUnknown("This provider cache version is unsupported. Check usage before retrying.") }
            try await onUsage(cached.usage)
            return cached
        }
        if let pendingURL, FileManager.default.fileExists(atPath: pendingURL.path), isMetered(c) {
            throw EdwardError.outcomeUnknown("A previous paid request has an uncertain outcome. Check the provider's usage dashboard before explicitly retrying; it will not be repeated automatically.")
        }
        if let reservedCost, reservedCost > budgetRemaining + 0.000001 {
            throw EdwardError.budget("The next request's conservative estimate exceeds the remaining job budget. Raise the budget, choose a cheaper model, or use local processing.")
        }
        if reservedCost == nil && !allowUnknownCost { throw EdwardError.budget("The request has unknown pricing. Explicitly allow unknown cost before proceeding.") }
        try Task.checkCancellation()
        if let cacheDirectory { try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true) }
        if let pendingURL { try Data("Request submitted; outcome may be unknown. Do not automatically retry.".utf8).write(to: pendingURL, options: .atomic) }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if !isMetered(c) {
                if let pendingURL { try? FileManager.default.removeItem(at: pendingURL) }
                if Task.isCancelled { throw CancellationError() }
                throw EdwardError.provider("The local model connection failed. Check that the server is running and the selected model is available.")
            }
            throw EdwardError.outcomeUnknown("The provider connection ended before a complete response arrived. It may have processed the request. Check usage before explicitly retrying.")
        }
        guard let http = response as? HTTPURLResponse else { throw EdwardError.outcomeUnknown("The provider returned an invalid response. Check usage before retrying.") }
        do { try Self.checkHTTP(http.statusCode, paid: isMetered(c)) }
        catch {
            if (400..<500).contains(http.statusCode) || !isMetered(c) {
                if let pendingURL { try? FileManager.default.removeItem(at: pendingURL) }
            }
            throw error
        }
        guard data.count <= 12_000_000 else { throw EdwardError.outcomeUnknown("The provider response exceeded the supported size. Check usage before retrying.") }
        let reported = Self.reportedUsage(data, kind: c.kind)
        // If an endpoint omits usage, retain the reservation rather than treating a paid call as free.
        let input = reported?.0 ?? reservedInput
        let output = reported?.1 ?? outputLimit
        let usage = UsageRecord(providerID: c.id, model: c.model, requestID: http.value(forHTTPHeaderField: "x-request-id"),
                                inputTokens: input, outputTokens: output, estimatedCost: cost(c, input: input, output: output))
        let cached = CachedResponse(version: 1, response: data, usage: usage)
        if let completeURL {
            do { try JSONEncoder().encode(cached).write(to: completeURL, options: .atomic) }
            catch { try? await onUsage(usage); throw EdwardError.outcomeUnknown("The paid response arrived but could not be checkpointed. Check free disk space and usage before retrying.") }
        }
        if let pendingURL { try? FileManager.default.removeItem(at: pendingURL) }
        try await onUsage(usage)
        if let actual = usage.estimatedCost, actual > budgetRemaining + 0.000001 {
            throw EdwardError.budget("Reported usage exceeded the configured estimate. The response was saved; processing stopped before further requests.")
        }
        return cached
    }

    private func cost(_ c: ProviderConfiguration, input: Int, output: Int) -> Double? {
        if !isMetered(c) { return 0 }
        guard let inputPrice = c.inputCostPerMillion, let outputPrice = c.outputCostPerMillion else { return nil }
        return (Double(input) * inputPrice + Double(output) * outputPrice) / 1_000_000
    }

    private func isMetered(_ c: ProviderConfiguration) -> Bool {
        !c.isLocal || (c.inputCostPerMillion ?? 0) > 0 || (c.outputCostPerMillion ?? 0) > 0
    }

    private static func reportedUsage(_ data: Data, kind: ProviderKind) -> (Int, Int)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let usage = object[kind == .gemini ? "usageMetadata" : "usage"] as? [String: Any]
        let input: Int?; let output: Int?
        switch kind {
        case .openAI: input = usage?["input_tokens"] as? Int; output = usage?["output_tokens"] as? Int
        case .anthropic:
            input = (usage?["input_tokens"] as? Int).map { $0 + (usage?["cache_read_input_tokens"] as? Int ?? 0) + (usage?["cache_creation_input_tokens"] as? Int ?? 0) }
            output = usage?["output_tokens"] as? Int
        case .gemini:
            input = usage?["promptTokenCount"] as? Int
            let candidates = usage?["candidatesTokenCount"] as? Int
            let thoughts = usage?["thoughtsTokenCount"] as? Int
            output = candidates == nil && thoughts == nil ? nil : (candidates ?? 0) + (thoughts ?? 0)
        case .openAICompatible: input = usage?["prompt_tokens"] as? Int; output = usage?["completion_tokens"] as? Int
        case .ollama: input = object["prompt_eval_count"] as? Int; output = object["eval_count"] as? Int
        }
        guard let input, let output, input >= 0, output >= 0 else { return nil }
        return (input, output)
    }

    private static func checkHTTP(_ status: Int, paid: Bool) throws {
        guard (200..<300).contains(status) else {
            switch status {
            case 401, 403: throw EdwardError.provider("The provider rejected this credential or permission. Check the API key and model access.")
            case 404: throw EdwardError.provider("The endpoint or model was not found. Check the base URL and model ID.")
            case 429: throw EdwardError.provider("The provider reported a rate or quota limit. Check billing or wait before explicitly retrying.")
            case 400, 422: throw EdwardError.provider("The model rejected the request format. Verify its text, image, and structured-output capabilities.")
            case 500...599 where paid: throw EdwardError.outcomeUnknown("The provider returned a server error after submission. Check its usage dashboard before retrying.")
            default: throw EdwardError.provider("The provider returned HTTP \(status). No automatic retry was made.")
            }
        }
    }
}
