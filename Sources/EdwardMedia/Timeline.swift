import Foundation
import CoreMedia
import EdwardDomain

/// All edits are quantized to a 60,000 Hz clock, retaining common video frame rates.
public enum MediaTimeline {
    public static let timescale: CMTimeScale = 60_000
    public static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }

    public static func validate(_ ranges: [TimeRange], duration: Double) throws {
        guard !ranges.isEmpty, duration.isFinite, duration > 0 else { throw EdwardError.invalidInput("The clip has no valid media range.") }
        for range in ranges {
            guard range.start.isFinite, range.end.isFinite, range.start >= 0, range.end > range.start,
                  range.end <= duration + 0.025 else { throw EdwardError.invalidInput("A clip range is outside the source video.") }
        }
    }

    public static func sourceTime(at output: Double, ranges: [TimeRange]) -> Double {
        var offset = 0.0
        for range in ranges {
            if output < offset + range.duration { return range.start + max(0, output - offset) }
            offset += range.duration
        }
        return ranges.last?.end ?? 0
    }

    public static func editedWords(_ words: [TimedWord], ranges: [TimeRange]) -> [TimedWord] {
        var offset = 0.0; var result: [TimedWord] = []
        for range in ranges {
            for word in words where word.start < range.end && word.end > range.start {
                var mapped = word
                mapped.start = offset + max(word.start, range.start) - range.start
                mapped.end = offset + min(word.end, range.end) - range.start
                if mapped.end > mapped.start { result.append(mapped) }
            }
            offset += range.duration
        }
        return result
    }

    public static func srt(words: [TimedWord], wordsPerCue: Int = 8) -> String {
        captionGroups(words, maximum: wordsPerCue).enumerated().map { index, group in
            "\(index + 1)\n\(stamp(group.first!.start)) --> \(stamp(group.last!.end))\n\(group.map(\.text).joined(separator: " "))\n"
        }.joined(separator: "\n")
    }

    static func captionGroups(_ words: [TimedWord], maximum: Int) -> [[TimedWord]] {
        var groups: [[TimedWord]] = []; var pending: [TimedWord] = []
        for word in words {
            if let last = pending.last, word.start - last.end > 0.75 || (last.speaker != word.speaker && word.speaker != nil) {
                groups.append(pending); pending = []
            }
            pending.append(word)
            if pending.count >= max(1, maximum) || word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!") {
                groups.append(pending); pending = []
            }
        }
        if !pending.isEmpty { groups.append(pending) }
        return groups
    }

    static func stamp(_ value: Double) -> String {
        let ms = max(0, Int((value * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    public static func importTranscript(url: URL) throws -> TimedTranscript {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "json" {
            let transcript = try JSONDecoder().decode(TimedTranscript.self, from: data)
            try validateWords(transcript.words)
            return transcript
        }
        guard let text = String(data: data, encoding: .utf8) else { throw EdwardError.invalidInput("The transcript must be UTF-8 SRT or Edward JSON.") }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var words: [TimedWord] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let pair = lines[index].components(separatedBy: "-->")
            guard pair.count == 2, let start = parseTimestamp(pair[0]), let end = parseTimestamp(pair[1]), end > start else {
                throw EdwardError.invalidInput("An SRT cue has an invalid time range.")
            }
            let tokens = lines.dropFirst(index + 1).joined(separator: " ").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).split(whereSeparator: \.isWhitespace)
            // SRT supplies cue timing, not word alignment; the engine label preserves that distinction.
            for (i, token) in tokens.enumerated() {
                let step = (end - start) / Double(max(1, tokens.count))
                words.append(.init(text: String(token), start: start + Double(i) * step, end: start + Double(i + 1) * step))
            }
        }
        try validateWords(words)
        return .init(words: words, engine: "Imported SRT · interpolated word timing")
    }

    static func parseTimestamp(_ value: String) -> Double? {
        let token = value.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]
        let bits = token.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        guard bits.count == 3, bits.allSatisfy({ $0.isFinite && $0 >= 0 }), bits[1] < 60, bits[2] < 60 else { return nil }
        return bits[0] * 3600 + bits[1] * 60 + bits[2]
    }

    static func validateWords(_ words: [TimedWord]) throws {
        guard !words.isEmpty, words.allSatisfy({ !$0.text.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else {
            throw EdwardError.invalidInput("The transcript has no usable timed words.")
        }
    }
}
