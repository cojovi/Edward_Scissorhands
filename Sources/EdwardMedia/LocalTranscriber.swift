import Foundation
import FluidAudio
import WhisperKit
import EdwardDomain

enum LocalTranscriber {
    static func transcribe(audioURL: URL, engine: TranscriptionEngine, model: String, recognizeSpeakers: Bool = true) async throws -> TimedTranscript {
        try Task.checkCancellation()
        if engine == .importedTranscript { return try MediaTimeline.importTranscript(url: audioURL) }
        var transcript: TimedTranscript
        switch engine {
        case .fluidAudio:
            let requested = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard requested.isEmpty || ["v2", "v3", "parakeet-v2", "parakeet-v3"].contains(requested.lowercased()) || requested.hasPrefix("/") else {
                throw EdwardError.invalidInput("FluidAudio model must be v2, v3, or an absolute folder containing compatible Parakeet CoreML models.")
            }
            let version: AsrModelVersion = requested.lowercased().hasSuffix("v2") ? .v2 : .v3
            let manager = AsrManager()
            do {
                let models = requested.hasPrefix("/")
                    ? try await AsrModels.load(from: URL(fileURLWithPath: requested), version: version)
                    : try await AsrModels.downloadAndLoad(version: version)
                try Task.checkCancellation()
                try await manager.loadModels(models)
                var state = try TdtDecoderState()
                let result = try await manager.transcribeDiskBacked(audioURL, decoderState: &state)
                let words = buildWordTimings(from: result.tokenTimings ?? []).map {
                    TimedWord(text: $0.word, start: $0.startTime, end: max($0.startTime + 0.01, $0.endTime))
                }
                transcript = .init(words: words, language: version == .v2 ? "en" : "auto", engine: "FluidAudio Parakeet \(version == .v2 ? "v2" : "v3")")
                await manager.cleanup()
            } catch {
                await manager.cleanup()
                throw error
            }
        case .whisperKit:
            let requested = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let config = WhisperKitConfig(model: requested.isEmpty ? "openai_whisper-large-v3_turbo" : requested, verbose: false, prewarm: false, load: true, download: true)
            let whisper = try await WhisperKit(config)
            do {
                let options = DecodingOptions(verbose: false, skipSpecialTokens: true, wordTimestamps: true, concurrentWorkerCount: 1)
                let result = try await whisper.transcribe(audioPath: audioURL.path,
                    audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental(chunkDurationSeconds: 300, maxBufferedChunks: 1)), decodeOptions: options)
                let words = result.flatMap(\.segments).flatMap { $0.words ?? [] }.map {
                    TimedWord(text: $0.word.trimmingCharacters(in: .whitespacesAndNewlines), start: Double($0.start), end: max(Double($0.start) + 0.01, Double($0.end)))
                }.filter { !$0.text.isEmpty }
                transcript = .init(words: words, language: result.first?.language ?? "auto", engine: "WhisperKit \(requested.isEmpty ? "large-v3-turbo" : requested)")
                await whisper.unloadModels()
            } catch {
                await whisper.unloadModels(); throw error
            }
        case .importedTranscript: throw EdwardError.invalidInput("Choose a transcript file to import.")
        }
        try Task.checkCancellation()
        try MediaTimeline.validateWords(transcript.words)
        guard recognizeSpeakers else { return transcript }
        // ASR weights are unloaded before diarization so the two models do not compete for memory.
        return try await attachSpeakers(to: transcript) {
            let diarizer = OfflineDiarizerManager()
            try await diarizer.prepareModels()
            let result = try await diarizer.process(audioURL)
            return result.segments.map { SpeakerInterval(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        }
    }

    static func attachSpeakers(to original: TimedTranscript, recognition: () async throws -> [SpeakerInterval]) async throws -> TimedTranscript {
        var transcript = original
        do {
            let intervals = try await recognition()
            try Task.checkCancellation()
            for i in transcript.words.indices {
                let word = transcript.words[i]
                let match = intervals.max { a, b in
                    func overlap(_ segment: SpeakerInterval) -> Double {
                        max(0, min(word.end, segment.end) - max(word.start, segment.start))
                    }
                    return overlap(a) < overlap(b)
                }
                if let match, match.end > word.start, match.start < word.end {
                    transcript.words[i].speaker = match.speaker
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // Speaker analysis is optional enrichment; retain a successful, usable ASR result.
            transcript.engine += " · speaker recognition unavailable"
        }
        return transcript
    }
}
