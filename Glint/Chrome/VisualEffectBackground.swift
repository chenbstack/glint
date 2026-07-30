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
    /// 显式钉住的外观。`nil` = 跟随系统(暗 / 亮);非空 = 强制按指定外观渲染
    /// (NSVisualEffectView 的 material 是「外观感知」的,系统外观和 Glint 主题
    /// 不一致时,不钉就会出现 sidebar 暗、终端亮这种反向 —— 比如 macOS 暗色 +
    /// Glint 亮主题。Glint chrome 的语义是「跟主题不跟系统」,所以这里需要钉。)
    let appearance: NSAppearance?

    init(material: NSVisualEffectView.Material = .sidebar,
         blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
         state: NSVisualEffectView.State = .followsWindowActiveState,
         allowsWindowDrag: Bool = false,
         appearance: NSAppearance? = nil) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.allowsWindowDrag = allowsWindowDrag
        self.appearance = appearance
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v: NSVisualEffectView = allowsWindowDrag
            ? NSVisualEffectView()
            : NoDragVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        v.isEmphasized = true
        v.appearance = appearance
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // SwiftUI calls this on every layout pass. Re-assigning these
        // NSVisualEffectView properties even when unchanged can make the
        // material redraw for a frame, which is visible while resizing panes.
        if nsView.material != material {
            nsView.material = material
        }
        if nsView.blendingMode != blendingMode {
            nsView.blendingMode = blendingMode
        }
        if nsView.state != state {
            nsView.state = state
        }
        if nsView.appearance?.name != appearance?.name {
            nsView.appearance = appearance
        }
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

/// Invisible overlay that fires `onMiddleClick` only on a middle-mouse
/// button press. Left/right clicks, drags, hover, and scroll pass through
/// untouched (the view returns nil from `hitTest` unless the middle button
/// is down), so any SwiftUI gesture / popover / menu underneath keeps
/// working. Mirror of the `WindowDragSurface` / `NoDragSurface` pattern.
struct MiddleClickCatcher: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onMiddleClick: onMiddleClick) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onMiddleClick = onMiddleClick
    }

    private final class CatcherView: NSView {
        var onMiddleClick: () -> Void

        init(onMiddleClick: @escaping () -> Void) {
            self.onMiddleClick = onMiddleClick
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        // Only claim hits when the middle button is pressed — every other
        // interaction (left/right click, drag, hover, scroll) falls through
        // to the SwiftUI view underneath. `hitTest` is the gate AppKit
        // consults before routing any mouse event, so returning nil here
        // makes this view genuinely transparent to non-middle input.
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSEvent.pressedMouseButtons & (1 << 2) != 0 ? self : nil
        }

        override func otherMouseDown(with event: NSEvent) {
            // buttonNumber 2 == middle. Other "other" buttons (back/forward)
            // pass through to the responder chain.
            guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
            onMiddleClick()
        }

        // Never let the overlay drag the window or steal cursor focus.
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { false }
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
                material: isDarkTheme ? .underPageBackground : .popover,
                state: .active,
                // 钉外观让 vibrancy 跟 Glint 主题走,而不是跟系统。否则系统暗 +
                // Glint 亮(或反之)时,材质会渲染成反方向,浮岛 capsule 跟终端
                // 色调撞车。
                appearance: NSAppearance(named: isDarkTheme ? .darkAqua : .aqua)
            )
            if isDarkTheme {
                // Light black wash — underPageBackground is already the
                // darker stock material, so we only need a small nudge to
                // keep the capsule reading as glass without flattening it
                // into an opaque slab.
                Color.black.opacity(0.3)
            } else {
                // 亮色:Codex-style neutral glass. Keep this wash thin and
                // nearly equal-channel so it does not drift blue.
                Color(red: 0.970, green: 0.970, blue: 0.976).opacity(0.32)
            }
            if let tint {
                tint.opacity(isDarkTheme ? 0.18 : 0.05)
            }
            // Faint top-down sheen so the upper edge catches "light" — the
            // single cheapest cue that says "glass surface" rather than
            // "translucent slab." 亮色用 0.14 而不是更高,光泽要轻 —— 36% 的
            // 白会读成"顶部一条高光带",失了玻璃的微妙感。
            LinearGradient(
                colors: isDarkTheme
                    ? [Color.white.opacity(0.06), Color.white.opacity(0)]
                    : [Color.white.opacity(0.18), Color.white.opacity(0.03)],
                startPoint: .top, endPoint: .center
            )
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isDarkTheme ? Color.white.opacity(0.10) : Color.black.opacity(0.045),
                lineWidth: 0.5
            )
        )
        .background(LightGlassCapsuleDepth(cornerRadius: cornerRadius))
    }
}

private struct LightGlassCapsuleDepth: View {
    let cornerRadius: CGFloat

    var body: some View {
        if !Theme.current.isDark {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape
                // Almost invisible fill gives SwiftUI a shape to cast shadows
                // from without changing the capsule's glass color.
                .fill(Color.white.opacity(0.001))
                .shadow(color: Color.black.opacity(0.105), radius: 1.2, y: 0.7)
                .shadow(color: Color.black.opacity(0.085), radius: 7, y: 2.5)
                .shadow(color: Color.black.opacity(0.045), radius: 18, y: 8)
        }
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
            .background(LightGlassCapsuleDepth(cornerRadius: cornerRadius))
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
