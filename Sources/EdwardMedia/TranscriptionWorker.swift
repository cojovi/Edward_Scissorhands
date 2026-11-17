import Foundation
import EdwardDomain

struct TranscriptionRequest: Codable {
    var audioURL: URL
    var engine: TranscriptionEngine
    var model: String
    var recognizeSpeakers: Bool
    var outputURL: URL
}

enum TranscriptionWorkerClient {
    static func transcribe(audioURL: URL, engine: TranscriptionEngine, model: String, recognizeSpeakers: Bool) async throws -> TimedTranscript {
        guard let worker = MediaTools.executable("EdwardMediaWorker") else {
            throw EdwardError.dependency("The local speech worker is missing. Build EdwardMediaWorker or reinstall the app.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("edward-transcribe-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("transcript.json")
        let request = TranscriptionRequest(audioURL: audioURL, engine: engine, model: model, recognizeSpeakers: recognizeSpeakers, outputURL: output)
        let input = folder.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: input, options: .atomic)
        _ = try await OwnedProcess().run(executable: worker, arguments: [input.path], directory: folder)
        try Task.checkCancellation()
        let transcript = try JSONDecoder().decode(TimedTranscript.self, from: Data(contentsOf: output))
        try MediaTimeline.validateWords(transcript.words)
        return transcript
    }
}

/// Entry point for the bundled helper; model loading and CoreML execution remain outside the UI process.
public enum LocalTranscriptionWorker {
    public static func run(requestURL: URL) async throws {
        let request = try JSONDecoder().decode(TranscriptionRequest.self, from: Data(contentsOf: requestURL))
        let transcript = try await LocalTranscriber.transcribe(audioURL: request.audioURL, engine: request.engine, model: request.model, recognizeSpeakers: request.recognizeSpeakers)
        try JSONEncoder().encode(transcript).write(to: request.outputURL, options: .atomic)
    }
}
