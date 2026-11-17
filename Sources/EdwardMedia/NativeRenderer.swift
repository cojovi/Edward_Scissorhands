import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreText
import EdwardDomain

struct ComposedMedia: @unchecked Sendable {
    let asset: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
}

enum NativeRenderer {
    static func compose(_ plan: RenderPlan) async throws -> ComposedMedia {
        let source = AVURLAsset(url: plan.sourceURL)
        let duration = try await source.load(.duration).seconds
        try MediaTimeline.validate(plan.clip.ranges, duration: duration)
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else { throw EdwardError.media("The source video track is missing.") }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw EdwardError.media("Could not allocate a video track.") }
        let sourceAudio = try await source.loadTracks(withMediaType: .audio).first
        let audio = sourceAudio.flatMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        let audioRange = try await sourceAudio?.load(.timeRange)
        var cursor = CMTime.zero
        for range in plan.clip.ranges {
            try Task.checkCancellation()
            let sourceRange = CMTimeRange(start: MediaTimeline.time(range.start), end: MediaTimeline.time(min(range.end, duration)))
            try video.insertTimeRange(sourceRange, of: sourceVideo, at: cursor)
            if let sourceAudio, let audio, let audioRange {
                let overlap = CMTimeRangeGetIntersection(sourceRange, otherRange: audioRange)
                if overlap.isValid, overlap.duration > .zero {
                    try audio.insertTimeRange(overlap, of: sourceAudio, at: cursor + overlap.start - sourceRange.start)
                }
            }
            cursor = cursor + sourceRange.duration
        }
        let sourceSize = try await sourceVideo.load(.naturalSize)
        let transform = try await sourceVideo.load(.preferredTransform)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = EdwardVideoCompositor.self
        videoComposition.renderSize = CGSize(width: plan.canvas.width, height: plan.canvas.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = [EdwardVideoInstruction(plan: plan, trackID: video.trackID, duration: cursor, sourceSize: sourceSize, transform: transform)]
        return .init(asset: composition, videoComposition: videoComposition)
    }
}

final class EdwardVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let plan: RenderPlan
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let groups: [[TimedWord]]
    init(plan: RenderPlan, trackID: CMPersistentTrackID, duration: CMTime, sourceSize: CGSize, transform: CGAffineTransform) {
        var sortedPlan = plan
        sortedPlan.cropKeyframes.sort { $0.time < $1.time }
        self.plan = sortedPlan; self.trackID = trackID
        self.timeRange = CMTimeRange(start: .zero, duration: duration)
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        let targetBounds = CGRect(origin: .zero, size: sourceSize).applying(transform)
        // Track transforms use top-left coordinates; Core Image uses bottom-left coordinates.
        self.transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceSize.height)
            .concatenating(transform)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: abs(targetBounds.height)))
        self.groups = MediaTimeline.captionGroups(MediaTimeline.editedWords(plan.transcript.words, ranges: plan.clip.ranges), maximum: max(1, plan.captions.wordsPerLine * 2))
    }
}

final class EdwardVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.edward.media.compositor", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var captionCache: [String: CIImage] = [:]
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]() ] }
    var supportsHDRSourceFrames: Bool { false }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { queue.sync { captionCache.removeAll() } }
    func cancelAllPendingVideoCompositionRequests() { queue.sync {} }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? EdwardVideoInstruction,
                      let source = request.sourceFrame(byTrackID: instruction.trackID), let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: EdwardError.media("The renderer could not obtain a video frame.")); return
                }
                let size = request.renderContext.size
                let canvas = CGRect(origin: .zero, size: size)
                let outputTime = request.compositionTime.seconds
                let sourceTime = MediaTimeline.sourceTime(at: outputTime, ranges: instruction.plan.clip.ranges)
                var image = CIImage(cvPixelBuffer: source).transformed(by: instruction.transform)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                let point = instruction.plan.framing == .speaker
                    ? Self.cropPoint(at: sourceTime, keyframes: instruction.plan.cropKeyframes)
                    : CropKeyframe(time: sourceTime, centerX: 0.5)
                let preserve = instruction.plan.framing == .preserve || point.preserve
                let scale = preserve ? min(size.width / image.extent.width, size.height / image.extent.height) : max(size.width / image.extent.width, size.height / image.extent.height)
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let dx: CGFloat; let dy: CGFloat
                if preserve {
                    dx = (size.width - image.extent.width) / 2; dy = (size.height - image.extent.height) / 2
                } else {
                    dx = min(0, max(size.width - image.extent.width, size.width / 2 - point.centerX * image.extent.width))
                    dy = min(0, max(size.height - image.extent.height, size.height / 2 - point.centerY * image.extent.height))
                }
                image = image.transformed(by: CGAffineTransform(translationX: dx, y: dy))
                    .composited(over: CIImage(color: CIColor(red: 0.012, green: 0.027, blue: 0.024)).cropped(to: canvas))
                    .cropped(to: canvas)
                if instruction.plan.captions.enabled,
                   let cueIndex = instruction.groups.firstIndex(where: { outputTime >= ($0.first?.start ?? 0) && outputTime < ($0.last?.end ?? 0) }) {
                    let cue = instruction.groups[cueIndex]
                    let active = cue.lastIndex(where: { $0.start <= outputTime }) ?? 0
                    let key = "\(instruction.plan.id):\(cueIndex):\(active):\(Int(size.width))"
                    let overlay = captionCache[key] ?? CaptionPainter.image(words: cue, active: active, style: instruction.plan.captions, size: size)
                    if let overlay {
                        if captionCache.count >= 32 { captionCache.removeAll(keepingCapacity: true) }
                        captionCache[key] = overlay
                        image = overlay.composited(over: image)
                    }
                }
                context.render(image, to: output, bounds: canvas, colorSpace: colorSpace)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }

    static func cropPoint(at time: Double, keyframes: [CropKeyframe]) -> CropKeyframe {
        guard let first = keyframes.first else { return .init(time: time, centerX: 0.5, preserve: true) }
        guard let i = keyframes.lastIndex(where: { $0.time <= time }) else { return first }
        let left = keyframes[i]
        guard i + 1 < keyframes.count else { return left }
        let right = keyframes[i + 1]
        if left.preserve || right.preserve { return .init(time: time, centerX: 0.5, preserve: true) }
        let t = min(1, max(0, (time - left.time) / max(0.001, right.time - left.time)))
        return .init(time: time, centerX: left.centerX + (right.centerX - left.centerX) * t, centerY: left.centerY + (right.centerY - left.centerY) * t)
    }
}

enum CaptionPainter {
    static func image(words: [TimedWord], active: Int, style: CaptionStyle, size: CGSize) -> CIImage? {
        let factor = min(1, size.width / 1080)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, max(18, style.fontSize * factor), nil)
        let attributed = NSMutableAttributedString()
        let normal = color(style.textHex)
        let activeColor = style.speakerColors ? speakerColor(words[active].speaker) : color(style.highlightHex)
        for (index, word) in words.enumerated() {
            let text = word.text + (index == words.count - 1 ? "" : " ")
            attributed.append(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): index == active ? activeColor : normal
            ]))
        }
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        attributed.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: paragraph, range: NSRange(location: 0, length: attributed.length))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let portrait = size.height > size.width * 1.2
        // Conservative short-form safe area, including room for right-side social controls.
        // This is an editorial default, not a guarantee for every platform UI revision.
        let leftMargin = portrait ? 48 * factor : size.width * 0.08
        let rightMargin = portrait ? max(176 * factor, size.width * 0.163) : size.width * 0.08
        let horizontalPadding = 20 * factor, verticalPadding = 12 * factor
        let textWidth = size.width - leftMargin - rightMargin - horizontalPadding * 2
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: textWidth, height: size.height * 0.4), nil)
        let textHeight = ceil(measured.height) + 12 * factor
        let minimumInset = portrait ? (style.atTop ? 230.0 : 300.0) * factor : 32 * factor
        let inset = max(minimumInset, min(style.bottomInset * factor, size.height * 0.65))
        let y = style.atTop ? size.height - inset - textHeight - verticalPadding : inset + verticalPadding
        let rect = CGRect(x: leftMargin + horizontalPadding, y: max(20, y), width: textWidth, height: textHeight)
        // Cache only the caption panel pixels, not a full 1080×1920 surface for every active word.
        let backingRect = rect.insetBy(dx: -horizontalPadding, dy: -verticalPadding).integral
        let width = Int(backingRect.width), height = Int(backingRect.height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: -backingRect.minX, y: -backingRect.minY)
        context.setFillColor(CGColor(gray: 0, alpha: 0.76))
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: -horizontalPadding, dy: -verticalPadding), cornerWidth: 15 * factor, cornerHeight: 15 * factor, transform: nil)); context.fillPath()
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
        guard let result = context.makeImage() else { return nil }
        return CIImage(cgImage: result).transformed(by: CGAffineTransform(translationX: backingRect.minX, y: backingRect.minY))
    }
    static func color(_ hex: String) -> CGColor {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xF3FAF6
        return CGColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static func speakerColor(_ speaker: String?) -> CGColor {
        let colors = ["39FF6A", "F2B53A", "67D8FF", "D6A5FF"]
        let index = (speaker ?? "").utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return color(colors[index])
    }
}
