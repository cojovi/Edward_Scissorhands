import Foundation

public struct TimeRange: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var duration: Double { max(0, end - start) }
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public struct MediaAsset: Codable, Identifiable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var duration: Double
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var hasAudio: Bool
    public init(id: UUID = UUID(), url: URL, title: String, duration: Double, width: Int, height: Int, frameRate: Double = 30, hasAudio: Bool = true) {
        self.id = id; self.url = url; self.title = title; self.duration = duration
        self.width = width; self.height = height; self.frameRate = frameRate; self.hasAudio = hasAudio
    }
}

public struct TimedWord: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var speaker: String?
    public init(text: String, start: Double, end: Double, speaker: String? = nil) {
        self.text = text; self.start = start; self.end = end; self.speaker = speaker
    }
}

public struct TimedSentence: Identifiable, Sendable {
    public let id: Int
    public let words: [TimedWord]
    public var text: String { words.map(\.text).joined(separator: " ") }
    public var range: TimeRange { .init(start: words.first?.start ?? 0, end: words.last?.end ?? 0) }
    public init(id: Int, words: [TimedWord]) { self.id = id; self.words = words }
}

public struct TimedTranscript: Codable, Sendable {
    public var words: [TimedWord]
    public var language: String
    public var engine: String
    public init(words: [TimedWord], language: String = "auto", engine: String) {
        self.words = words; self.language = language; self.engine = engine
    }
    public var text: String { words.map(\.text).joined(separator: " ") }
    public var sentences: [TimedSentence] {
        var result: [TimedSentence] = []; var current: [TimedWord] = []
        for word in words {
            if let previous = current.last, word.start - previous.end > 1.5 || (previous.speaker != word.speaker && word.speaker != nil) {
                result.append(.init(id: result.count, words: current)); current = []
            }
            current.append(word)
            if word.text.range(of: "[.!?][\"'’”]?$", options: .regularExpression) != nil {
                result.append(.init(id: result.count, words: current)); current = []
            }
        }
        if !current.isEmpty { result.append(.init(id: result.count, words: current)) }
        return result
    }
}

public struct SpeakerInterval: Codable, Hashable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public init(speaker: String, start: Double, end: Double) { self.speaker = speaker; self.start = start; self.end = end }
}
public struct SpeakerTrack: Codable, Sendable {
    public var intervals: [SpeakerInterval]
    public init(intervals: [SpeakerInterval] = []) { self.intervals = intervals }
}
public struct CropKeyframe: Codable, Hashable, Sendable {
    public var time: Double
    public var centerX: Double
    public var centerY: Double
    public var preserve: Bool
    public init(time: Double, centerX: Double, centerY: Double = 0.5, preserve: Bool = false) { self.time = time; self.centerX = centerX; self.centerY = centerY; self.preserve = preserve }
}

public struct ClipProposal: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var reason: String
    public var score: Double
    public var ranges: [TimeRange]
    public var duration: Double { ranges.reduce(0) { $0 + $1.duration } }
    public var start: Double { ranges.first?.start ?? 0 }
    public var end: Double { ranges.last?.end ?? 0 }
    public init(id: UUID = UUID(), title: String, reason: String, score: Double = 0, ranges: [TimeRange]) {
        self.id = id; self.title = title; self.reason = reason; self.score = score; self.ranges = ranges
    }
    public init(id: UUID = UUID(), title: String, reason: String, score: Double = 0, start: Double, end: Double) {
        self.init(id: id, title: title, reason: reason, score: score, ranges: [.init(start: start, end: end)])
    }
}

public enum FramingMode: String, Codable, CaseIterable, Sendable { case speaker, preserve }
public enum VideoQuality: String, Codable, CaseIterable, Sendable { case standard, sharp, maximum }
public enum CanvasFormat: String, Codable, CaseIterable, Sendable {
    case vertical, square, landscape
    public var width: Int { self == .landscape ? 1920 : 1080 }
    public var height: Int { self == .vertical ? 1920 : 1080 }
}
public struct CaptionStyle: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    public var fontSize: Double = 58
    public var wordsPerLine: Int = 5
    public var bottomInset: Double = 320
    public var textHex: String = "F3FAF6"
    public var highlightHex: String = "39FF6A"
    public var speakerColors: Bool = false
    public var atTop: Bool = false
    public init() {}
}
public struct BatchPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var clipCount: Int = 5
    public var minDuration: Double = 30
    public var maxDuration: Double = 90
    public var topic: String = ""
    public var framing: FramingMode = .speaker
    public var canvas: CanvasFormat = .vertical
    public var captions: CaptionStyle = .init()
    public var automaticExport: Bool = true
    public var removeFillersAndPauses: Bool = false
    public var recognizeSpeakers: Bool = true
    public var quality: VideoQuality = .sharp
    public init(id: String = "podcast", name: String = "Podcast highlights", framing: FramingMode = .speaker) {
        self.id = id; self.name = name; self.framing = framing
    }
    public static let defaults: [BatchPreset] = [.init(), .init(id: "interview", name: "Interview moments"), .init(id: "tutorial", name: "Tutorial takeaways", framing: .preserve)]
}

public struct RenderPlan: Codable, Identifiable, Sendable {
    public var id: UUID
    public var sourceURL: URL
    public var outputURL: URL
    public var clip: ClipProposal
    public var transcript: TimedTranscript
    public var canvas: CanvasFormat
    public var framing: FramingMode
    public var cropKeyframes: [CropKeyframe]
    public var captions: CaptionStyle
    public var quality: VideoQuality = .sharp
    public init(id: UUID = UUID(), sourceURL: URL, outputURL: URL, clip: ClipProposal, transcript: TimedTranscript, canvas: CanvasFormat = .vertical, framing: FramingMode = .speaker, cropKeyframes: [CropKeyframe] = [], captions: CaptionStyle = .init()) {
        self.id = id; self.sourceURL = sourceURL; self.outputURL = outputURL; self.clip = clip
        self.transcript = transcript; self.canvas = canvas; self.framing = framing
        self.cropKeyframes = cropKeyframes; self.captions = captions
    }
}
public struct ClipResult: Codable, Identifiable, Sendable {
    public var id: UUID { proposal.id }
    public var proposal: ClipProposal
    public var plan: RenderPlan?
    public var outputURL: URL?
    public var error: String?
    public init(proposal: ClipProposal, plan: RenderPlan? = nil, outputURL: URL? = nil, error: String? = nil) {
        self.proposal = proposal; self.plan = plan; self.outputURL = outputURL; self.error = error
    }
}

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case openAI, anthropic, gemini, openAICompatible, ollama
    public var title: String {
        switch self { case .openAI: return "OpenAI"; case .anthropic: return "Anthropic"; case .gemini: return "Gemini"; case .openAICompatible: return "Compatible API"; case .ollama: return "Ollama" }
    }
}
public struct ProviderCapabilities: Codable, Equatable, Sendable {
    public var text: Bool = true
    public var images: Bool = false
    public var video: Bool = false
    public var transcription: Bool = false
    public var structuredOutput: Bool = true
    public init(text: Bool = true, images: Bool = false, video: Bool = false, transcription: Bool = false, structuredOutput: Bool = true) {
        self.text = text; self.images = images; self.video = video; self.transcription = transcription; self.structuredOutput = structuredOutput
    }
}
public struct ProviderConfiguration: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: ProviderKind
    public var baseURL: String
    public var model: String
    public var capabilities: ProviderCapabilities
    public var inputCostPerMillion: Double?
    public var outputCostPerMillion: Double?
    public var isLocal: Bool {
        if kind == .ollama { return true }
        return kind == .openAICompatible && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(URLComponents(string: baseURL)?.host?.lowercased() ?? "")
    }
    public init(id: String, name: String, kind: ProviderKind, baseURL: String, model: String = "", capabilities: ProviderCapabilities = .init(), inputCostPerMillion: Double? = nil, outputCostPerMillion: Double? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL; self.model = model; self.capabilities = capabilities
        self.inputCostPerMillion = inputCostPerMillion; self.outputCostPerMillion = outputCostPerMillion
    }
    public static let defaults: [ProviderConfiguration] = [
        .init(id: "openai", name: "OpenAI", kind: .openAI, baseURL: "https://api.openai.com/v1"),
        .init(id: "anthropic", name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com/v1"),
        .init(id: "gemini", name: "Google Gemini", kind: .gemini, baseURL: "https://generativelanguage.googleapis.com/v1beta"),
        .init(id: "compatible", name: "Compatible endpoint", kind: .openAICompatible, baseURL: ""),
        .init(id: "ollama", name: "Local · Ollama", kind: .ollama, baseURL: "http://localhost:11434")
    ]
}
public struct VideoFrame: Sendable {
    public var timestamp: Double
    public var jpegData: Data
    public init(timestamp: Double, jpegData: Data) { self.timestamp = timestamp; self.jpegData = jpegData }
}
public struct UsageRecord: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var providerID: String
    public var model: String
    public var requestID: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var estimatedCost: Double?
    public var date: Date = Date()
    public init(providerID: String, model: String, requestID: String? = nil, inputTokens: Int = 0, outputTokens: Int = 0, estimatedCost: Double? = nil) {
        self.providerID = providerID; self.model = model; self.requestID = requestID; self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.estimatedCost = estimatedCost
    }
}
public struct AnalysisResult: Sendable {
    public var proposals: [ClipProposal]
    public var usage: [UsageRecord]
    public init(proposals: [ClipProposal], usage: [UsageRecord] = []) { self.proposals = proposals; self.usage = usage }
}
public enum TranscriptionEngine: String, Codable, CaseIterable, Sendable { case fluidAudio, whisperKit, importedTranscript }
public struct JobConfiguration: Codable, Sendable {
    public var preset: BatchPreset = .init()
    public var transcription: TranscriptionEngine = .fluidAudio
    public var transcriptionModel: String = ""
    public var editorial: ProviderConfiguration = ProviderConfiguration.defaults[4]
    public var visual: ProviderConfiguration?
    public var budgetUSD: Double = 1
    public var allowUnknownCost: Bool = false
    public var outputDirectory: URL
    public init(outputDirectory: URL) { self.outputDirectory = outputDirectory }
}
public enum JobStage: String, Codable, CaseIterable, Sendable {
    case ingest, probe, transcribe, select, analyze, render, verify, complete
    public var title: String {
        switch self { case .ingest: return "Importing"; case .probe: return "Reading media"; case .transcribe: return "Transcribing"; case .select: return "Finding moments"; case .analyze: return "Framing"; case .render: return "Rendering"; case .verify: return "Checking exports"; case .complete: return "Complete" }
    }
}
public enum JobState: String, Codable, CaseIterable, Sendable { case queued, running, paused, awaitingReview, failed, cancelled, completed, outcomeUnknown }
public struct JobCheckpoint: Codable, Identifiable, Sendable {
    public var id: UUID
    public var source: String
    public var title: String
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var state: JobState = .queued
    public var stage: JobStage = .ingest
    public var completedStages: [JobStage] = []
    public var progress: Double = 0
    public var message: String = "Ready when you are"
    public var error: String?
    public var configuration: JobConfiguration
    public var asset: MediaAsset?
    public var ingestedURL: URL?
    public var sourceFingerprint: String?
    public var audioURL: URL?
    public var transcript: TimedTranscript?
    public var speakerTrack: SpeakerTrack?
    public var clips: [ClipResult] = []
    public var usage: [UsageRecord] = []
    public var pendingRequest: Bool = false
    public var manuallyApproved: Bool = false
    public var visualAssessmentComplete: Bool = false
    public init(id: UUID = UUID(), source: String, configuration: JobConfiguration) {
        self.id = id; self.source = source; self.configuration = configuration
        self.title = URL(string: source)?.lastPathComponent.removingPercentEncoding ?? source
        if title.isEmpty { title = "Untitled source" }
    }
}

public struct AppSettings: Codable, Sendable {
    public var providers: [ProviderConfiguration] = ProviderConfiguration.defaults
    public var selectedProviderID: String = "ollama"
    public var visualProviderID: String?
    public var transcription: TranscriptionEngine = .fluidAudio
    public var transcriptionModel: String = ""
    public var preset: BatchPreset = .init()
    public var savedPresets: [BatchPreset] = BatchPreset.defaults
    public var outputDirectory: URL
    public var budgetUSD: Double = 1
    public var allowUnknownCost: Bool = false
    public var standingPrompt: String = ""
    public var revealWhenFinished: Bool = false
    public var soundWhenFinished: Bool = false
    public init(outputDirectory: URL) { self.outputDirectory = outputDirectory }
    public var jobConfiguration: JobConfiguration {
        var c = JobConfiguration(outputDirectory: outputDirectory)
        c.preset = preset; c.transcription = transcription; c.transcriptionModel = transcriptionModel
        c.preset.topic = [standingPrompt, preset.topic].filter { !$0.isEmpty }.joined(separator: "\n\n")
        c.editorial = providers.first { $0.id == selectedProviderID } ?? providers[0]
        c.visual = providers.first { $0.id == visualProviderID }
        c.budgetUSD = budgetUSD; c.allowUnknownCost = allowUnknownCost
        return c
    }
}

public enum EdwardError: LocalizedError, Sendable {
    case invalidInput(String), dependency(String), provider(String), budget(String), outcomeUnknown(String), media(String)
    public var errorDescription: String? {
        switch self { case .invalidInput(let m), .dependency(let m), .provider(let m), .budget(let m), .outcomeUnknown(let m), .media(let m): return m }
    }
}
