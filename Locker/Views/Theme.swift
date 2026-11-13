import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Theme {
    static let accent = Color(hex: 0x3451D1)
    static let sidebar = Color(hex: 0xF4F4F1)
    static let chrome = Color(hex: 0xF6F6F4)
    static let border = Color(hex: 0xE4E4E0)
    static let line = Color(hex: 0xDCDCD7)
    static let termBG = Color(hex: 0x17171A)
    static let tabStrip = Color(hex: 0x222226)
    static let muted = Color(hex: 0x64645F)
    static let text = Color(hex: 0x1A1A1A)
    static let chipBG = Color(hex: 0xEEF1FD)
    static let chipFG = Color(hex: 0x2A44B8)
    static let green = Color(hex: 0x1F7A4D)
    static let amber = Color(hex: 0xB45309)
    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

struct OutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(height: 32)
            .background(Color.white.opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(Theme.text)
    }
}

struct PrimaryButton: ButtonStyle {
    var height: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).frame(height: height)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: height > 32 ? 8 : 7))
            .foregroundStyle(.white)
    }
}
