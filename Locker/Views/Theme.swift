import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// A colour that resolves to `light` or `dark` depending on the effective appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Semantic colour tokens. Every colour used in views should come from here so light and dark stay in sync.
enum Theme {
    // Brand / surfaces
    static let accent = Color(light: 0x3451D1, dark: 0x6F86F0)
    static let sidebar = Color(light: 0xF4F4F1, dark: 0x1F1F22)
    static let chrome = Color(light: 0xF6F6F4, dark: 0x252528)
    static let surface = Color(light: 0xFFFFFF, dark: 0x2B2B2F)
    static let border = Color(light: 0xE4E4E0, dark: 0x38383C)
    static let line = Color(light: 0xDCDCD7, dark: 0x45454A)
    static let headerLine = Color(light: 0xECECE8, dark: 0x303034)
    static let selectedBorder = Color(light: 0xD6D6D1, dark: 0x55555A)

    // Text
    static let text = Color(light: 0x1A1A1A, dark: 0xECECE8)
    static let muted = Color(light: 0x64645F, dark: 0xA0A09A)
    static let secondary = Color(light: 0x55554F, dark: 0xB4B4AE)
    static let idle = Color(light: 0x9A9A94, dark: 0x77777A)

    // Chips
    static let chipBG = Color(light: 0xEEF1FD, dark: 0x2A3158)
    static let chipFG = Color(light: 0x2A44B8, dark: 0xA9B7FF)

    // Status
    static let green = Color(light: 0x1F7A4D, dark: 0x4CC38A)
    static let amber = Color(light: 0xB45309, dark: 0xF0A04B)
    static let amberBG = Color(light: 0xFFF4E5, dark: 0x3A2C17)
    static let red = Color(light: 0xB42318, dark: 0xF97066)
    static let redBG = Color(light: 0xFEF3F2, dark: 0x3B1F1D)

    // Terminal chrome (always dark)
    static let termBG = Color(hex: 0x17171A)
    static let tabStrip = Color(hex: 0x222226)
    static let termText = Color(hex: 0xC8C8C2)
    static let termMuted = Color(hex: 0xA6A6A0)
    static let termButtonBG = Color(hex: 0x2A2A2F)
    static let termButtonBorder = Color(hex: 0x45454A)

    // Claude Code activity highlight (sidebar rows)
    static let activityWaitingBG = Color(light: 0xE3EDFF, dark: 0x22305A)
    static let activityRunningBG = Color(light: 0xFFF3C4, dark: 0x3F3513)
    static let activityIdleBG = Color(light: 0xE6F4EC, dark: 0x16342A)
    static let activityRunning = Color(light: 0xD9A406, dark: 0xF2C94C)

    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

struct OutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(height: 32)
            .background(Theme.surface.opacity(configuration.isPressed ? 0.6 : 1))
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

// MARK: - Banner and toast (the single feedback pattern)

enum FeedbackKind {
    case info, success, warning, error

    var tint: Color {
        switch self {
        case .info: Theme.chipFG
        case .success: Theme.green
        case .warning: Theme.amber
        case .error: Theme.red
        }
    }
    var background: Color {
        switch self {
        case .info: Theme.chipBG
        case .success: Theme.surface
        case .warning: Theme.amberBG
        case .error: Theme.redBG
        }
    }
    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

/// Inline message shown where the problem happened (form errors, repair prompts).
struct Banner: View {
    let kind: FeedbackKind
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbol).foregroundStyle(kind.tint)
            Text(message).font(.system(size: 12)).foregroundStyle(Theme.text).textSelection(.enabled)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(kind.tint)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(kind.background))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(kind.tint.opacity(0.4)))
        .accessibilityElement(children: .combine)
    }
}

/// A transient confirmation with an optional Undo action.
struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var kind: FeedbackKind = .success
    var text: String
    var undoTitle: String? = nil
    var undo: (() -> Void)? = nil

    static func == (l: ToastMessage, r: ToastMessage) -> Bool { l.id == r.id }
}

struct ToastView: View {
    let toast: ToastMessage
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.kind.symbol).foregroundStyle(toast.kind.tint)
            Text(toast.text).font(.system(size: 12.5, weight: .medium))
            if let title = toast.undoTitle, let undo = toast.undo {
                Button(title) { undo(); dismiss() }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
    }
}
