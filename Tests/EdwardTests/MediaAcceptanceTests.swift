import XCTest
@preconcurrency import AVFoundation
import EdwardDomain
@testable import EdwardMedia

final class MediaAcceptanceTests: XCTestCase {
    func testFourKScreenPreservationAndSilentVideo() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("4k.mp4")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=15:duration=1", "-c:v", "h264_videotoolbox", "-b:v", "6000000", source.path], in: directory)
        let engine = MediaEngine(), asset = try await MediaEngine().probe(url: source)
        XCTAssertEqual(asset.width, 3840); XCTAssertEqual(asset.height, 2160); XCTAssertFalse(asset.hasAudio)
        do { _ = try await engine.extractAudio(asset: asset, directory: directory); XCTFail("Silent media must not become a fake transcript") } catch {}
        let plan = renderPlan(source: source, output: directory.appendingPathComponent("screen.mp4"), ranges: [.init(start: 0, end: 1)])
        let rendered = try await engine.render(plan: plan, progress: { _ in })
        let output = try await engine.probe(url: rendered)
        XCTAssertEqual(output.width, 1080); XCTAssertEqual(output.height, 1920); XCTAssertFalse(output.hasAudio)
        let keys = try await engine.track(asset: asset, clip: plan.clip, transcript: plan.transcript)
        XCTAssertTrue(keys.allSatisfy(\.preserve), "Screen footage without faces must keep the full frame")
    }

    func testVariableFrameRateRangeUsesSourceTime() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("vfr.mp4")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=2", "-vf", "select=if(lt(t\\,1)\\,not(mod(n\\,5))\\,1)", "-fps_mode", "vfr", "-c:v", "h264_videotoolbox", source.path], in: directory)
        let native = AVURLAsset(url: source)
        let tracks = try await native.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        // Use a reader bound to the same asset as its track.
        let sourceReader = try AVAssetReader(asset: native)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        sourceReader.add(samples); XCTAssertTrue(sourceReader.startReading())
        var times: [Double] = []
        while let sample = samples.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if time.isFinite { times.append(time) }
        }
        times.sort()
        XCTAssertGreaterThan(times.count, 5)
        let intervals = zip(times, times.dropFirst()).map { Int((($1 - $0) * 1000).rounded()) }
        XCTAssertGreaterThan(Set(intervals).count, 1, "Fixture must actually contain variable presentation intervals")
        let engine = MediaEngine()
        let plan = renderPlan(source: source, output: directory.appendingPathComponent("recut.mp4"), ranges: [.init(start: 0.7, end: 1.7)])
        let rendered = try await engine.render(plan: plan, progress: { _ in })
        let output = try await engine.probe(url: rendered)
        XCTAssertEqual(output.duration, 1, accuracy: 0.1)
        XCTAssertEqual(output.frameRate, 30, accuracy: 0.1)
    }

    func testTwoHourSourceNearEndDoesNotShiftTimeline() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("two-hours.mp4")
        // 720 tiny frames encode two hours; the test exercises long timestamps without a large fixture.
        try await ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=64x64:r=1/10:d=7190", "-f", "lavfi", "-i", "color=c=blue:s=64x64:r=1/10:d=10", "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "35", source.path], in: directory)
        let engine = MediaEngine(), asset = try await MediaEngine().probe(url: source)
        XCTAssertEqual(asset.duration, 7200, accuracy: 0.1)
        let plan = renderPlan(source: source, output: directory.appendingPathComponent("last-five-seconds.mp4"), ranges: [.init(start: 7190, end: 7195)])
        let rendered = try await engine.render(plan: plan, progress: { _ in })
        let output = try await engine.probe(url: rendered)
        XCTAssertEqual(output.duration, 5, accuracy: 0.1)
        let words = MediaTimeline.editedWords([.init(text: "At the end.", start: 7191, end: 7192)], ranges: plan.clip.ranges)
        XCTAssertEqual(words[0].start, 1); XCTAssertEqual(words[0].end, 2)
    }

    func testCorruptedFileFailsWithoutCreatingOutput() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("corrupt.mp4")
        try Data("not a media container".utf8).write(to: source)
        do { _ = try await MediaEngine().probe(url: source); XCTFail("Corrupt source unexpectedly accepted") } catch {}
        let plan = renderPlan(source: source, output: directory.appendingPathComponent("output.mp4"), ranges: [.init(start: 0, end: 1)])
        do { _ = try await MediaEngine().render(plan: plan, progress: { _ in }); XCTFail("Corrupt source unexpectedly rendered") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.outputURL.path))
    }

    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edward-acceptance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func ffmpeg(_ arguments: [String], in directory: URL) async throws {
        guard let executable = MediaTools.executable("ffmpeg") else { throw XCTSkip("FFmpeg is required only for fixture generation") }
        _ = try await OwnedProcess().run(executable: executable, arguments: ["-hide_banner", "-loglevel", "error"] + arguments, directory: directory)
    }
    private func renderPlan(source: URL, output: URL, ranges: [TimeRange]) -> RenderPlan {
        var captions = CaptionStyle(); captions.enabled = false
        return .init(sourceURL: source, outputURL: output, clip: .init(title: "Acceptance", reason: "Synthetic fixture", ranges: ranges), transcript: .init(words: [], engine: "fixture"), canvas: .vertical, framing: .preserve, captions: captions)
    }
}
