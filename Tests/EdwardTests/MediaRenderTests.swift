import XCTest
@preconcurrency import AVFoundation
import CoreImage
import EdwardDomain
@testable import EdwardMedia

final class MediaRenderTests: XCTestCase {
    func testURLIngestionThroughPinnedDownloader() async throws {
        guard MediaTools.executable("yt-dlp") != nil else { throw XCTSkip("Run scripts/media-tools.sh for downloader integration tests") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edward-url-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await fixture(in: directory)
        let server = Process()
        let portFile = directory.appendingPathComponent("server-port.txt")
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", "import http.server,os,sys,pathlib; os.chdir(sys.argv[1]); s=http.server.HTTPServer(('127.0.0.1',0),http.server.SimpleHTTPRequestHandler); pathlib.Path(sys.argv[2]).write_text(str(s.server_address[1])); s.serve_forever()", directory.path, portFile.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        server.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let port = try XCTUnwrap(Int(try String(contentsOf: portFile, encoding: .utf8)))
        let engine = MediaEngine()
        let downloaded = try await engine.ingest(source: "http://127.0.0.1:\(port)/\(fixture.lastPathComponent)", directory: directory.appendingPathComponent("job"))
        let media = try await engine.probe(url: downloaded)
        XCTAssertTrue(media.hasAudio); XCTAssertEqual(media.duration, 4, accuracy: 0.1)
        XCTAssertTrue(downloaded.path.contains("download-"))
    }
    func testIndependentDownloadedTracksMuxWithoutReencoding() async throws {
        guard let ffmpeg = MediaTools.executable("ffmpeg") else { throw XCTSkip("FFmpeg fixture generator unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edward-mux-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await fixture(in: directory)
        let video = directory.appendingPathComponent("video-only.mp4")
        _ = try await OwnedProcess().run(executable: ffmpeg, arguments: ["-loglevel", "error", "-i", original.path, "-an", "-c:v", "copy", video.path], directory: directory)
        let engine = MediaEngine(), asset = try await MediaEngine().probe(url: original)
        let audio = try await engine.extractAudio(asset: asset, directory: directory)
        let combined = try await NativeDownloader.merge([video, audio], directory: directory)
        let result = try await engine.probe(url: combined)
        XCTAssertTrue(result.hasAudio); XCTAssertEqual(result.duration, asset.duration, accuracy: 0.1)
        XCTAssertEqual(result.width, asset.width); XCTAssertEqual(result.height, asset.height)
    }
    func testRotatedSourceMatchesNativePreviewOrientation() async throws {
        guard let ffmpeg = MediaTools.executable("ffmpeg") else { throw XCTSkip("FFmpeg fixture generator unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edward-rotate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("raw.mp4"), rotated = directory.appendingPathComponent("rotated.mp4")
        _ = try await OwnedProcess().run(executable: ffmpeg, arguments: ["-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=320x360:r=30:d=1", "-f", "lavfi", "-i", "color=c=blue:s=320x360:r=30:d=1", "-filter_complex", "hstack=inputs=2", "-c:v", "h264_videotoolbox", raw.path], directory: directory)
        _ = try await OwnedProcess().run(executable: ffmpeg, arguments: ["-loglevel", "error", "-display_rotation", "90", "-i", raw.path, "-c", "copy", rotated.path], directory: directory)
        let engine = MediaEngine(), asset = try await MediaEngine().probe(url: rotated)
        XCTAssertEqual(asset.width, 360); XCTAssertEqual(asset.height, 640)
        var style = CaptionStyle(); style.enabled = false
        let plan = RenderPlan(sourceURL: rotated, outputURL: directory.appendingPathComponent("render.mp4"), clip: .init(title: "Rotation", reason: "Fixture", start: 0, end: 1), transcript: .init(words: [], engine: "fixture"), canvas: .vertical, framing: .preserve, captions: style)
        let output = try await engine.render(plan: plan, progress: { _ in })
        let rendered = try await engine.probe(url: output)
        let reference = try await engine.frames(asset: asset, times: [0.4])
        let actual = try await engine.frames(asset: rendered, times: [0.4])
        for y in [0.25, 0.75] {
            let expected = try averageCenter(reference[0].jpegData, y: y)
            let observed = try averageCenter(actual[0].jpegData, y: y)
            XCTAssertEqual(expected.0 > expected.2, observed.0 > observed.2, "Rotation must preserve the spatial ordering of red and blue halves")
            XCTAssertEqual(max(expected.0, expected.2), max(observed.0, observed.2), accuracy: 30)
        }
    }
    func testNativeRenderRecutsAudioVideoAndCaptions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edward-render-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await fixture(in: directory)
        let engine = MediaEngine()
        let asset = try await engine.probe(url: source)
        XCTAssertEqual(asset.width, 640); XCTAssertEqual(asset.height, 360); XCTAssertTrue(asset.hasAudio)
        let audio = try await engine.extractAudio(asset: asset, directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        var style = CaptionStyle(); style.fontSize = 60; style.bottomInset = 100
        let transcript = TimedTranscript(words: [.init(text: "Blue first.", start: 2, end: 3, speaker: "speaker_0"), .init(text: "Red second.", start: 0, end: 1, speaker: "speaker_1")], engine: "Test fixture")
        let clip = ClipProposal(title: "Ordered edit", reason: "Fixture", ranges: [.init(start: 2, end: 3), .init(start: 0.25, end: 0.75)])
        let destination = directory.appendingPathComponent("result.mp4")
        let plan = RenderPlan(sourceURL: source, outputURL: destination, clip: clip, transcript: transcript, canvas: .square, framing: .preserve, captions: style)
        let output = try await engine.render(plan: plan, progress: { _ in })
        let result = try await engine.probe(url: output)
        XCTAssertEqual(result.duration, 1.5, accuracy: 0.1)
        XCTAssertEqual(result.width, 1080); XCTAssertEqual(result.height, 1080); XCTAssertTrue(result.hasAudio)
        let srt = try String(contentsOf: output.deletingPathExtension().appendingPathExtension("srt"), encoding: .utf8)
        XCTAssertTrue(srt.contains("Blue first.")); XCTAssertTrue(srt.contains("00:00:01,000 --> 00:00:01,500"))
        let frames = try await engine.frames(asset: result, times: [0.4, 1.2])
        let first = try averageCenter(frames[0].jpegData), second = try averageCenter(frames[1].jpegData)
        XCTAssertGreaterThan(first.2, first.0 * 2, "First recut must use the blue source range")
        XCTAssertGreaterThan(second.0, second.2 * 2, "Second recut must use the red source range")
        let player = try await engine.preview(plan: plan)
        let hasComposition = await MainActor.run { player.videoComposition != nil }
        XCTAssertTrue(hasComposition)
    }

    func testCancellationDoesNotPublishPartialVideo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edward-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await fixture(in: directory)
        let output = directory.appendingPathComponent("cancelled.mp4")
        let plan = RenderPlan(sourceURL: source, outputURL: output, clip: .init(title: "Cancel", reason: "Fixture", start: 0, end: 4), transcript: .init(words: [], engine: "fixture"))
        let task = Task { try await MediaEngine().render(plan: plan, progress: { _ in }) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled render unexpectedly completed") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    private func fixture(in directory: URL) async throws -> URL {
        guard let ffmpeg = MediaTools.executable("ffmpeg") else { throw XCTSkip("FFmpeg is used only to create this synthetic test fixture.") }
        let output = directory.appendingPathComponent("fixture.mp4")
        _ = try await OwnedProcess().run(executable: ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=640x360:r=30:d=2", "-f", "lavfi", "-i", "color=c=blue:s=640x360:r=30:d=2", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4", "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]", "-map", "2:a", "-c:v", "h264_videotoolbox", "-c:a", "aac", "-t", "4", output.path], directory: directory)
        return output
    }
    private func averageCenter(_ data: Data, y: Double = 0.5) throws -> (Double, Double, Double) {
        let image = try XCTUnwrap(CIImage(data: data))
        let center = CGRect(x: image.extent.midX - 10, y: image.extent.height * y - 10, width: 20, height: 20)
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: center)])
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext().render(average, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(bytes[0]), Double(bytes[1]), Double(bytes[2]))
    }
}
