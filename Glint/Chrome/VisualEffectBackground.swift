import SwiftUI
import AppKit

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    /// When false the area refuses to initiate window-dragging on mouseDown.
    /// Default is false so sidebars / panes don't grab the window by accident;
    /// the toolbar opts in explicitly.
    let allowsWindowDrag: Bool

    init(material: NSVisualEffectView.Material = .sidebar,
         blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
         state: NSVisualEffectView.State = .followsWindowActiveState,
         allowsWindowDrag: Bool = false) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.allowsWindowDrag = allowsWindowDrag
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v: NSVisualEffectView = allowsWindowDrag
            ? NSVisualEffectView()
            : NoDragVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

private final class NoDragVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Invisible NSView whose only job is titlebar-style window dragging.
/// The header's Liquid Glass band draws via `.glassEffect` (no NSView of
/// ours), so this restores the drag behavior the NSVisualEffectView used
/// to provide.
struct WindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        // Drive the drag manually instead of letting AppKit auto-move the
        // window: a view with `mouseDownCanMoveWindow = true` never receives
        // `mouseDown`, so we couldn't see the double-click. With it false we
        // get the event, start the drag ourselves for a single click, and
        // zoom (maximize) on a double click (matching a real titlebar).
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window else { super.mouseDown(with: event); return }
            if event.clickCount == 2 {
                window.zoom(nil)
                return
            }
            window.performDrag(with: event)
        }
    }
}

/// The opposite: an invisible NSView that refuses window dragging. SwiftUI
/// surfaces painted with plain `Color` have no NSView of their own, so with
/// `isMovableByWindowBackground` every empty stretch drags the window —
/// slide this behind regions (sidebar content) that should stay put.
struct NoDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NoDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class NoDragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

// MARK: - Liquid Glass (macOS 26)

/// Whether the OS can render Liquid Glass at all. Call sites that keep a
/// separate flat style for the same state (e.g. a chip's fill) combine this
/// with the user's glass toggle so the two looks never stack.
var liquidGlassAvailable: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
}

/// Pre-26 stand-in for the system's Liquid Glass — a real NSVisualEffectView
/// (so the terminal grid genuinely blurs through) clipped to the same rounded
/// shape, with a hairline border and a faint top sheen so the capsule reads
/// as glass and not a flat slab. Used as the default fallback by the
/// no-fallback `liquidGlass(enabled:cornerRadius:)` so the floating-island
/// header stays consistent on macOS < 26.
struct GlassCapsuleFallback: View {
    let cornerRadius: CGFloat
    var tint: Color?

    private var isDarkTheme: Bool { Theme.current.isDark }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            // `.underPageBackground` is the darkest stock vibrancy
            // material in dark mode — `.hudWindow` was a HUD-style frosty
            // light grey and even a 0.6 black wash couldn't fully tame it
            // (you could see the capsule "settle" a frame or two after
            // the viewport-top-offset's scrollback rows landed underneath
            // and blurred up through the glass).
            //
            // State pinned to `.active` so the material doesn't flash the
            // lighter `.inactive` palette during the first frames while
            // the window is still picking up key state.
            VisualEffectBackground(
                material: isDarkTheme ? .underPageBackground : .hudWindow,
                state: .active
            )
            if isDarkTheme {
                // Light black wash — underPageBackground is already the
                // darker stock material, so we only need a small nudge to
                // keep the capsule reading as glass without flattening it
                // into an opaque slab.
                Color.black.opacity(0.3)
            } else {
                // Pre-26 vibrancy follows the system appearance, not Glint's
                // theme. Pull light themes back toward the selected terminal
                // background so a light Glint theme doesn't get a dark capsule
                // on older macOS releases.
                Theme.bgPane.opacity(0.78)
                Color.white.opacity(0.12)
            }
            if let tint {
                tint.opacity(isDarkTheme ? 0.18 : 0.10)
            }
            // Faint top-down sheen so the upper edge catches "light" — the
            // single cheapest cue that says "glass surface" rather than
            // "translucent slab."
            LinearGradient(
                colors: isDarkTheme
                    ? [Color.white.opacity(0.06), Color.white.opacity(0)]
                    : [Color.white.opacity(0.36), Color.white.opacity(0.04)],
                startPoint: .top, endPoint: .center
            )
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isDarkTheme ? Color.white.opacity(0.10) : Color.black.opacity(0.10),
                lineWidth: 0.5
            )
        )
    }
}

/// Puts macOS 26 Liquid Glass behind the content when the OS supports it and
/// the user's glass toggle is on. Pre-26 + glass on falls back to
/// `GlassCapsuleFallback` (no-user-fallback overload) or to the caller's
/// fallback (the overload that takes one). Glass off short-circuits to the
/// supplied fallback / nothing, so the band layout keeps working untouched.
struct LiquidGlassSurface<Fallback: View>: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool
    /// True when the caller didn't supply a fallback — we substitute the
    /// in-house glass capsule so floating islands keep working pre-26.
    var autoCapsule: Bool
    @ViewBuilder let fallback: () -> Fallback

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), enabled {
            content.glassEffect(
                glass,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else if enabled && autoCapsule {
            content.background(GlassCapsuleFallback(cornerRadius: cornerRadius, tint: tint))
        } else {
            content.background(fallback())
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    /// Forces the standard arrow pointer while hovering. The floating header
    /// islands sit over the terminal, whose NSView installs an iBeam cursor
    /// rect across its whole bounds — SwiftUI views assert no cursor of their
    /// own, so without this the islands inherit the text cursor.
    @ViewBuilder
    func arrowPointer() -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(.default)
        } else {
            self
        }
    }

    /// Liquid Glass with the in-house capsule as automatic pre-26 fallback —
    /// for floating header islands that need the capsule on every macOS so
    /// the layout doesn't fork. `enabled=false` paints nothing (band layout).
    func liquidGlass(enabled: Bool,
                     cornerRadius: CGFloat,
                     tint: Color? = nil,
                     interactive: Bool = false) -> some View {
        modifier(LiquidGlassSurface(enabled: enabled,
                                    cornerRadius: cornerRadius,
                                    tint: tint,
                                    interactive: interactive,
                                    autoCapsule: true,
                                    fallback: { EmptyView() }))
    }

    /// Liquid Glass with a caller-supplied fallback — for surfaces (modals,
    /// dialogs) whose pre-26 look is hand-painted differently from the
    /// floating-island capsule.
    func liquidGlass<F: View>(enabled: Bool,
                              cornerRadius: CGFloat,
                              tint: Color? = nil,
                              interactive: Bool = false,
                              @ViewBuilder fallback: @escaping () -> F) -> some View {
        modifier(LiquidGlassSurface(enabled: enabled,
                                    cornerRadius: cornerRadius,
                                    tint: tint,
                                    interactive: interactive,
                                    autoCapsule: false,
                                    fallback: fallback))
    }
}
