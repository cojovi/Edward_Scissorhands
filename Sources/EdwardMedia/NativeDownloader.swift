import Foundation
@preconcurrency import AVFoundation
import EdwardDomain

enum NativeDownloader {
    static func merge(_ urls: [URL], directory: URL) async throws -> URL {
        var sourceVideo: AVAssetTrack?
        var sourceAudio: AVAssetTrack?
        var videoURL: URL?
        var retainedAssets: [AVURLAsset] = []
        defer { withExtendedLifetime(retainedAssets) {} }
        for url in Array(Set(urls)).sorted(by: { $0.path < $1.path }) {
            let asset = AVURLAsset(url: url)
            retainedAssets.append(asset)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            if let video = videos.first {
                sourceVideo = video; videoURL = url
                if !audios.isEmpty { return url }
            }
            if let audio = audios.first { sourceAudio = audio }
        }
        guard let video = sourceVideo, let videoURL else { throw EdwardError.media("The link did not produce a supported MP4 video.") }
        guard let audio = sourceAudio else { return videoURL }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EdwardError.media("Could not combine the downloaded video and audio.")
        }
        let videoRange = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        try videoTrack.insertTimeRange(videoRange, of: video, at: .zero)
        videoTrack.preferredTransform = try await video.load(.preferredTransform)
        let overlap = CMTimeRangeGetIntersection(audioRange, otherRange: videoRange)
        if overlap.duration > .zero { try audioTrack.insertTimeRange(overlap, of: audio, at: overlap.start - videoRange.start) }
        let output = directory.appendingPathComponent("source.mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw EdwardError.media("Could not prepare the downloaded video for playback.")
        }
        exporter.outputURL = output; exporter.outputFileType = .mp4
        try await runExport(exporter)
        // Keep source tracks in the job cache until the user clears it; failed muxes never destroy downloads.
        return output
    }
}
