import Foundation

public enum TranscriptEditing {
    public static func retainedRanges(originalPieces: [TimeRange], sentences: [TimedSentence], selectedIDs: Set<Int>, trim: TimeRange) -> [TimeRange] {
        guard trim.start.isFinite, trim.end.isFinite, trim.start >= 0, trim.end > trim.start else { return [] }
        return merged(sentences.filter { selectedIDs.contains($0.id) }.flatMap { sentence in
            originalPieces.compactMap { piece in
                let start = max(trim.start, sentence.range.start, piece.start)
                let end = min(trim.end, sentence.range.end, piece.end)
                return end > start ? TimeRange(start: start, end: end) : nil
            }
        })
    }
    public static func validate(_ transcript: TimedTranscript, duration: Double) throws {
        guard !transcript.words.isEmpty else { throw EdwardError.invalidInput("No speech was found. Import a timed transcript or choose a different source.") }
        var previous = -Double.infinity
        for word in transcript.words {
            guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end > word.start,
                  word.end <= duration + 0.2, word.start >= previous, !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EdwardError.invalidInput("The transcript contains invalid or out-of-order timestamps.")
            }
            previous = word.start
        }
    }
    public static func removingFillersAndPauses(from clip: ClipProposal, transcript: TimedTranscript) -> ClipProposal {
        let fillers: Set<String> = ["um", "uh", "umm", "uhh", "erm", "er"]
        var ranges: [TimeRange] = []
        for source in clip.ranges {
            let words = transcript.words.filter { $0.start >= source.start - 0.05 && $0.end <= source.end + 0.05 }
            var current: TimeRange?
            for word in words {
                let token = word.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
                if fillers.contains(token) {
                    if let c = current { ranges.append(c); current = nil }
                    continue
                }
                let padded = TimeRange(start: max(source.start, word.start - 0.06), end: min(source.end, word.end + 0.08))
                if let c = current, padded.start - c.end <= 0.55 {
                    current = .init(start: c.start, end: max(c.end, padded.end))
                } else {
                    if let c = current { ranges.append(c) }; current = padded
                }
            }
            if let c = current { ranges.append(c) }
        }
        var result = clip
        result.ranges = merged(ranges)
        return result
    }
    public static func merged(_ ranges: [TimeRange]) -> [TimeRange] {
        var result: [TimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) where range.duration > 0 {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = max(last.end, range.end)
            } else { result.append(range) }
        }
        return result
    }
    public static func importFile(_ url: URL) throws -> TimedTranscript {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "json" { return try JSONDecoder().decode(TimedTranscript.self, from: data) }
        guard let text = String(data: data, encoding: .utf8) else { throw EdwardError.invalidInput("Transcript must be UTF-8 JSON or SRT.") }
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        var words: [TimedWord] = []
        func seconds(_ raw: String) -> Double? {
            let values = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
            guard values.count == 3 else { return nil }
            return values[0] * 3600 + values[1] * 60 + values[2]
        }
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let bounds = lines[i].components(separatedBy: "-->")
            guard bounds.count == 2, let start = seconds(bounds[0]), let end = seconds(bounds[1]), start >= 0, end > start else { throw EdwardError.invalidInput("Invalid SRT timestamp.") }
            let tokens = lines.dropFirst(i + 1).joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            // SRT has cue timing only; interpolation is explicitly identified in engine metadata.
            let step = (end - start) / Double(tokens.count)
            words += tokens.enumerated().map { .init(text: $0.element, start: start + Double($0.offset) * step, end: start + Double($0.offset + 1) * step) }
        }
        guard !words.isEmpty else { throw EdwardError.invalidInput("No timed cues found in this transcript.") }
        return .init(words: words.sorted { $0.start < $1.start }, engine: "Imported SRT · interpolated word timing")
    }
}
