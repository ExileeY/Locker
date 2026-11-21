import Foundation

/// The side panel of one workspace: whether it is open, how wide, and the page it shows.
/// Kept apart from `AppState` (own file, see `PaneStore`) so the state schema does not change.
struct PaneState: Codable, Equatable {
    static let defaultFraction = 0.45

    var open = false
    /// Share of the detail area's width the panel takes while open.
    var widthFraction = PaneState.defaultFraction
    /// Last page shown; nil until the user opens one.
    var url: String?

    init(open: Bool = false, widthFraction: Double = PaneState.defaultFraction, url: String? = nil) {
        self.open = open; self.widthFraction = widthFraction; self.url = url
    }

    /// Lenient: a bad value in one field must not lose the others.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        open = (try? c.decodeIfPresent(Bool.self, forKey: .open)) ?? false
        let f = (try? c.decodeIfPresent(Double.self, forKey: .widthFraction)) ?? PaneState.defaultFraction
        widthFraction = f.isFinite ? f : PaneState.defaultFraction
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
    }
}

/// How the detail area is shared between the terminal and the panel.
enum PaneLayout {
    static let minTerminal: Double = 360
    static let minPane: Double = 280
    /// Width of the divider between them.
    static let dividerWidth: Double = 6

    /// The panel's width for `fraction` of `total`, kept so the terminal and the panel both stay usable.
    /// When `total` cannot fit both minimums the panel gets what the terminal leaves (never negative).
    static func paneWidth(fraction: Double, total: Double) -> Double {
        let usable = max(0, total - dividerWidth)
        let lo = minPane, hi = usable - minTerminal
        if hi < lo { return max(0, min(lo, usable - minTerminal)) }
        let want = (fraction.isFinite ? fraction : PaneState.defaultFraction) * usable
        return min(max(want, lo), hi)
    }

    /// The fraction that gives the panel `width` of `total` (inverse of `paneWidth`, before clamping).
    static func fraction(forPaneWidth width: Double, total: Double) -> Double {
        let usable = total - dividerWidth
        guard usable > 0 else { return PaneState.defaultFraction }
        return min(max(width / usable, 0), 1)
    }
}
