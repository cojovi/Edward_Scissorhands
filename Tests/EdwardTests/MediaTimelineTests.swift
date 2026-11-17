import XCTest
import AVFoundation
import EdwardDomain
@testable import EdwardMedia

final class MediaTimelineTests: XCTestCase {
    func testDiscontiguousEditsMapWordsAndSourceClock() throws {
        let ranges = [TimeRange(start: 10, end: 12), .init(start: 20, end: 22)]
        let words = [TimedWord(text: "first", start: 9.8, end: 10.4), .init(text: "removed", start: 15, end: 16), .init(text: "second", start: 20.5, end: 21)]
        let edited = MediaTimeline.editedWords(words, ranges: ranges)
        XCTAssertEqual(edited.map(\.text), ["first", "second"])
        XCTAssertEqual(edited[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(edited[0].end, 0.4, accuracy: 0.001)
        XCTAssertEqual(edited[1].start, 2.5, accuracy: 0.001)
        XCTAssertEqual(MediaTimeline.sourceTime(at: 2.1, ranges: ranges), 20.1, accuracy: 0.001)
    }
    func testReorderedRangesRetainEditorialOrder() {
        let ranges = [TimeRange(start: 20, end: 22), .init(start: 1, end: 3)]
        XCTAssertEqual(MediaTimeline.sourceTime(at: 2.5, ranges: ranges), 1.5, accuracy: 0.001)
    }
    func testRejectsInvalidRanges() {
        XCTAssertThrowsError(try MediaTimeline.validate([.init(start: 1, end: .infinity)], duration: 5))
        XCTAssertThrowsError(try MediaTimeline.validate([.init(start: -1, end: 1)], duration: 5))
        XCTAssertThrowsError(try MediaTimeline.validate([.init(start: 1, end: 6)], duration: 5))
    }
    func testSRTImportPreservesCuesAndMarksInterpolation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edward-\(UUID()).srt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "1\r\n00:00:01,000 --> 00:00:03,000\r\nHello world.\r\n".write(to: url, atomically: true, encoding: .utf8)
        let result = try MediaTimeline.importTranscript(url: url)
        XCTAssertEqual(result.words.count, 2)
        XCTAssertEqual(result.words[0].start, 1)
        XCTAssertEqual(result.words[1].end, 3)
        XCTAssertTrue(result.engine.contains("interpolated"))
        XCTAssertTrue(MediaTimeline.srt(words: result.words).contains("00:00:01,000 --> 00:00:03,000"))
    }
    func testAmbiguousFaceFramePreservesCanvas() {
        let points = [CropKeyframe(time: 0, centerX: 0.2), .init(time: 1, centerX: 0.5, preserve: true)]
        XCTAssertTrue(EdwardVideoCompositor.cropPoint(at: 0.5, keyframes: points).preserve)
        XCTAssertTrue(EdwardVideoCompositor.cropPoint(at: 0.5, keyframes: []).preserve)
    }
    func testReorderedSentenceRecutKeepsSourceFraming() {
        var clip = ClipProposal(title: "Reordered", reason: "Source framing", start: 1, end: 22)
        clip.ranges = [.init(start: 20, end: 22), .init(start: 1, end: 3)]
        let plan = RenderPlan(sourceURL: URL(fileURLWithPath: "/tmp/source.mp4"), outputURL: URL(fileURLWithPath: "/tmp/output.mp4"), clip: clip,
                              transcript: .init(words: [], engine: "test"), cropKeyframes: [.init(time: 20, centerX: 0.8), .init(time: 21.999, centerX: 0.8), .init(time: 1, centerX: 0.2), .init(time: 2.999, centerX: 0.2)])
        let instruction = EdwardVideoInstruction(plan: plan, trackID: 1, duration: MediaTimeline.time(4), sourceSize: CGSize(width: 1920, height: 1080), transform: .identity)
        let first = EdwardVideoCompositor.cropPoint(at: MediaTimeline.sourceTime(at: 0.5, ranges: clip.ranges), keyframes: instruction.plan.cropKeyframes)
        let second = EdwardVideoCompositor.cropPoint(at: MediaTimeline.sourceTime(at: 2.5, ranges: clip.ranges), keyframes: instruction.plan.cropKeyframes)
        XCTAssertEqual(first.centerX, 0.8, accuracy: 0.001)
        XCTAssertEqual(second.centerX, 0.2, accuracy: 0.001)
    }
}
