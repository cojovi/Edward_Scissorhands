import Foundation
@preconcurrency import AVFoundation
import Vision
import ImageIO
import UniformTypeIdentifiers
import EdwardDomain

public actor MediaEngine {
    public init() {}

    public func ingest(source: String, directory: URL, quality: VideoQuality = .sharp) async throws -> URL {
        try Task.checkCancellation()
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") || text.hasPrefix("~") {
            let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw EdwardError.invalidInput("The source file cannot be read.") }
            return url
        }
        guard let url = URL(string: text) else { throw EdwardError.invalidInput("Choose a local file or a valid HTTP video URL.") }
        if url.isFileURL {
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw EdwardError.invalidInput("The source file cannot be read.") }
            return url
        }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw EdwardError.invalidInput("Only HTTP(S) video URLs are supported.")
        }
        guard let downloader = MediaTools.executable("yt-dlp") else {
            throw EdwardError.dependency("The video downloader is missing. Run scripts/media-tools.sh, or reinstall the packaged app.")
        }
        let staging = directory.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: staging) } }
        // Download separate MP4/AAC tracks, then mux with AVFoundation. No merger subprocess is needed.
        let limit = quality == .standard ? "[height<=?720]" : quality == .sharp ? "[height<=?1080]" : ""
        var args = ["--ignore-config", "--no-playlist", "--no-progress", "--no-warnings", "--no-overwrites", "--restrict-filenames", "--socket-timeout", "30", "--retries", "3", "--fixup", "never", "--format", "bv[ext=mp4][vcodec^=avc1]\(limit)/bv[ext=mp4]\(limit)/best[ext=mp4]\(limit),ba[ext=m4a]/best[ext=mp4]\(limit)", "--print", "after_move:filepath", "--output", "source.%(format_id)s.%(ext)s"]
        if let qjs = MediaTools.executable("qjs") { args += ["--js-runtimes", "quickjs:\(qjs.path)"] }
        args += ["--", url.absoluteString]
        let output = try await OwnedProcess().run(executable: downloader, arguments: args, directory: staging)
        let paths = output.split(separator: "\n").map { line -> URL in
            let path = String(line)
            return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : staging.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
        }
        guard !paths.isEmpty, paths.allSatisfy({ $0.path.hasPrefix(staging.standardizedFileURL.path + "/") && FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw EdwardError.media("The downloaded media could not be found in the job folder.")
        }
        let downloaded = try await NativeDownloader.merge(paths, directory: staging)
        succeeded = true
        return downloaded
    }

    public func probe(url: URL) async throws -> MediaAsset {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw EdwardError.media("This file does not contain a playable video track.")
        }
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let rate = try await video.load(.nominalFrameRate)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        return .init(url: url, title: url.deletingPathExtension().lastPathComponent, duration: duration,
                     width: Int(abs(bounds.width).rounded()), height: Int(abs(bounds.height).rounded()), frameRate: Double(rate > 0 ? rate : 30), hasAudio: hasAudio)
    }

    public func extractAudio(asset: MediaAsset, directory: URL) async throws -> URL {
        guard asset.hasAudio else { throw EdwardError.media("This video has no audio track to transcribe.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("audio.m4a")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let temporary = directory.appendingPathComponent("audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = AVURLAsset(url: asset.url)
        guard let session = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetAppleM4A) else {
            throw EdwardError.media("Could not create the audio extraction session.")
        }
        session.outputURL = temporary; session.outputFileType = .m4a
        try await runExport(session)
        try FileManager.default.moveItem(at: temporary, to: output)
        return output
    }

    public func transcribe(audioURL: URL, engine: TranscriptionEngine, model: String, recognizeSpeakers: Bool = true) async throws -> TimedTranscript {
        if engine == .importedTranscript { return try MediaTimeline.importTranscript(url: audioURL) }
        return try await TranscriptionWorkerClient.transcribe(audioURL: audioURL, engine: engine, model: model, recognizeSpeakers: recognizeSpeakers)
    }

    public func importTranscript(url: URL) throws -> TimedTranscript { try MediaTimeline.importTranscript(url: url) }

    public func frames(asset: MediaAsset, times: [Double]) async throws -> [VideoFrame] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        var frames: [VideoFrame] = []
        for time in times {
            try Task.checkCancellation()
            guard time.isFinite, time >= 0, time < asset.duration else { continue }
            let image = try await generator.image(at: MediaTimeline.time(time))
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw EdwardError.media("Could not encode a video frame.") }
            CGImageDestinationAddImage(destination, image.image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw EdwardError.media("Could not encode a video frame.") }
            frames.append(.init(timestamp: image.actualTime.seconds, jpegData: data as Data))
        }
        return frames
    }

    public func track(asset: MediaAsset, clip: ClipProposal, transcript: TimedTranscript) async throws -> [CropKeyframe] {
        try await SpeakerFraming.track(asset: asset, clip: clip, transcript: transcript)
    }

    public func preview(plan: RenderPlan) async throws -> AVPlayerItem {
        let composed = try await NativeRenderer.compose(plan)
        return await MainActor.run {
            let item = AVPlayerItem(asset: composed.asset)
            item.videoComposition = composed.videoComposition
            return item
        }
    }

    public func render(plan: RenderPlan, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        let parent = plan.outputURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: plan.outputURL.path) else { throw EdwardError.media("An export already exists at \(plan.outputURL.lastPathComponent). Choose a new filename.") }
        let values = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < Int64(max(50_000_000, plan.clip.duration * 2_000_000)) {
            throw EdwardError.media("There is not enough free space to render this clip.")
        }
        let temporary = parent.appendingPathComponent(".\(UUID().uuidString).mp4")
        let temporarySRT = parent.appendingPathComponent(".\(UUID().uuidString).srt")
        let srtURL = plan.outputURL.deletingPathExtension().appendingPathExtension("srt")
        guard !fm.fileExists(atPath: srtURL.path) else { throw EdwardError.media("A subtitle file already exists at \(srtURL.lastPathComponent). Choose a new filename.") }
        defer { try? fm.removeItem(at: temporary); try? fm.removeItem(at: temporarySRT) }
        let composed = try await NativeRenderer.compose(plan)
        try await NativeWriter.write(composed, to: temporary, quality: plan.quality, progress: progress)
        try await verify(url: temporary, expectedDuration: plan.clip.duration)
        try Task.checkCancellation()
        let words = MediaTimeline.editedWords(plan.transcript.words, ranges: plan.clip.ranges)
        let subtitles = MediaTimeline.srt(words: words, wordsPerCue: max(1, plan.captions.wordsPerLine * 2))
        // Each artifact is written atomically; the final video name is published only after verification.
        try subtitles.write(to: temporarySRT, atomically: true, encoding: .utf8)
        try fm.moveItem(at: temporarySRT, to: srtURL)
        do { try fm.moveItem(at: temporary, to: plan.outputURL) }
        catch { try? fm.removeItem(at: srtURL); throw error }
        progress(1)
        return plan.outputURL
    }

    public func verify(url: URL, expectedDuration: Double) async throws {
        let asset = try await probe(url: url)
        guard abs(asset.duration - expectedDuration) <= max(0.15, 2 / max(1, asset.frameRate)), asset.width > 0, asset.height > 0 else {
            throw EdwardError.media("Export validation failed: the video duration or dimensions are incorrect.")
        }
        let samples = try await frames(asset: asset, times: [0, max(0, asset.duration / 2), max(0, asset.duration - 0.1)])
        guard samples.count == 3 else { throw EdwardError.media("Export validation failed: video frames cannot be decoded.") }
        let nativeAsset = AVURLAsset(url: url)
        if let audio = try await nativeAsset.loadTracks(withMediaType: .audio).first {
            let reader = try AVAssetReader(asset: nativeAsset)
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            guard reader.canAdd(output) else { throw EdwardError.media("Export validation failed: the audio track cannot be decoded.") }
            reader.add(output)
            guard reader.startReading(), let sample = output.copyNextSampleBuffer(), CMSampleBufferGetNumSamples(sample) > 0 else {
                throw reader.error ?? EdwardError.media("Export validation failed: the audio track is empty.")
            }
            reader.cancelReading()
        }
    }
}

func runExport(_ session: AVAssetExportSession) async throws {
    try await withTaskCancellationHandler {
        try Task.checkCancellation()
        await session.export()
        try Task.checkCancellation()
        guard session.status == .completed else { throw session.error ?? EdwardError.media("The media export did not complete.") }
    } onCancel: { session.cancelExport() }
}
