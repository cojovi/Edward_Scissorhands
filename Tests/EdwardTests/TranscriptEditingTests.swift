import XCTest
import EdwardDomain

final class TranscriptEditingTests: XCTestCase {
    func testEditingTightenedSentenceNeverRestoresRemovedGap() {
        let transcript = TimedTranscript(words: [.init(text: "A", start: 2, end: 3), .init(text: "complete", start: 5, end: 6), .init(text: "thought.", start: 6, end: 7)], engine: "fixture")
        let pieces = [TimeRange(start: 2, end: 3), .init(start: 5, end: 7)]
        let kept = TranscriptEditing.retainedRanges(originalPieces: pieces, sentences: transcript.sentences, selectedIDs: Set(transcript.sentences.map(\.id)), trim: .init(start: 0, end: 10))
        XCTAssertEqual(kept, pieces)
        let none = TranscriptEditing.retainedRanges(originalPieces: pieces, sentences: transcript.sentences, selectedIDs: [], trim: .init(start: 0, end: 10))
        XCTAssertTrue(none.isEmpty)
    }
    func testFillersRemovedWithoutDeletingUsefulWordsAndInvalidTrimRejected() {
        let transcript = TimedTranscript(words: [.init(text: "Useful", start: 0, end: 0.5), .init(text: "um", start: 0.6, end: 0.9), .init(text: "advice.", start: 1.1, end: 1.8)], engine: "fixture")
        let clip = ClipProposal(title: "Test", reason: "Fixture", start: 0, end: 2)
        let edited = TranscriptEditing.removingFillersAndPauses(from: clip, transcript: transcript)
        XCTAssertEqual(edited.ranges.count, 2)
        XCTAssertLessThan(edited.ranges[0].end, 0.6)
        XCTAssertGreaterThan(edited.ranges[1].start, 0.9)
        XCTAssertTrue(TranscriptEditing.retainedRanges(originalPieces: edited.ranges, sentences: transcript.sentences, selectedIDs: [0], trim: .init(start: .nan, end: 2)).isEmpty)
    }
}
