import Foundation
@preconcurrency import AVFoundation
import Vision
import EdwardDomain

/// Conservative audio/visual association. Ambiguous or off-screen speech keeps the complete frame.
enum SpeakerFraming {
    struct Face {
        let box: CGRect
        let mouthOpening: Double?
        var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
    }
    static func track(asset: MediaAsset, clip: ClipProposal, transcript: TimedTranscript) async throws -> [CropKeyframe] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var result: [CropKeyframe] = []
        var speakerLocations: [String: CGPoint] = [:]
        var previousFaces: [Face] = []
        var previousCenter: CGPoint?
        for range in clip.ranges {
            // A sentence recut may jump to an unrelated camera shot at the same face positions.
            speakerLocations.removeAll(); previousFaces.removeAll()
            previousCenter = nil
            for time in stride(from: range.start, to: min(range.end, asset.duration), by: 0.75) {
                try Task.checkCancellation()
                let central = try await faces(generator: generator, time: time)
                if central.count != previousFaces.count || central.contains(where: { face in !previousFaces.contains(where: { distance(face.center, $0.center) < 0.18 }) }) {
                    speakerLocations.removeAll()
                }
                previousFaces = central
                let speaker = transcript.words.first(where: { $0.start <= time && $0.end >= time })?.speaker
                var chosen: Face?
                if central.count == 1 {
                    chosen = central[0]
                } else if central.count > 1 {
                    let before = try await faces(generator: generator, time: max(range.start, time - 0.16))
                    let after = try await faces(generator: generator, time: min(asset.duration - 0.02, min(range.end - 0.02, time + 0.16)))
                    let scores = central.compactMap { face -> (Face, Double)? in
                        guard let mouth = face.mouthOpening,
                              let a = nearest(face, in: before)?.mouthOpening,
                              let b = nearest(face, in: after)?.mouthOpening else { return nil }
                        return (face, abs(mouth - a) + abs(b - mouth))
                    }.sorted { $0.1 > $1.1 }
                    // A changing mouth is evidence of articulation, but only strong separation is usable.
                    if let top = scores.first, top.1 > 0.045, top.1 > (scores.dropFirst().first?.1 ?? 0) * 1.8, speaker != nil {
                        chosen = top.0
                        speakerLocations[speaker!] = top.0.center
                    } else if let speaker, let location = speakerLocations[speaker],
                              let known = central.min(by: { distance($0.center, location) < distance($1.center, location) }), distance(known.center, location) < 0.10 {
                        chosen = known
                    }
                }
                if let chosen {
                    let target = chosen.center
                    let center: CGPoint
                    if let last = previousCenter, distance(last, target) < 0.25 {
                        center = CGPoint(x: last.x * 0.25 + target.x * 0.75, y: last.y * 0.25 + target.y * 0.75)
                    } else { center = target }
                    result.append(.init(time: time, centerX: center.x, centerY: center.y))
                    previousCenter = center
                } else {
                    result.append(.init(time: time, centerX: 0.5, preserve: true)); previousCenter = nil
                }
            }
            // Hold the final framing to this range's end rather than panning across a deleted gap.
            if let final = result.last, final.time >= range.start {
                result.append(.init(time: max(final.time, min(range.end, asset.duration) - 0.001), centerX: final.centerX, centerY: final.centerY, preserve: final.preserve))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    static func faces(generator: AVAssetImageGenerator, time: Double) async throws -> [Face] {
        let image = try await generator.image(at: MediaTimeline.time(max(0, time))).image
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).map { observation in
            var ratio: Double?
            if let mouth = observation.landmarks?.innerLips, mouth.pointCount > 2 {
                let points = mouth.normalizedPoints
                let xs = points.map(\.x); let ys = points.map(\.y)
                if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(), maxX > minX {
                    ratio = Double((maxY - minY) / (maxX - minX))
                }
            }
            return Face(box: observation.boundingBox, mouthOpening: ratio)
        }
    }
    static func nearest(_ face: Face, in others: [Face]) -> Face? {
        guard let match = others.min(by: { distance(face.center, $0.center) < distance(face.center, $1.center) }), distance(face.center, match.center) < 0.12 else { return nil }
        return match
    }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}
