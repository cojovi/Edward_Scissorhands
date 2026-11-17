import SwiftUI

enum Studio {
    static let background = Color(hex: "030706")
    static let pine = Color(hex: "09110D")
    static let panel = Color(hex: "101A15")
    static let raised = Color(hex: "17261F")
    static let line = Color(hex: "2A3C33")
    static let green = Color(hex: "39FF6A")
    static let white = Color(hex: "F3FAF6")
    static let amber = Color(hex: "F2B53A")
    static let muted = Color(hex: "97A89E")
    static let body = Color(hex: "D7E1DB")
    static func mono(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}
extension Color {
    init(hex: String) {
        let v = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, opacity: 1)
    }
}
struct SignalButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .foregroundStyle(prominent ? Studio.background : Studio.white)
            .background(prominent ? Studio.green.opacity(configuration.isPressed ? 0.75 : 1) : Studio.raised.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? Studio.green : Studio.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.42)
    }
}
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).background(Studio.panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Studio.line.opacity(0.6))) }
}
struct Eyebrow: View {
    let text: String
    var color: Color = Studio.muted
    var body: some View { Text(text.uppercased()).font(Studio.mono(10)).tracking(2).foregroundStyle(color) }
}
struct ScissorMark: View {
    var size: CGFloat = 38
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24).fill(Studio.green)
            Image(systemName: "scissors").font(.system(size: size * 0.57, weight: .bold)).rotationEffect(.degrees(-28)).foregroundStyle(Studio.background)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
struct EmptyTimeline: View {
    var body: some View {
        Canvas { context, size in
            for i in 0..<72 {
                let x = CGFloat(i) * size.width / 72
                let height = 5 + abs(sin(Double(i) * 0.51) * cos(Double(i) * 0.19)) * 48
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: max(2, size.width / 110), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(i > 24 && i < 49 ? Studio.green.opacity(0.8) : Studio.line))
            }
            let box = CGRect(x: size.width * 0.34, y: 6, width: size.width * 0.34, height: size.height - 12)
            context.stroke(Path(roundedRect: box, cornerRadius: 5), with: .color(Studio.green.opacity(0.6)), lineWidth: 1)
        }.frame(height: 86).accessibilityHidden(true)
    }
}
func timecode(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "—" }
    let total = max(0, Int(seconds))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
}
