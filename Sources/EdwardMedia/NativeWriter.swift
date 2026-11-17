import Foundation
@preconcurrency import AVFoundation
import EdwardDomain

enum NativeWriter {
    static func write(_ composition: ComposedMedia, to url: URL, quality: VideoQuality, progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: composition.asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoTracks = try await composition.asset.loadTracks(withMediaType: .video)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition.videoComposition; output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EdwardError.media("Could not prepare the video decoder.") }
        reader.add(output)
        let size = composition.videoComposition.renderSize
        let bitrate = quality == .standard ? 5_000_000 : quality == .sharp ? 12_000_000 : 22_000_000
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 60],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EdwardError.media("The H.264 encoder is unavailable.") }
        writer.add(input)
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        let audioTracks = try await composition.asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let decoded = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            decoded.alwaysCopiesSampleData = false
            let encoded = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            encoded.expectsMediaDataInRealTime = false
            guard reader.canAdd(decoded), writer.canAdd(encoded) else { throw EdwardError.media("The AAC audio encoder is unavailable.") }
            reader.add(decoded); writer.add(encoded); audioOutput = decoded; audioInput = encoded
        }
        let duration = try await composition.asset.load(.duration)
        try await withTaskCancellationHandler {
            guard writer.startWriting() else { throw writer.error ?? EdwardError.media("Could not start writing the export.") }
            writer.startSession(atSourceTime: .zero)
            guard reader.startReading() else { throw reader.error ?? EdwardError.media("Could not decode the source media.") }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await pump(output: output, input: input, reader: reader, writer: writer, duration: duration.seconds, progress: progress) }
                    if let audioOutput, let audioInput {
                        group.addTask { try await pump(output: audioOutput, input: audioInput, reader: reader, writer: writer, duration: duration.seconds, progress: nil) }
                    }
                    try await group.waitForAll()
                }
                try Task.checkCancellation()
                guard reader.status == .completed else { throw reader.error ?? EdwardError.media("The video decoder stopped before the export completed.") }
                writer.endSession(atSourceTime: duration)
                await writer.finishWriting()
                guard writer.status == .completed else { throw writer.error ?? EdwardError.media("The video encoder did not finish writing.") }
            } catch { reader.cancelReading(); writer.cancelWriting(); throw error }
        } onCancel: { reader.cancelReading(); writer.cancelWriting() }
    }

    private static func pump(output: AVAssetReaderOutput, input: AVAssetWriterInput, reader: AVAssetReader, writer: AVAssetWriter, duration: Double, progress: (@Sendable (Double) -> Void)?) async throws {
        defer { input.markAsFinished() }
        while true {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? EdwardError.media("The encoder stopped accepting frames.") }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed { throw reader.error ?? EdwardError.media("The source could not be decoded.") }
                return
            }
            guard input.append(sample) else { throw writer.error ?? EdwardError.media("Could not write the next media frame.") }
            if let progress { progress(min(0.99, max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))) }
        }
    }
}
