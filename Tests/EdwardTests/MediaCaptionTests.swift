import XCTest
import CoreImage
import EdwardDomain
@testable import EdwardMedia

final class MediaCaptionTests: XCTestCase {
    func testPortraitCaptionsFitSafeAreaAndActuallyPaintText() throws {
        let words = [TimedWord(text: "Clear", start: 0, end: 1), .init(text: "captions", start: 1, end: 2)]
        for top in [false, true] {
            var style = CaptionStyle(); style.atTop = top; style.bottomInset = 20
            let image = try XCTUnwrap(CaptionPainter.image(words: words, active: 0, style: style, size: CGSize(width: 1080, height: 1920)))
            XCTAssertGreaterThanOrEqual(image.extent.minX, 47)
            XCTAssertLessThanOrEqual(image.extent.maxX, 905)
            if top { XCTAssertLessThanOrEqual(image.extent.maxY, 1691) }
            else { XCTAssertGreaterThanOrEqual(image.extent.minY, 299) }
            XCTAssertLessThan(image.extent.height, 400, "Caption cache must not allocate a full video-frame bitmap")
            let width = Int(image.extent.width), height = Int(image.extent.height)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            CIContext().render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            var green = 0, white = 0
            for pixel in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[pixel] < 100, pixels[pixel + 1] > 220, pixels[pixel + 2] < 180 { green += 1 }
                if pixels[pixel] > 220, pixels[pixel + 1] > 220, pixels[pixel + 2] > 220 { white += 1 }
            }
            XCTAssertGreaterThan(green, 200, "Active-word glyphs must be visible")
            XCTAssertGreaterThan(white, 200, "Remaining caption glyphs must be visible")
        }
    }
}
