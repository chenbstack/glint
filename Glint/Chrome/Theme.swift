import SwiftUI
import AppKit

enum Theme {
    // backgrounds
    static let bgWindow   = Color(red: 0.039, green: 0.043, blue: 0.063)   // #0A0B10
    static let bgPane     = Color(red: 0.043, green: 0.039, blue: 0.078)   // #0B0A14 (slight indigo)

    // vibrancy tint overlays — black-first with the faintest indigo cast
    static let sidebarTintTop    = Color(red: 0.075, green: 0.065, blue: 0.110).opacity(0.86)
    static let sidebarTintBottom = Color(red: 0.045, green: 0.038, blue: 0.085).opacity(0.90)
    static let toolbarTint       = Color(red: 0.060, green: 0.052, blue: 0.095).opacity(0.86)

    // Liquid Glass tint (macOS 26): the sidebar indigo, but thin enough that
    // the glass still refracts the terminal behind it instead of reading as
    // a painted slab.
    static let glassTint         = Color(red: 0.075, green: 0.065, blue: 0.110).opacity(0.5)

    // text
    static let text1 = Color(red: 0.925, green: 0.929, blue: 0.949)        // #ECEDF2
    static let text2 = Color(red: 0.717, green: 0.725, blue: 0.784)        // #B7B9C8
    static let text3 = Color(red: 0.494, green: 0.510, blue: 0.565)        // #7E8290
    // text4 is used for 10–11pt captions; the original #565A6C only hit
    // ~2.9:1 against bgWindow — below WCAG AA (4.5:1) at these sizes.
    // #757A91 measures ~4.6:1 on bgWindow/bgPane while staying darker and
    // bluer than text3 (~5.1:1) so the muted hierarchy survives.
    static let text4 = Color(red: 0.459, green: 0.478, blue: 0.569)        // #757A91

    // accents
    static let accent       = Color(red: 0.369, green: 0.361, blue: 0.902) // #5E5CE6 systemIndigo
    static let accentBright = Color(red: 0.549, green: 0.549, blue: 1.000) // #8C8CFF
    static let green        = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
    static let orange       = Color(red: 1.000, green: 0.624, blue: 0.039) // #FF9F0A
    static let pink         = Color(red: 1.000, green: 0.392, blue: 0.510) // #FF6482
    static let cyan         = Color(red: 0.392, green: 0.824, blue: 1.000) // #64D2FF

    // separators
    static let divider = Color.white.opacity(0.045)
    static let border  = Color.white.opacity(0.07)

    /// Canonical accent palette keyed by the `glint.accentName` token. Single
    /// source for the SwiftUI chrome accent (`WorkspaceStore.accent`), the
    /// Settings swatches, and the terminal cursor/selection color so the three
    /// never drift. "indigo" / unset map to `accentBright`.
    static func accent(named name: String?) -> Color {
        switch name {
        case "cyan":   return cyan
        case "pink":   return pink
        case "orange": return orange
        case "green":  return green
        default:       return accentBright
        }
    }
}

extension Color {
    /// "RRGGBB" in sRGB. Lets a chrome accent `Color` feed ghostty's text
    /// config (cursor/selection), which only accepts hex strings — so the
    /// terminal color is derived from the same `Theme` color the UI uses
    /// rather than a hand-kept parallel hex table.
    var rgbHex: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

extension Font {
    static let glintUI       = Font.system(size: 13, weight: .medium)
    static let glintUISmall  = Font.system(size: 12, weight: .medium)
    static let glintCaption  = Font.system(size: 10.5, weight: .semibold).leading(.tight)
    static let glintSection  = Font.system(size: 10.5, weight: .semibold)
    static let glintMono     = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    static let glintMonoBig  = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let glintStatus   = Font.system(size: 11, weight: .medium, design: .monospaced)
}
