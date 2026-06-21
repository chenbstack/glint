import AppKit
import Darwin
import QuartzCore
import GhosttyKit

/// AppKit view hosting one `ghostty_surface_t`.
///
/// We give ghostty an `NSView*` via `ghostty_surface_config_s.platform.macos.nsview`.
/// At surface creation ghostty's Metal renderer REPLACES `view.layer` with its
/// own `IOSurfaceLayer` — a plain CALayer whose `contents` it swaps to a freshly
/// drawn IOSurface each frame (see ghostty/src/renderer/Metal.zig). So nothing
/// we configure on a layer of our own survives past `createSurface()`; the
/// initial layer only provides the background color before the first frame.
/// Frame presentation runs through the main queue (`IOSurfaceLayer.setSurface`
/// dispatches the contents swap), so keeping the main thread responsive is
/// load-bearing for terminal frame pacing.
final class GhosttySurfaceView: NSView, NSTextInputClient {

    private var surface: ghostty_surface_t?
    private var trackingArea: NSTrackingArea?
    private var markedTextValue: NSAttributedString = NSAttributedString(string: "")
    /// While non-nil, `insertText`/`doCommand(by:)` divert into this buffer
    /// instead of touching the surface. Used to let the IME observe a chord
    /// (e.g. Shift+Return) without emitting its text/command side-effects.
    private var keyTextAccumulator: [String]?
    private let initialCwd: String?
    /// Identifier (`"<wsuuid>:<paneSeq>"`) passed into the pty as
    /// `$GLINT_PANE_ID` so CLI-agent hooks can address us back.
    private let paneKey: String?
    /// True when this pane reaches the top edge of the window — only then
    /// does the padded launcher (clear + blank rows) make sense, since the
    /// floating glass header only ever obscures top-edge panes. Bottom panes
    /// from Shift+Cmd+D (vertical splits) get a plain shell so their content
    /// starts at the divider, not 3 blank rows below it.
    private let topAligned: Bool
    private let agentSocketPath: String?
    /// Optional text fed into the PTY as if typed by the user at the start of
    /// the session — ghostty handles the timing (waits until the shell is
    /// ready). Used to auto-resume `claude --continue` / `codex resume --last`
    /// when the corresponding setting is on. nil = no initial input.
    private let initialInput: String?
    /// Latest cwd pushed by ghostty via OSC 7 / PWD action. Preferred over
    /// proc_pidinfo polling because it's event-driven.
    var cachedCwd: String?

    private var scrollbackEnabled: Bool {
        (UserDefaults.standard.object(forKey: "glint.restoreTerminalScrollback") as? Bool) ?? true
    }
    private var scrollbackID: String? {
        paneKey.map { ScrollbackArchive.fileID(forPaneKey: $0) }
    }
    /// The exact history text echoed into this surface at restore (the prior
    /// session's saved scrollback). Kept verbatim so future snapshots can
    /// re-attach it as a STABLE prefix and capture only this session's NEW
    /// output, instead of re-rendering the restored content from the grid each
    /// flush — which otherwise piles it up (duplicate banners, stale-width
    /// rows) every restart. nil until a restore happens.
    private var restoredHistory: String?
    /// Saved scrollback waiting to be echoed. Held until the surface is wide
    /// enough for the captured content (the window briefly lays out narrower
    /// during launch, so the FIRST non-zero size is too small). Consumed once
    /// in `syncSurfaceSize`.
    private var pendingRestoreData: Data?
    /// Column count the pending restore content was captured at (its widest
    /// line). We wait for the surface to reach this before echoing so full-
    /// width rows land without wrapping. 0 = unknown (old snapshot) → echo at
    /// first valid size.
    private var requiredRestoreCols = 0
    /// One-shot guard: if the window settles NARROWER than the captured content
    /// (wrapping then unavoidable), echo anyway so history is never lost.
    private var restoreFallbackArmed = false
    /// Column count seen at the previous restore probe. We echo only once the
    /// width holds STEADY across two `syncSurfaceSize` passes — the surface
    /// ramps up during launch (e.g. 88 → 180 → 250), and a restored input box
    /// repaints its background to the right edge with `\e[K`, which fills to the
    /// width AT ECHO TIME. Echoing at the first qualifying frame would stop that
    /// fill at the launch-time width; waiting for the width to settle fills to
    /// the final window width. -1 = no probe yet.
    private var lastRestoreProbeCols = -1

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { false }
    /// Go non-opaque when the terminal is translucent so AppKit's compositor
    /// draws the desktop behind ghostty's alpha IOSurface instead of an opaque
    /// backing. Re-queried by AppKit whenever the layer backing is refreshed.
    override var isOpaque: Bool { !GhosttyManager.shared.terminalIsTransparent }
    override var wantsUpdateLayer: Bool { true }
    /// NSView's default in borderless windows is YES — that lets the terminal
    /// area drag the whole window. Force NO so clicks here only go to ghostty.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Cursor shape currently advertised by ghostty (default: text I-beam).
    /// Updated when ghostty emits `GHOSTTY_ACTION_MOUSE_SHAPE` while the
    /// pointer hovers over a link or enters mouse-mode rendering.
    var mouseShape: ghostty_action_mouse_shape_e = GHOSTTY_MOUSE_SHAPE_TEXT {
        didSet {
            guard mouseShape != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    init(frame: NSRect,
         initialCwd: String? = nil,
         paneKey: String? = nil,
         agentSocketPath: String? = nil,
         topAligned: Bool = true,
         initialInput: String? = nil) {
        self.initialCwd = initialCwd
        self.paneKey = paneKey
        self.agentSocketPath = agentSocketPath
        self.topAligned = topAligned
        self.initialInput = initialInput
        super.init(frame: frame)
        wantsLayer = true
        // Placeholder until ghostty installs its IOSurfaceLayer. Opaque mode:
        // paint the theme bg so a new pane doesn't flash white. Translucent
        // mode: stay clear/non-opaque so nothing blocks the desktop behind
        // ghostty's own background-opacity.
        refreshAppearanceBacking()
        // Accept file drops from Finder; on drop we paste the shell-quoted
        // path so users can `cd <drop>` without typing it.
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let s = surface { ghostty_surface_free(s) }
    }

    /// One-shot: a kept-alive surface was re-attached to a window, so the next
    /// `syncSurfaceSize` with a valid drawable size must force a frame. The
    /// render thread won't redraw on its own without a size change or an
    /// occlusion transition, neither of which a same-size workspace switch-back
    /// produces. Cleared the moment that forced frame is drawn.
    private var pendingVisibleRedraw = false

    /// Opt-in tracing for the blank-pane-on-switch investigation. Launch the dev
    /// build with `GLINT_LOG_VISIBLE=1` to see attach / forced-redraw events.
    private let logVisible = ProcessInfo.processInfo.environment["GLINT_LOG_VISIBLE"] != nil
    var debugKey: String { paneKey ?? "?" }

    /// (Re)apply the opaque/clear backing to whatever layer is currently
    /// installed. Must be called AGAIN after `createSurface` because ghostty
    /// REPLACES `view.layer` with its own IOSurfaceLayer — the placeholder
    /// settings from init don't carry over to the new layer. Also re-run from
    /// the representable's `updateNSView` so live opacity changes take hold.
    func refreshAppearanceBacking() {
        GhosttyManager.shared.applyTerminalBacking(to: layer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Observe the window moving between screens so ghostty's
        // CVDisplayLink can re-lock to the new display's vsync; without
        // this the link stays on whatever display it was created on and
        // scroll/animation pacing falls out of sync with the actual
        // screen the surface is being composited onto.
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        if let win = window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeScreen(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: win
            )
        }

        // Occlusion: ghostty stops a surface's display link while it's not
        // visible (renderer.setVisible). Without this push, every surface
        // detached from the window — i.e. all panes of every non-selected
        // workspace, which the store keeps alive on purpose — keeps its
        // render loop running forever (cursor blink redraws etc.). Window-
        // level occlusion (minimized, fully covered) is pushed too, same as
        // upstream's windowDidChangeOcclusionState.
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        if let win = window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeOcclusionState(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: win
            )
        }
        pushOcclusionToGhostty()

        guard window != nil else {
            // Detached (e.g. switched to another workspace). Occlusion was
            // pushed false above; nothing to draw.
            return
        }

        if surface == nil {
            createSurface()
            // Push the initial display id right after surface creation. The
            // `didChangeScreen` notification only fires on subsequent moves,
            // so without this CVDisplayLink would start on
            // `createWithActiveCGDisplays()`'s default display, which may not
            // be the one our window is on (multi-monitor setups, secondary
            // ProMotion display, etc.).
            pushDisplayIDToGhostty()
            // The surface didn't exist for the push above; mark it visible now.
            pushOcclusionToGhostty()
        } else {
            // Reusing a surface kept alive while its workspace was off screen.
            pushDisplayIDToGhostty()
        }

        // A surface kept alive in a non-selected workspace had its swap chain
        // shrunk to 1×1 while detached, and the render thread only auto-redraws
        // on a false→true occlusion *transition* (renderer/Thread.zig) or a size
        // change. Re-attaching to an already-visible window fires no occlusion
        // notification, and if the pane's size is unchanged nothing dirties the
        // renderer — so a pane switched back into view would sit blank until it
        // next emits output. Mark a one-shot redraw; it fires from
        // `syncSurfaceSize` once we have a valid (non-zero) drawable size, since
        // `drawFrame` bails on a 0×0 surface — which is what `bounds` is at
        // attach time, before AppKit lays the view out.
        pendingVisibleRedraw = true
        if logVisible {
            NSLog("[glint.visible] attach pane=\(paneKey) bounds=\(bounds.size) occluVisible=\(window?.occlusionState.contains(.visible) ?? false)")
        }
        syncSurfaceSize(pointsSize: bounds.size)   // usually pre-layout → no-op
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            if self.logVisible {
                NSLog("[glint.visible] async-tick pane=\(self.paneKey ?? "?") bounds=\(self.bounds.size) pending=\(self.pendingVisibleRedraw)")
            }
            // Re-confirm occlusion once `occlusionState` has settled (a stale
            // read at attach time would otherwise leave us pushed-occluded with
            // no notification coming), and fire the redraw now that the view has
            // been laid out.
            self.pushOcclusionToGhostty()
            self.syncSurfaceSize(pointsSize: self.bounds.size)
        }
    }

    @objc private func windowDidChangeScreen(_ note: Notification) {
        pushDisplayIDToGhostty()
        // Backing scale can differ across screens (Retina vs non-Retina,
        // mixed-DPI external monitors); re-push so ghostty re-rasterises
        // glyphs at the right scale.
        viewDidChangeBackingProperties()
    }

    @objc private func windowDidChangeOcclusionState(_ note: Notification) {
        pushOcclusionToGhostty()
    }

    private func pushOcclusionToGhostty() {
        guard let s = surface else { return }
        let visible = window?.occlusionState.contains(.visible) ?? false
        ghostty_surface_set_occlusion(s, visible)
    }

    private func pushDisplayIDToGhostty() {
        guard let s = surface,
              let screenNum = window?.screen?.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber
        else { return }
        ghostty_surface_set_display_id(s, screenNum.uint32Value)
    }

    private func createSurface() {
        // Memory-profiling escape hatch: launch with GLINT_NO_SURFACE=1 to
        // measure the app's footprint without any ghostty renderer.
        if ProcessInfo.processInfo.environment["GLINT_NO_SURFACE"] != nil {
            NSLog("GhosttySurfaceView: GLINT_NO_SURFACE set, skipping surface creation")
            showSurfaceCreationError()
            return
        }
        guard let app = GhosttyManager.shared.app else {
            NSLog("GhosttySurfaceView: ghostty app not ready")
            showSurfaceCreationError()
            return
        }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos = ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        )
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0   // 0 = use config default

        // working_directory lives only while cfg is alive — strdup so the
        // C string outlives this scope; ghostty copies it during surface_new.
        var cwdBuf: UnsafeMutablePointer<CChar>? = nil
        if let cwd = initialCwd, !cwd.isEmpty {
            cwdBuf = strdup(cwd)
            cfg.working_directory = UnsafePointer(cwdBuf)
        }
        defer { if cwdBuf != nil { free(cwdBuf) } }

        // Same strdup discipline for `initial_input` — ghostty feeds these
        // bytes into the PTY after the shell is ready, so callers don't have
        // to time the injection themselves.
        var inputBuf: UnsafeMutablePointer<CChar>? = nil
        if let input = initialInput, !input.isEmpty {
            inputBuf = strdup(input)
            cfg.initial_input = UnsafePointer(inputBuf)
        }
        defer { if inputBuf != nil { free(inputBuf) } }

        // Env vars for CLI-agent hooks (Claude Code etc.) — same strdup
        // discipline; ghostty copies the array during surface_new.
        var envPairs: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        if let pk = paneKey { envPairs.append((strdup("GLINT_PANE_ID"), strdup(pk))) }
        if let sock = agentSocketPath { envPairs.append((strdup("GLINT_AGENT_SOCK"), strdup(sock))) }
        defer { envPairs.forEach { free($0.0); free($0.1) } }

        // Reserve a top inset for the floating-island header when this pane
        // is the one that sits flush against the chrome (split children are
        // tucked below it and don't need the offset). The ghostty fork
        // paints scrollback rows up into this strip so the islands' glass
        // blur shows real content scrolling through, not a dead band.
        if topAligned, let pt = GhosttyManager.floatingHeaderInsetPt() {
            cfg.viewport_top_offset = pt
        }

        let restoreData: Data? = {
            guard scrollbackEnabled, let id = scrollbackID,
                  let data = ScrollbackArchive.read(id: id), !data.isEmpty else { return nil }
            return data
        }()

        var envArray: [ghostty_env_var_s] = envPairs.map {
            ghostty_env_var_s(key: UnsafePointer($0.0), value: UnsafePointer($0.1))
        }
        let s: ghostty_surface_t? = envArray.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                cfg.env_vars = base
                cfg.env_var_count = buf.count
            }
            return ghostty_surface_new(app, &cfg)
        }
        guard let s else {
            NSLog("ghostty_surface_new returned nil")
            showSurfaceCreationError()
            return
        }
        self.surface = s
        // ghostty just swapped in its IOSurfaceLayer — re-stamp the
        // opaque/clear backing onto the NEW layer (init's settings were on the
        // discarded placeholder layer).
        refreshAppearanceBacking()
        removeSurfaceCreationError()

        // Terminal history restore: echo last session's saved colored
        // scrollback into the surface (clean even for TUIs — it's the final
        // character grid, not a replay of the render stream). Gated by a
        // setting. DEFERRED to the first valid `syncSurfaceSize`: a brand-new
        // surface sits at ghostty's default column count, narrower than the
        // pane, so echoing full-width history here would wrap every line and a
        // later resize doesn't reliably reflow it back. We stash the bytes and
        // echo once the surface has its real pane width (see syncSurfaceSize).
        pendingRestoreData = restoreData
        requiredRestoreCols = restoreData.map { Self.maxDisplayWidth(of: $0) } ?? 0

        // Route the initial size through the same CATransaction path the
        // resize hooks use, so frame 0 already has drawableSize aligned
        // with view bounds — no first-paint stretch from the layer's
        // default 0×0 drawable.
        syncSurfaceSize(pointsSize: bounds.size)
    }

    /// Echo the previous session's saved colored scrollback into a freshly
    /// created surface. The saved bytes are a flat colored text dump (SGR color
    /// codes + newlines only — no cursor moves, mode switches, or negotiation),
    /// rebuilt from the final grid, so it can't corrupt the new terminal even if
    /// the prior session ended inside a full-screen TUI.
    private func restoreScrollback(into s: ghostty_surface_t, data: Data) {
        var text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return }
        // Remember the prior history verbatim so flushes re-attach it as a
        // stable prefix rather than re-deriving it (at a possibly different
        // width) from the grid every cycle. Trailing newlines stripped so the
        // junction with this session's new output stays clean.
        restoredHistory = String(text.reversed().drop(while: { $0 == "\n" || $0 == "\r" }).reversed())
        // Saved with \n line breaks; the terminal needs CRLF or each line would
        // start under the previous line's end (staircase).
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\n", with: "\r\n")
        let payload = text + "\u{1b}[0m\r\n\u{1b}[2m"
            + Self.restoreMarkerText + "\u{1b}[0m\r\n"
        // process_output renders bytes as child output (history), NOT as input —
        // it must never go through text_input or the shell would execute it.
        payload.withCString { ghostty_surface_process_output(s, $0, UInt(strlen($0))) }
    }

    /// Snapshot the pane's current scrollback to disk as colored text (ANSI SGR).
    /// Driven off the hot path (store flush timer + app terminate).
    ///
    /// Main-thread cost is just the grid export: `ghostty_surface_render_grid_json`
    /// (cmux fork) takes the renderer-state lock and serializes the FINAL grid
    /// (viewport + N scrollback rows) with per-cell fg/bg/attrs — clean even for
    /// TUIs (it reads grid state, it is NOT a replay of the raw render stream,
    /// which is what corrupted the earlier byte-tee approach). Decoding that
    /// JSON, rebuilding ANSI text, and the disk write all happen on the archive
    /// queue, which also drops the frame early when the grid hasn't changed.
    func flushScrollbackToDisk() {
        guard let id = scrollbackID, let s = surface else { return }
        let json = ghostty_surface_render_grid_json(s, "", 0, 0, UInt(maxScrollbackLines))
        defer { ghostty_string_free(json) }
        guard let ptr = json.ptr, json.len > 0 else { return }
        let data = Data(bytes: ptr, count: Int(json.len))
        ScrollbackArchive.writeRendered(id: id, gridJSON: data, maxLines: maxScrollbackLines,
                                        priorHistory: restoredHistory,
                                        restoreMarker: Self.restoreMarkerText)
    }

    /// The dim epilogue echoed after restored history. Shared by `restoreScrollback`
    /// (writes it) and `flushScrollbackToDisk` (locates it in the grid to split
    /// off this session's new output). Localized — must match on both sides.
    fileprivate static var restoreMarkerText: String {
        String(localized: "── session restored ──")
    }

    /// Last `maxScrollbackLines` rows of scrollback + screen, with color.
    private let maxScrollbackLines = 3000

    // MARK: render-grid JSON → ANSI text

    private struct RenderGrid: Decodable {
        struct Style: Decodable {
            let id: Int
            let foreground: String
            let background: String
            let bold, faint, italic, underline, blink, inverse, invisible, strikethrough, overline: Bool
        }
        struct Span: Decodable {
            let row: Int
            let column: Int
            let style_id: Int
            let cell_width: Int
            let text: String
        }
        let styles: [Style]
        let row_spans: [Span]
        let scrollback_spans: [Span]
        let scrollback_rows: Int
        let rows: Int
        // Per-row soft-wrap flags (true = row continues into the next). Optional
        // so snapshots written before this field still decode.
        let row_wraps: [Bool]?
        let scrollback_row_wraps: [Bool]?
    }

    private static func rgb(_ hex: String) -> (Int, Int, Int)? {
        guard hex.count == 7, hex.hasPrefix("#"), let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    /// Widest line (in terminal cells) of a saved ANSI scrollback blob. Used to
    /// decide how wide the surface must be before restored history can be echoed
    /// without wrapping. SGR escapes are stripped; CJK/emoji count as 2 cells.
    static func maxDisplayWidth(of data: Data) -> Int {
        let text = String(decoding: data, as: UTF8.self)
        var maxW = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Strip any CSI sequence (SGR `m`, Erase-in-Line `K`, …) so a
            // restored colored fill emitted as `\e[K` doesn't inflate the width
            // and over-raise the echo-width gate.
            let line = rawLine.replacingOccurrences(of: "\u{1b}\\[[0-9;]*[A-Za-z]", with: "",
                                                    options: .regularExpression)
            var w = 0
            for scalar in line.unicodeScalars { w += isWideScalar(scalar) ? 2 : 1 }
            if w > maxW { maxW = w }
        }
        return maxW
    }

    /// Rough east-asian-wide / emoji test — enough to size a restore, not a full
    /// Unicode width table. Box-drawing (U+2500–257F) is intentionally narrow.
    private static func isWideScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    private static func isBlankLine(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Rebuild flat colored text from a render-grid JSON frame. Each span emits
    /// an absolute SGR (reset + attrs + truecolor fg/bg) so ordering is
    /// stable; default-colored spans omit fg/bg so the restored text still
    /// adopts the current theme's default colors instead of being painted with
    /// the capture-time palette.
    fileprivate static func reconstructANSI(fromRenderGrid data: Data, maxLines: Int) -> String? {
        guard let grid = try? JSONDecoder().decode(RenderGrid.self, from: data),
              let defaultStyle = grid.styles.first else { return nil }
        var styleByID: [Int: RenderGrid.Style] = [:]
        for st in grid.styles { styleByID[st.id] = st }

        func sgr(for id: Int) -> String {
            guard let st = styleByID[id] else { return "\u{1b}[0m" }
            var codes = ["0"]
            if st.bold { codes.append("1") }
            if st.faint { codes.append("2") }
            if st.italic { codes.append("3") }
            if st.underline { codes.append("4") }
            if st.blink { codes.append("5") }
            if st.inverse { codes.append("7") }
            if st.invisible { codes.append("8") }
            if st.strikethrough { codes.append("9") }
            if st.overline { codes.append("53") }
            if st.foreground != defaultStyle.foreground, let c = rgb(st.foreground) {
                codes.append("38;2;\(c.0);\(c.1);\(c.2)")
            }
            if st.background != defaultStyle.background, let c = rgb(st.background) {
                codes.append("48;2;\(c.0);\(c.1);\(c.2)")
            }
            return "\u{1b}[" + codes.joined(separator: ";") + "m"
        }

        func renderRegion(_ spans: [RenderGrid.Span], rowCount: Int) -> [String] {
            var byRow: [Int: [RenderGrid.Span]] = [:]
            for sp in spans { byRow[sp.row, default: []].append(sp) }
            let maxRow = max(rowCount - 1, byRow.keys.max() ?? -1)
            guard maxRow >= 0 else { return [] }
            var lines: [String] = []
            lines.reserveCapacity(maxRow + 1)
            for r in 0...maxRow {
                // Assemble the row as (sgr, text) segments so ALL trailing
                // whitespace can be dropped. A row padded out to the capture-
                // time width — a TUI's full-width background fill (agent input
                // boxes), gap padding — otherwise restores as a full-width line
                // that wraps an extra row in the terminal. Restored history is
                // static, so dropping the right-side fill (even colored) is the
                // right trade: no wrap, and the live input box is redrawn fresh
                // by the new session anyway. Border glyphs and rules end in a
                // non-space cell, so they keep their full width untouched.
                let rowSpans = (byRow[r] ?? []).sorted(by: { $0.column < $1.column })
                var segs: [(sgr: String, text: String)] = []
                var col = 0
                for sp in rowSpans {
                    if sp.column > col {
                        segs.append(("\u{1b}[0m", String(repeating: " ", count: sp.column - col)))
                    }
                    segs.append((sgr(for: sp.style_id), sp.text))
                    col = sp.column + sp.cell_width
                }
                // A TUI input box renders its whole row as ONE span — text
                // "› 你好" then padding spaces, all on the same non-default bg —
                // so the row is full-width and wraps when restored. Two moves
                // keep the look without wrapping:
                //  1. Trim trailing whitespace at the CHARACTER level (across
                //     segments) so the stored row is only as wide as its glyphs.
                //  2. If that trimmed tail was a COLORED background fill, repaint
                //     it with Erase-in-Line: emit the box bg + `\e[K`. EL fills
                //     from the cursor to the live terminal's right edge with the
                //     current bg and never advances the cursor, so the box色条
                //     comes back at whatever width the terminal currently is —
                //     width-independent, never wraps. A bordered box ends in a
                //     glyph (not a space), so it's left literal and full-width.
                var fillSGR: String? = nil
                if let last = rowSpans.last,
                   let bg = styleByID[last.style_id]?.background,
                   bg != defaultStyle.background, last.text.last == " " {
                    fillSGR = sgr(for: last.style_id)
                }
                while let last = segs.last {
                    let trimmed = String(last.text.reversed().drop(while: { $0 == " " }).reversed())
                    if trimmed.isEmpty {
                        segs.removeLast()
                    } else {
                        if trimmed != last.text { segs[segs.count - 1].text = trimmed }
                        break
                    }
                }
                var line = ""
                for seg in segs { line += seg.sgr + seg.text }
                if let fill = fillSGR { line += fill + "\u{1b}[K" }
                line += "\u{1b}[0m"
                lines.append(line)
            }
            return lines
        }

        let sbLines = renderRegion(grid.scrollback_spans, rowCount: grid.scrollback_rows)
        let vpLines = renderRegion(grid.row_spans, rowCount: grid.rows)
        let lines = sbLines + vpLines

        // Per-line wrap flags aligned to `lines`. A soft-wrapped row must be
        // re-joined with the next one (no `\n`) so a single logical line that
        // ghostty wrapped across grid rows doesn't restore as several hard
        // lines; the new terminal re-wraps it to its own width.
        var wraps = [Bool](repeating: false, count: lines.count)
        let sbW = grid.scrollback_row_wraps ?? []
        for i in 0..<min(sbLines.count, sbW.count) { wraps[i] = sbW[i] }
        let vpW = grid.row_wraps ?? []
        for i in 0..<min(vpLines.count, vpW.count) { wraps[sbLines.count + i] = vpW[i] }

        var logical: [String] = []
        var current = ""
        var open = false
        for i in 0..<lines.count {
            current += lines[i]
            open = true
            if !(i < wraps.count && wraps[i]) {
                logical.append(current)
                current = ""
                open = false
            }
        }
        if open { logical.append(current) }

        while let last = logical.last, isBlankLine(last) { logical.removeLast() }
        if logical.count > maxLines { logical = Array(logical.suffix(maxLines)) }
        let text = logical.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    // MARK: - surface creation failure UI

    /// Centered "Terminal failed to start" + Retry, shown when ghostty
    /// isn't ready or `ghostty_surface_new` fails. Without it the pane is
    /// just a dead dark rectangle and the only evidence is an NSLog line.
    /// Plain AppKit (no SwiftUI hosting) because this view is below the
    /// SwiftUI layer; colors mirror Theme.text1/text2 — the app is
    /// dark-mode-only so hardcoding the dark values is safe.
    private var surfaceErrorStack: NSStackView?

    private func showSurfaceCreationError() {
        guard surfaceErrorStack == nil else { return }

        let label = NSTextField(labelWithString: String(localized: "Terminal failed to start"))
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(red: 0.925, green: 0.929, blue: 0.949, alpha: 1.0) // Theme.text1
        label.alignment = .center

        let retry = NSButton(title: String(localized: "Retry"),
                             target: self,
                             action: #selector(retrySurfaceCreation(_:)))
        retry.bezelStyle = .rounded
        retry.controlSize = .regular

        let stack = NSStackView(views: [label, retry])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        surfaceErrorStack = stack
    }

    private func removeSurfaceCreationError() {
        surfaceErrorStack?.removeFromSuperview()
        surfaceErrorStack = nil
    }

    @objc private func retrySurfaceCreation(_ sender: Any?) {
        guard surface == nil else { return }
        // createSurface removes the placeholder itself on success.
        createSurface()
        guard surface != nil else { return }  // still failing — keep the placeholder
        // Same post-creation steps viewDidMoveToWindow performs on the
        // happy path: lock CVDisplayLink to the right display and hand
        // keyboard focus to the freshly created surface.
        pushDisplayIDToGhostty()
        window?.makeFirstResponder(self)
    }

    /// Best-effort current cwd: prefers the cached value pushed via ghostty's
    /// PWD action; falls back to proc_pidinfo polling.
    func currentCwd() -> String? {
        if let c = cachedCwd, !c.isEmpty { return c }
        return foregroundCwd()
    }

    /// Query the foreground process' working directory via macOS proc_pidinfo.
    /// Returns nil if there's no surface or the call fails.
    func foregroundCwd() -> String? {
        guard let s = surface else { return nil }
        let pid = ghostty_surface_foreground_pid(s)
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(Int32(pid), PROC_PIDVNODEPATHINFO, 0, ptr, size)
        }
        guard result == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// Foreground process name (e.g. "zsh", "claude", "ssh"). The PTY's
    /// foreground pgrp leader is what's actually attached to user input.
    ///
    /// `pbi_comm` is what the kernel sees, which some programs override —
    /// `claude`, for instance, sets it to its version string ("2.1.169").
    /// When the comm looks like a version number we fall back to argv[0]
    /// via `KERN_PROCARGS2` so the icon still resolves to the binary name.
    func foregroundProcessName() -> String? {
        guard let s = surface else { return nil }
        let pid = ghostty_surface_foreground_pid(s)
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, ptr, size)
        }
        guard result == size else { return nil }
        let comm = withUnsafePointer(to: &info.pbi_comm) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
        if Self.looksLikeVersion(comm), let argv0 = Self.processBasenameFromArgv(pid: Int32(pid)) {
            return argv0
        }
        // npm-installed CLIs (codex, claude, …) run as `node` with the real
        // tool only visible in argv — the bin shim's path. Surface that
        // basename instead so the icon table can match the actual agent.
        if comm == "node", let script = Self.scriptBasenameFromArgv(pid: Int32(pid)) {
            return script
        }
        return comm
    }

    /// Anything matching `^\d+(\.\d+)+` — covers "2.1.169" and friends.
    private static func looksLikeVersion(_ s: String) -> Bool {
        var sawDigit = false
        var sawDot = false
        for c in s {
            if c.isNumber { sawDigit = true }
            else if c == "." { if !sawDigit { return false }; sawDot = true }
            else { return false }
        }
        return sawDigit && sawDot
    }

    /// Read `KERN_PROCARGS2` for `pid` and return the first few argv entries.
    /// Layout: `int argc; char exec_path[]; char argv[0][]; …`.
    private static func processArgv(pid: Int32, limit: Int = 8) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var sz: Int = 0
        if sysctl(&mib, 3, nil, &sz, nil, 0) != 0 || sz == 0 { return nil }
        var buf = [UInt8](repeating: 0, count: sz)
        if sysctl(&mib, 3, &buf, &sz, nil, 0) != 0 { return nil }
        guard sz > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        // Skip argc, then the exec_path C-string and any nul padding.
        var i = MemoryLayout<Int32>.size
        while i < sz && buf[i] != 0 { i += 1 }
        while i < sz && buf[i] == 0 { i += 1 }
        var argv: [String] = []
        while i < sz, argv.count < min(argc, limit) {
            let start = i
            while i < sz && buf[i] != 0 { i += 1 }
            guard i > start else { break }
            argv.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return argv.isEmpty ? nil : argv
    }

    /// Basename of `argv[0]`; the icon table matches on short names.
    private static func processBasenameFromArgv(pid: Int32) -> String? {
        guard let argv0 = processArgv(pid: pid, limit: 1)?.first else { return nil }
        return (argv0 as NSString).lastPathComponent
    }

    /// Basename of the script a `node` process is executing: the first argv
    /// entry after the binary that looks like a path (npm bin shims always
    /// pass one — `node /opt/homebrew/bin/codex` → "codex"). Requiring a
    /// "/" keeps inline code (`node -e '…'`) and a bare REPL out; those
    /// return nil and the caller falls back to the plain comm name.
    private static func scriptBasenameFromArgv(pid: Int32) -> String? {
        guard let argv = processArgv(pid: pid) else { return nil }
        for arg in argv.dropFirst() where !arg.hasPrefix("-") && arg.contains("/") {
            return (arg as NSString).lastPathComponent
        }
        return nil
    }

    // MARK: - resize

    /// Snap our frame to the screen pixel grid, same trick the container does.
    /// AutoLayout drives our frame independently from `NoDragContainerView`'s
    /// snap path — when SwiftUI / split layout hands AppKit a fractional width
    /// (or origin), AppKit calls our setFrameSize / setFrameOrigin directly,
    /// bypassing the container override. The IOSurfaceLayer that ghostty
    /// installs as `view.layer` uses `kCAGravityTopLeft`; if the view sits at
    /// a half-pixel position the compositor linearly resamples the surface
    /// onto the pixel grid and we get a 1px row fault line tearing through
    /// rapidly scrolling output — the same symptom the container snap was
    /// meant to fix, just on a different code path.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(snappedSize(newSize))
        if logVisible {
            NSLog("[glint.visible] setFrameSize pane=\(paneKey ?? "?") -> \(newSize) pending=\(pendingVisibleRedraw)")
        }
        syncSurfaceSize(pointsSize: bounds.size)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(snappedOrigin(newOrigin))
    }

    private func snappedOrigin(_ p: NSPoint) -> NSPoint {
        guard window != nil else { return p }
        return backingAlignedRect(
            NSRect(origin: p, size: frame.size),
            options: [.alignAllEdgesNearest]
        ).origin
    }

    private func snappedSize(_ s: NSSize) -> NSSize {
        guard window != nil else { return s }
        return backingAlignedRect(
            NSRect(origin: frame.origin, size: s),
            options: [.alignAllEdgesNearest]
        ).size
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncSurfaceSize(pointsSize: bounds.size)
    }

    /// Push (contentsScale, ghostty surface size) in one CATransaction with
    /// implicit animations disabled, so the bounds change and ghostty's grid
    /// resize land in the same commit. Ghostty discards stale-sized frames on
    /// present (`IOSurfaceLayer.setSurfaceCallback` checks surface size against
    /// layer bounds × contentsScale), so keeping bounds and scale coherent
    /// within one transaction is what prevents live-resize stretch.
    private func syncSurfaceSize(pointsSize: NSSize) {
        guard let s = surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let pixelWidth = floor(pointsSize.width * scale)
        let pixelHeight = floor(pointsSize.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // ghostty's IOSurfaceLayer only learns the scale at surface creation;
        // re-push so cross-display moves (Retina ↔ non-Retina) re-rasterise
        // at the right DPI. It reads layer.contentsScale when sizing frames.
        layer?.contentsScale = scale
        ghostty_surface_set_content_scale(s, scale, scale)
        ghostty_surface_set_size(s, UInt32(pixelWidth), UInt32(pixelHeight))
        CATransaction.commit()

        // Echo restored history only once the surface width has SETTLED. The
        // window ramps up during launch (e.g. 88 → 180 → 250 cols), and a
        // restored input box repaints its background to the right edge with
        // `\e[K`, which fills to whatever width the terminal is AT ECHO TIME —
        // so echoing at the first frame that merely reaches the content width
        // would stop the fill at the launch-time width, not the final one. Wait
        // until the width holds steady across two passes AND is at least the
        // captured content width (so a full-width bordered box doesn't wrap),
        // then echo. A one-shot fallback echoes at whatever width the surface
        // has reached after a short delay, so history is never lost if the
        // window settles narrow or no further sync pass fires.
        if let data = pendingRestoreData {
            let cols = Int(ghostty_surface_size(s).columns)
            let wideEnough = requiredRestoreCols == 0 || cols >= requiredRestoreCols
            if cols > 0 && wideEnough && cols == lastRestoreProbeCols {
                pendingRestoreData = nil
                restoreScrollback(into: s, data: data)
            } else if cols > 0 {
                lastRestoreProbeCols = cols
                if !restoreFallbackArmed {
                    restoreFallbackArmed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        guard let self, let s = self.surface, let data = self.pendingRestoreData
                        else { return }
                        self.pendingRestoreData = nil
                        self.restoreScrollback(into: s, data: data)
                    }
                }
            }
        }

        // Fire the one-shot redraw queued when this kept-alive surface was
        // re-attached (workspace switch-back). We deferred it to here because
        // `drawFrame` bails on a 0×0 surface and `bounds` is 0 at attach time;
        // now that we've pushed a valid size, force the frame so the pane paints
        // immediately instead of waiting for its next output. `set_size` above is
        // a no-op when the size is unchanged, so this is the only thing that
        // dirties the renderer in the common same-size case.
        if pendingVisibleRedraw {
            pendingVisibleRedraw = false
            ghostty_surface_draw(s)
            if logVisible {
                NSLog("[glint.visible] forced redraw pane=\(paneKey ?? "?") px=\(Int(pixelWidth))x\(Int(pixelHeight))")
            }
        }
    }

    // MARK: - focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let s = surface { ghostty_surface_set_focus(s, true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let s = surface { ghostty_surface_set_focus(s, false) }
        return ok
    }

    /// Explicit focus sync — splits / SwiftUI rebuilds don't always route
    /// firstResponder cleanly, so the SwiftUI layer pokes us directly.
    func setGhosttyFocus(_ flag: Bool) {
        guard let s = surface else { return }
        ghostty_surface_set_focus(s, flag)
    }

    // MARK: - keyboard

    override func keyDown(with event: NSEvent) {
        guard let s = surface else { super.keyDown(with: event); return }
        let mods = event.modifierFlags
        // ⌘V (keycode 9): handle explicitly. Embedded ghostty's default
        // keybindings don't include cmd+v=paste_from_clipboard (standalone
        // ghostty.app wires that through its own Edit menu, which we
        // don't get when embedding), so without this branch the event
        // falls through to `interpretKeyEvents` and macOS types a literal
        // "v" via `insertText`.
        //  - image clipboard → forward ⌃V (0x16); running CLIs (claude
        //    code, codex) read the system clipboard themselves on ⌃V
        //    and attach the image, no literal path leaks into the buffer.
        //  - everything else → ghostty's normal paste path.
        if mods.contains(.command),
           !mods.contains(.shift), !mods.contains(.option), !mods.contains(.control),
           event.keyCode == 9 {
            // Finder file copy → paste the shell-quoted full path(s), same
            // as a drag-drop. Takes priority over the image branch so that
            // copying an image *file* yields its path, not the ⌃V detour.
            if pasteClipboardFileURLs(into: s) {
                return
            }
            if clipboardHasPasteableImage() {
                var syn: UInt8 = 0x16
                withUnsafePointer(to: &syn) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 1) { cptr in
                        ghostty_surface_text_input(s, cptr, 1)
                    }
                }
            } else {
                pasteClipboardText(into: s)
            }
            return
        }
        // ⌘K is terminal muscle memory for clearing the screen/scrollback.
        // Keep it out of app-level shortcuts so it always targets the
        // focused terminal surface. Skip while an IME composition is active —
        // a CJK user mid-composition who hits ⌘K should let AppKit's text
        // path settle the marked text, not have the buffer wiped from under it.
        if mods.contains(.command),
           !mods.contains(.shift), !mods.contains(.option), !mods.contains(.control),
           event.keyCode == 40, !hasMarkedText() {
            triggerBindingAction(s, "clear_screen")
            return
        }
        // Plain Esc: neither claude nor codex emit any hook when the user
        // interrupts a turn (Stop explicitly skips interrupts), so the
        // sidebar would show "thinking" forever. The wrapper does see the
        // keypress — tell the store so it can optimistically flip the
        // pane's agent state back to idle. If the agent wasn't actually
        // interrupted, its next hook event restores the busy status. The
        // event still flows through to ghostty below.
        // Skip while an IME composition is active: plain Esc / Return then
        // cancel or confirm the candidate, not the agent — posting would
        // optimistically flip agent state for a key the agent never received.
        // Same guard the ⌘K and Shift+Return paths already use.
        if event.keyCode == 53,
           mods.intersection([.command, .option, .control, .shift]).isEmpty,
           !hasMarkedText(),
           let pk = paneKey {
            NotificationCenter.default.post(
                name: .glintPaneEscPressed, object: nil, userInfo: ["pane": pk])
        }
        if (event.keyCode == 36 || event.keyCode == 76),
           mods.intersection([.command, .option, .control, .shift]).isEmpty,
           !hasMarkedText(),
           let pk = paneKey {
            NotificationCenter.default.post(
                name: .glintPaneReturnPressed, object: nil, userInfo: ["pane": pk])
        }

        if Self.isShiftReturn(event) && !hasMarkedText() {
            // Let the input method observe the whole Shift+Return chord. Some
            // Chinese IMEs toggle languages on a "standalone" Shift; if Return
            // bypasses AppKit's text-input path, the IME can misclassify the
            // chord and flip Chinese/English mode after inserting the newline.
            // The accumulator swallows insertText/doCommand so this observation
            // pass produces no newline or beep — ghostty still gets the press.
            keyTextAccumulator = []
            interpretKeyEvents([event])
            keyTextAccumulator = nil
            let handled = sendKey(event, action: GHOSTTY_ACTION_PRESS, surface: s)
            if !handled { interpretKeyEvents([event]) }
            return
        }

        let hasBindingMod = mods.contains(.control) || mods.contains(.command)
            || optionActsAsMeta(mods, surface: s)
        if hasBindingMod || Self.isSpecialKey(event.keyCode) {
            // Bindings + special keys (arrows, Return, Backspace, etc.) go
            // through ghostty so it can map them to escape sequences.
            let handled = sendKey(event, action: GHOSTTY_ACTION_PRESS, surface: s)
            if !handled { interpretKeyEvents([event]) }
        } else {
            // Plain printable input goes straight to the macOS text input
            // pipeline. Sending it through ghostty_surface_key with text=nil
            // makes ghostty echo the keycode as a preedit, which shows up as
            // a white-background "marked text" until the user moves the cursor.
            interpretKeyEvents([event])
        }
    }

    private static func isShiftReturn(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return (event.keyCode == 36 || event.keyCode == 76)
            && mods.contains(.shift)
            && !mods.contains(.command)
            && !mods.contains(.option)
            && !mods.contains(.control)
    }

    /// Whether an Option-modified press should be routed through ghostty
    /// (option-as-meta: readline ⌥B/⌥F/⌥D, claude code's ⌥↵, …) instead of
    /// the macOS text-input pipeline. Without this, ⌥B falls through to
    /// `interpretKeyEvents` → `insertText("∫")` and ghostty never sees the
    /// event, so `macos-option-as-alt` is dead config.
    ///
    /// We can't decide this ourselves: on many European layouts Option is
    /// how users type legitimate characters (@, [, {, …) and dead keys, so
    /// hijacking it unconditionally breaks text entry. Ghostty already owns
    /// the decision — `ghostty_surface_key_translation_mods` applies
    /// `macos-option-as-alt` (with per-layout auto-detection when unset,
    /// see embedded.zig) and strips Option from the mods that should be
    /// used for *character translation*. If Option survives translation,
    /// the press is character input and must keep flowing through
    /// `interpretKeyEvents` (dead keys, IME); if it's stripped, Option is a
    /// Meta modifier and the event belongs to ghostty, which then does its
    /// own keymap translation + ESC-prefix encoding via `ghostty_surface_key`.
    private func optionActsAsMeta(_ mods: NSEvent.ModifierFlags,
                                  surface s: ghostty_surface_t) -> Bool {
        guard mods.contains(.option) else { return false }
        // Mid-IME composition (e.g. Japanese henkan) — never steal keys
        // from the input method while marked text is active.
        if hasMarkedText() { return false }
        let translated = ghostty_surface_key_translation_mods(s, currentMods(mods))
        return translated.rawValue & GHOSTTY_MODS_ALT.rawValue == 0
    }

    private static func isSpecialKey(_ keycode: UInt16) -> Bool {
        switch keycode {
        case 36, 48, 51, 53, 76,        // Return, Tab, Backspace, Escape, KeypadEnter
             117,                         // Forward Delete
             123, 124, 125, 126,         // Arrows: Left, Right, Down, Up
             115, 116, 119, 121,         // Home, PgUp, End, PgDn
             122, 120, 99, 118, 96,      // F1-F5
             97, 98, 100, 101, 109,      // F6-F10
             103, 111:                    // F11, F12
            return true
        default:
            return false
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let s = surface else { super.keyUp(with: event); return }
        sendKey(event, action: GHOSTTY_ACTION_RELEASE, surface: s)
    }

    override func flagsChanged(with event: NSEvent) {
        // `flagsChanged` is emitted for both modifier press and release.
        // Sending every edge as PRESS leaves ghostty with phantom Shift
        // events; with IMEs that use Shift to toggle languages this can feel
        // like Shift+Enter fired Shift more than once.
        guard let s = surface else { return }
        guard !hasMarkedText(),
              let action = Self.modifierAction(for: event) else { return }

        var key = ghostty_input_key_s()
        key.action = action
        key.mods = currentMods(event.modifierFlags)
        key.consumed_mods = ghostty_input_mods_e(rawValue: 0)
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.unshifted_codepoint = 0
        key.composing = false
        _ = ghostty_surface_key(s, key)
    }

    /// Map a modifier-only `flagsChanged` event to a press/release action.
    /// Returns nil for keycodes that aren't a known modifier. We use the
    /// device-dependent side masks (left/right) so e.g. releasing the left
    /// Shift while the right is still held still reads as a press.
    private static func modifierAction(for event: NSEvent) -> ghostty_input_action_e? {
        let modifierActive: Bool
        switch event.keyCode {
        case 0x39:
            modifierActive = event.modifierFlags.contains(.capsLock)
        case 0x38, 0x3C:
            modifierActive = event.modifierFlags.contains(.shift)
        case 0x3B, 0x3E:
            modifierActive = event.modifierFlags.contains(.control)
        case 0x3A, 0x3D:
            modifierActive = event.modifierFlags.contains(.option)
        case 0x37, 0x36:
            modifierActive = event.modifierFlags.contains(.command)
        default:
            return nil
        }

        guard modifierActive else { return GHOSTTY_ACTION_RELEASE }

        let flags = event.modifierFlags.rawValue
        let sidePressed: Bool
        switch event.keyCode {
        case 0x38:
            sidePressed = flags & UInt(NX_DEVICELSHIFTKEYMASK) != 0
        case 0x3C:
            sidePressed = flags & UInt(NX_DEVICERSHIFTKEYMASK) != 0
        case 0x3B:
            sidePressed = flags & UInt(NX_DEVICELCTLKEYMASK) != 0
        case 0x3E:
            sidePressed = flags & UInt(NX_DEVICERCTLKEYMASK) != 0
        case 0x3A:
            sidePressed = flags & UInt(NX_DEVICELALTKEYMASK) != 0
        case 0x3D:
            sidePressed = flags & UInt(NX_DEVICERALTKEYMASK) != 0
        case 0x37:
            sidePressed = flags & UInt(NX_DEVICELCMDKEYMASK) != 0
        case 0x36:
            sidePressed = flags & UInt(NX_DEVICERCMDKEYMASK) != 0
        default:
            sidePressed = true
        }

        return sidePressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    }

    @discardableResult
    private func sendKey(_ event: NSEvent,
                         action: ghostty_input_action_e,
                         surface s: ghostty_surface_t) -> Bool {
        var key = ghostty_input_key_s()
        key.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : action
        key.mods = currentMods(event.modifierFlags)
        key.consumed_mods = ghostty_input_mods_e(rawValue: 0)
        key.keycode = UInt32(event.keyCode)
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
        key.composing = hasMarkedText()
        // text=nil — ghostty either handles via keycode (control keys, bindings)
        // or returns false and we fall through to interpretKeyEvents → insertText
        key.text = nil
        return ghostty_surface_key(s, key)
    }

    private func currentMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift)    { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control)  { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)   { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command)  { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    // MARK: - mouse

    /// True while we're swallowing the click that focused this pane.
    /// The first click on an unfocused pane is a focus gesture, not
    /// terminal input — forwarding it would hand mouse-mode TUIs (vim,
    /// htop, claude) a stray click at wherever the cursor happened to be.
    /// We swallow the whole press session (down + drags + up) so ghostty
    /// never sees an unmatched release; the flag clears on mouseUp and
    /// every subsequent click behaves normally.
    private var swallowingFocusClick = false

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
            swallowingFocusClick = true
            return
        }
        // ⌘-click on a file path → open it in the default app. Resolves
        // absolute paths, ~, and paths relative to the surface's cwd. Falls
        // through to ghostty for anything that isn't an existing file, so
        // ⌘-click URL opening and ⌘-drag selection keep working.
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           !event.modifierFlags.contains(.control),
           openFileUnderPointer(event) {
            // Swallow the matching release/drag too, so ghostty never sees
            // this ⌘-click. Otherwise, if the cell also carries an OSC 8
            // hyperlink, ghostty fires its own OPEN_URL and the file opens
            // twice (the second open surfaces a Finder "-50" error).
            swallowingFocusClick = true
            return
        }
        forwardMousePos(event)
        forwardMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseDragged(with event: NSEvent) {
        if swallowingFocusClick { return }
        forwardMousePos(event)
    }

    override func mouseUp(with event: NSEvent) {
        if swallowingFocusClick {
            swallowingFocusClick = false
            return
        }
        forwardMousePos(event)
        forwardMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardMousePos(event)
        forwardMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardMousePos(event)
        forwardMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        forwardMousePos(event)
        let btn = mouseButton(forNumber: event.buttonNumber)
        forwardMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: btn)
    }

    override func otherMouseUp(with event: NSEvent) {
        forwardMousePos(event)
        let btn = mouseButton(forNumber: event.buttonNumber)
        forwardMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: btn)
    }

    /// ghostty's mouse_pos is in logical POINTS with top-left origin,
    /// even though `surface_set_size` is in pixels — the apprt is
    /// expected to do the cell-grid mapping in the same units it laid
    /// out the view with. NSEvent gives us window coords with bottom-
    /// left origin, so convert to view-local and flip Y. (Multiplying
    /// by backingScaleFactor here, like the size call does, makes
    /// every mouse hit land in a cell ~2× to the right and down — the
    /// "selection at wrong position" bug.)
    private func forwardMousePos(_ event: NSEvent) {
        guard let s = surface else { return }
        let local = convert(event.locationInWindow, from: nil)
        let y = bounds.height - local.y
        ghostty_surface_mouse_pos(s, local.x, y, currentMods(event.modifierFlags))
    }

    private func forwardMouseButton(_ event: NSEvent,
                                    state: ghostty_input_mouse_state_e,
                                    button: ghostty_input_mouse_button_e) {
        guard let s = surface else { return }
        _ = ghostty_surface_mouse_button(s, state, button, currentMods(event.modifierFlags))
    }

    private func mouseButton(forNumber n: Int) -> ghostty_input_mouse_button_e {
        switch n {
        case 2:  return GHOSTTY_MOUSE_MIDDLE
        case 3:  return GHOSTTY_MOUSE_FOUR
        case 4:  return GHOSTTY_MOUSE_FIVE
        case 5:  return GHOSTTY_MOUSE_SIX
        case 6:  return GHOSTTY_MOUSE_SEVEN
        case 7:  return GHOSTTY_MOUSE_EIGHT
        case 8:  return GHOSTTY_MOUSE_NINE
        case 9:  return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    override func mouseMoved(with event: NSEvent) {
        forwardMousePos(event)
    }

    override func mouseEntered(with event: NSEvent) {
        forwardMousePos(event)
    }

    override func mouseExited(with event: NSEvent) {
        // Send (-1, -1) so ghostty drops link underline / mouse-mode
        // hover decoration when the pointer leaves the surface.
        guard let s = surface else { return }
        ghostty_surface_mouse_pos(s, -1, -1, currentMods(event.modifierFlags))
    }

    /// Install / refresh the tracking area so we receive `mouseMoved` and
    /// `mouseEntered`/`mouseExited` while the window is key. Without this,
    /// hover-only features (link underline, tmux mouse mode highlights,
    /// cursor shape changes) wouldn't fire.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(t)
        trackingArea = t
    }

    /// macOS cursor lookup whenever the pointer enters our tracking area
    /// or after we invalidate cursor rects. Maps ghostty's CSS-flavored
    /// `mouse_shape` enum onto AppKit's cursor catalogue.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor(for: mouseShape))
    }

    private func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER:        return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:      return .crosshair
        case GHOSTTY_MOUSE_SHAPE_TEXT,
             GHOSTTY_MOUSE_SHAPE_CELL:           return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:  return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
             GHOSTTY_MOUSE_SHAPE_NO_DROP:        return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB:           return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING:       return .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE,
             GHOSTTY_MOUSE_SHAPE_W_RESIZE:       return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
             GHOSTTY_MOUSE_SHAPE_N_RESIZE,
             GHOSTTY_MOUSE_SHAPE_S_RESIZE:       return .resizeUpDown
        default:                                 return .iBeam
        }
    }

    // MARK: - drag-and-drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
            ? .copy
            : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return draggingEntered(sender)
    }

    /// Paste shell-quoted paths into the terminal. Joins multiple files
    /// with a space — handy for `mv a.txt b.txt dest/` style commands.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let s = surface,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return false
        }
        return injectFileURLs(urls, into: s)
    }

    /// If the general pasteboard holds file URLs (a Finder copy), inject
    /// their shell-quoted paths and return true. Returns false when there
    /// are no file URLs so callers can fall through to text/image paths.
    private func pasteClipboardFileURLs(into s: ghostty_surface_t) -> Bool {
        guard let urls = NSPasteboard.general.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }
        return injectFileURLs(urls, into: s)
    }

    /// Inject shell-quoted paths into the terminal. Joins multiple files
    /// with a space — handy for `mv a.txt b.txt dest/` style commands.
    /// Shared by drag-drop and ⌘V/right-click paste of Finder files.
    @discardableResult
    private func injectFileURLs(_ urls: [URL], into s: ghostty_surface_t) -> Bool {
        let joined = urls.map { shellQuote($0.path) }.joined(separator: " ")
        // shellQuote keeps quoting intact, but a filename can legally embed
        // a newline — gate on the actual injected string, same as paste.
        guard confirmUnsafeTextInjection(joined) else { return false }
        joined.withCString { ptr in
            ghostty_surface_text_input(s, ptr, UInt(strlen(ptr)))
        }
        return true
    }

    /// Single-quote a path, escaping embedded single quotes as `'\''`.
    /// Matches what `printf %q` would do for POSIX shells (good enough for
    /// zsh/bash; fish users can adjust their shell anyway).
    private func shellQuote(_ path: String) -> String {
        if !path.contains("'") { return "'\(path)'" }
        return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    // MARK: - ⌘-click to open files

    /// ⌘-click handler: read the word under the pointer and, if it resolves
    /// to an existing file, open it with the system opener. Returns true when
    /// a file was opened so the caller can swallow the click.
    private func openFileUnderPointer(_ event: NSEvent) -> Bool {
        guard let s = surface else { return false }
        // quicklook_word selects at ghostty's tracked cursor position, so
        // make sure it reflects this click before we read the word.
        forwardMousePos(event)
        var text = ghostty_text_s()
        guard ghostty_surface_quicklook_word(s, &text) else { return false }
        defer { ghostty_surface_free_text(s, &text) }
        guard let cstr = text.text, text.text_len > 0 else { return false }
        // `text` is a length-counted const char* (not guaranteed nul-terminated).
        let token = cstr.withMemoryRebound(to: UInt8.self, capacity: Int(text.text_len)) { bytes in
            String(decoding: UnsafeBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
        }
        guard let url = resolveFilePath(token) else { return false }
        // The token is untrusted terminal output — a hostile program can print
        // any path and the user only has to ⌘-click it. Never *launch* code:
        // apps, bundles, installers, URL shortcuts, and anything carrying the
        // POSIX execute bit are revealed in Finder instead of opened with their
        // default handler. Plain documents (source, logs, images, PDFs) open.
        // Shared with the OSC-8 OPEN_URL path via `openOrReveal`.
        Self.openOrReveal(url)
        return true
    }

    /// Launch-capable file types and bundles that must never be opened via
    /// their default handler from untrusted terminal content — they execute
    /// code, run installers, or redirect to arbitrary URLs.
    private static let revealOnlyExtensions: Set<String> = [
        "app", "bundle", "appex", "xpc", "kext", "osax", "prefpane",
        "command", "tool", "terminal", "workflow", "action", "scptd",
        "webloc", "url", "fileloc", "inetloc",
        "pkg", "mpkg", "dmg",
    ]

    /// Open `url` with its default handler, or — when opening it could execute
    /// code (apps, bundles, installers, URL shortcuts, anything with the POSIX
    /// execute bit, packages, directories) — reveal it in Finder instead.
    /// Shared trust boundary for both ⌘-click paths: a plain-text file token
    /// (`openFileUnderPointer`) and an OSC-8 hyperlink whose URL is `file://`
    /// (the OPEN_URL action). Terminal output is untrusted; a hostile program
    /// can print any path or `file://` link and the user only has to click it.
    static func openOrReveal(_ url: URL) {
        if shouldRevealRatherThanOpen(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// True when a ⌘-clicked path should be revealed in Finder rather than
    /// opened, because opening it could execute code.
    private static func shouldRevealRatherThanOpen(_ url: URL) -> Bool {
        if Self.revealOnlyExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .isExecutableKey, .isAliasFileKey,
        ])
        if values?.isDirectory == true || values?.isPackage == true { return true }
        // Execute bit catches bare binaries and runnable scripts regardless of
        // extension. `isExecutableKey` reflects the POSIX x bit for the file.
        if values?.isExecutable == true { return true }
        return false
    }

    /// Resolve a terminal word to a local file URL, or nil if it isn't an
    /// existing file. Strips a stray surrounding quote pair, expands `~`,
    /// and resolves relative paths against the surface's working directory
    /// (OSC 7 cwd, falling back to proc_pidinfo).
    private func resolveFilePath(_ token: String) -> URL? {
        var path = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, let first = path.first, first == path.last,
           first == "'" || first == "\"" {
            path = String(path.dropFirst().dropLast())
        }
        guard !path.isEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        let resolved: String
        if expanded.hasPrefix("/") {
            resolved = expanded
        } else if let cwd = currentCwd(), !cwd.isEmpty {
            resolved = URL(fileURLWithPath: cwd).appendingPathComponent(expanded).path
        } else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: resolved) else { return nil }
        return URL(fileURLWithPath: resolved)
    }

    // MARK: - gestures

    /// Pinch to zoom font size. Tracks accumulated magnification and fires
    /// ghostty's font-size binding action once the delta crosses a small
    /// threshold, so the gesture feels continuous instead of step-like.
    private var pinchAccum: CGFloat = 0
    override func magnify(with event: NSEvent) {
        guard let s = surface else { return }
        pinchAccum += event.magnification
        let step: CGFloat = 0.18
        while pinchAccum >= step {
            triggerBindingAction(s, "increase_font_size:1")
            pinchAccum -= step
        }
        while pinchAccum <= -step {
            triggerBindingAction(s, "decrease_font_size:1")
            pinchAccum += step
        }
    }

    /// Smart-magnify (double-tap on trackpad) → reset font size.
    override func smartMagnify(with event: NSEvent) {
        guard let s = surface else { return }
        triggerBindingAction(s, "reset_font_size")
    }

    @discardableResult
    private func triggerBindingAction(_ s: ghostty_surface_t, _ name: String) -> Bool {
        return name.withCString { ptr in
            ghostty_surface_binding_action(s, ptr, UInt(strlen(ptr)))
        }
    }

    // MARK: - context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "Copy"),
                  action: #selector(menuCopy(_:)),
                  keyEquivalent: "c").target = self
        m.addItem(withTitle: String(localized: "Paste"),
                  action: #selector(menuPaste(_:)),
                  keyEquivalent: "v").target = self
        m.addItem(NSMenuItem.separator())
        m.addItem(withTitle: String(localized: "Select All"),
                  action: #selector(menuSelectAll(_:)),
                  keyEquivalent: "a").target = self
        m.addItem(withTitle: String(localized: "Clear"),
                  action: #selector(menuClear(_:)),
                  keyEquivalent: "k").target = self
        return m
    }

    @objc private func menuCopy(_ sender: Any?) {
        guard let s = surface else { return }
        triggerBindingAction(s, "copy_to_clipboard")
    }

    @objc private func menuPaste(_ sender: Any?) {
        guard let s = surface else { return }
        if pasteClipboardFileURLs(into: s) { return }
        if pasteImageFromClipboardIfPresent() { return }
        pasteClipboardText(into: s)
    }

    /// Read the system clipboard as a string and inject it via
    /// `ghostty_surface_text` (the paste channel — wraps in bracketed
    /// paste sequences when the running app supports it). We bypass
    /// ghostty's `paste_from_clipboard` binding action because that path
    /// goes through `read_clipboard_cb`, which Glint doesn't wire (it
    /// requires tracking the request `state` pointer per surface and
    /// completing asynchronously via `ghostty_surface_complete_clipboard_request`).
    /// Driving paste from the AppKit side keeps the surface explicit.
    private func pasteClipboardText(into s: ghostty_surface_t) {
        guard let str = NSPasteboard.general.string(forType: .string),
              !str.isEmpty else { return }
        guard confirmUnsafeTextInjection(str) else { return }
        str.withCString { ptr in
            ghostty_surface_text(s, ptr, UInt(strlen(ptr)))
        }
    }

    // MARK: - external control injection (control.sock)

    /// A key the external control channel is allowed to inject. Either a named
    /// special key — mapped to a macOS virtual keycode so ghostty emits the
    /// proper escape sequence (arrows, Enter, Esc, …) — or a single printable
    /// ASCII character. Anything outside this whitelist parses to nil; raw
    /// keycodes are intentionally not exposed, to keep the injection surface
    /// small. See docs/external-pane-control.md §4.2.
    enum InjectableKey {
        case special(keycode: UInt16)
        case char(Character)

        static func parse(_ s: String) -> InjectableKey? {
            switch s {
            case "enter", "return": return .special(keycode: 36)
            case "esc", "escape":   return .special(keycode: 53)
            case "tab":             return .special(keycode: 48)
            case "space":           return .special(keycode: 49)
            case "up":              return .special(keycode: 126)
            case "down":            return .special(keycode: 125)
            case "left":            return .special(keycode: 123)
            case "right":           return .special(keycode: 124)
            default:
                if s.count == 1, let c = s.first, c.isASCII, c.isLetter || c.isNumber {
                    return .char(c)
                }
                return nil
            }
        }
    }

    /// Whether the underlying ghostty surface has been created. A view can be
    /// registered (minted) yet not have drawn — injection silently no-ops until
    /// the surface exists, so callers check this to avoid reporting a dropped
    /// inject as success.
    var hasLiveSurface: Bool { surface != nil }

    /// Inject text through the paste channel (bracketed-paste aware), the same
    /// pipe `pasteClipboardText` uses. No unsafe-injection prompt here: the
    /// caller is the gated control socket, not the user's clipboard. Main
    /// thread only (ghostty surface APIs are not thread-safe).
    func injectText(_ text: String) {
        guard let s = surface, !text.isEmpty else { return }
        // UTF-8 length, not strlen: a control-socket payload can carry an
        // embedded NUL (a literal NUL byte), and strlen would truncate the paste at
        // it. withCString's buffer is exactly utf8.count bytes + a NUL, so
        // passing utf8.count never overreads. Mirrors injectKey's char branch.
        let n = text.utf8.count
        text.withCString { ptr in
            ghostty_surface_text(s, ptr, UInt(n))
        }
    }

    /// Inject a single whitelisted key. Special keys go through
    /// `ghostty_surface_key` (press+release) so ghostty maps them to the right
    /// escape sequence; printable chars go straight through the text-input pipe
    /// to avoid the keycode→preedit "marked text" path. Main thread only.
    func injectKey(_ key: InjectableKey) {
        guard let s = surface else { return }
        switch key {
        case .special(let kc):
            var k = ghostty_input_key_s()
            k.mods = ghostty_input_mods_e(rawValue: 0)
            k.consumed_mods = ghostty_input_mods_e(rawValue: 0)
            k.keycode = UInt32(kc)
            k.text = nil
            k.unshifted_codepoint = 0
            k.composing = false
            k.action = GHOSTTY_ACTION_PRESS
            _ = ghostty_surface_key(s, k)
            k.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(s, k)
        case .char(let c):
            var bytes = Array(String(c).utf8)
            bytes.withUnsafeMutableBufferPointer { bp in
                bp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bp.count) { cptr in
                    ghostty_surface_text_input(s, cptr, UInt(bp.count))
                }
            }
        }
    }

    /// True when `text` contains bytes a shell could act on immediately:
    /// newlines (\n / \r — most shells and REPLs execute on CR even inside
    /// bracketed paste when the running program doesn't support it) or C0
    /// control characters other than tab (ESC can rewrite the line, ^C can
    /// kill the foreground job, etc.).
    private func injectedTextLooksUnsafe(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x09 { continue }                 // tab is fine
            if v < 0x20 || v == 0x7F { return true }  // C0 controls + DEL (covers \n, \r)
        }
        return false
    }

    /// Confirmation gate shared by every path that injects outside text
    /// into the pty (clipboard paste, file drag-drop). Returns true when
    /// injection should proceed. Safe text passes silently; risky text
    /// (see `injectedTextLooksUnsafe`) asks first, because a multi-line
    /// paste into a shell prompt executes each line as a command.
    private func confirmUnsafeTextInjection(_ text: String) -> Bool {
        guard injectedTextLooksUnsafe(text) else { return true }
        if UserDefaults.standard.bool(forKey: Self.skipUnsafePasteConfirmKey) { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Paste potentially unsafe text?")
        alert.informativeText = String(
            localized: "The text contains newlines or control characters, which may execute commands immediately."
        )
        alert.addButton(withTitle: String(localized: "Paste"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        // Only honor suppression when the user actually chose Paste — opting
        // out via Cancel + checkbox shouldn't silently green-light future pastes.
        if confirmed, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: Self.skipUnsafePasteConfirmKey)
        }
        return confirmed
    }

    private static let skipUnsafePasteConfirmKey = "glint.skipUnsafePasteConfirmation"

    /// True when the pasteboard holds image bytes worth re-routing through
    /// the running CLI's own ⌃V handler. Finder file-URL copies fall back
    /// to the regular paste path so the user gets the file path, not a
    /// detour through the agent's image-attach flow.
    private func clipboardHasPasteableImage() -> Bool {
        let pb = NSPasteboard.general
        let pbTypes = Set(pb.types ?? [])
        guard pbTypes.contains(.png) || pbTypes.contains(.tiff) else { return false }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            return false
        }
        return true
    }

    /// Right-click "Paste" alternative for image clipboards: write the
    /// image under `~/Library/Caches/Glint/paste/` and inject the
    /// shell-quoted path. Kept around because some users want the
    /// literal path (e.g. to drop it into a shell command) instead of
    /// the ⌃V forwarding the ⌘V hotkey now does.
    private func pasteImageFromClipboardIfPresent() -> Bool {
        guard let s = surface, clipboardHasPasteableImage() else { return false }
        let pb = NSPasteboard.general
        guard let pngData = imagePNGData(from: pb) else { return false }
        guard let path = persistPastedImage(pngData) else { return false }
        let quoted = shellQuote(path)
        quoted.withCString { ptr in
            ghostty_surface_text_input(s, ptr, UInt(strlen(ptr)))
        }
        return true
    }

    /// Pull the best PNG representation we can off the pasteboard. Tries
    /// PNG bytes directly (screenshots), then TIFF (most other sources),
    /// then any NSImage the pasteboard will hand us.
    private func imagePNGData(from pb: NSPasteboard) -> Data? {
        if let data = pb.data(forType: .png) { return data }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        if let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    /// Write to `~/Library/Caches/Glint/paste/glint-paste-<ts>.png`.
    /// Cache directory so macOS can reclaim it; pid+timestamp so
    /// repeated pastes don't collide between panes.
    private func persistPastedImage(_ data: Data) -> String? {
        let fm = FileManager.default
        guard let caches = try? fm.url(for: .cachesDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true) else {
            return nil
        }
        let dir = caches.appendingPathComponent("Glint/paste", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[glint] paste cache dir create failed: \(error)")
            return nil
        }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let url = dir.appendingPathComponent("glint-paste-\(getpid())-\(ts).png")
        do {
            try data.write(to: url, options: [.atomic])
            return url.path
        } catch {
            NSLog("[glint] paste write failed: \(error)")
            return nil
        }
    }

    @objc private func menuSelectAll(_ sender: Any?) {
        guard let s = surface else { return }
        triggerBindingAction(s, "select_all")
    }

    @objc private func menuClear(_ sender: Any?) {
        guard let s = surface else { return }
        triggerBindingAction(s, "clear_screen")
    }

    // MARK: - standard Edit menu hooks
    //
    // SwiftUI's default Edit menu binds ⌘C / ⌘V / ⌘A to the standard
    // `copy:` / `paste:` / `selectAll:` selectors. Implementing them keeps
    // those menu items enabled.
    //
    // `paste:` deliberately does NOT call `menuPaste` — they have different
    // semantics for image clipboards: ⌘V (this hook) forwards ⌃V so the
    // running CLI (claude code, codex) attaches the image directly, while
    // right-click → Paste (menuPaste) writes the image to ~/Library/Caches
    // and pastes the shell-quoted path for use in shell commands. Same
    // image/text split as the ⌘V branch in `keyDown`.

    @objc func paste(_ sender: Any?) {
        guard let s = surface else { return }
        if pasteClipboardFileURLs(into: s) { return }
        if clipboardHasPasteableImage() {
            var syn: UInt8 = 0x16
            withUnsafePointer(to: &syn) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 1) { cptr in
                    ghostty_surface_text_input(s, cptr, 1)
                }
            }
        } else {
            pasteClipboardText(into: s)
        }
    }

    @objc func copy(_ sender: Any?) { menuCopy(sender) }
    @objc override func selectAll(_ sender: Any?) { menuSelectAll(sender) }

    /// Forward scroll wheel events to ghostty. Without this, `scrollWheel`
    /// bubbles up through SwiftUI and ghostty never sees it — scrollback
    /// can't be navigated and mouse-mode apps (vim, htop, claude) miss
    /// their wheel input.
    ///
    /// `ghostty_input_scroll_mods_t` is a packed byte:
    ///   bit 0     — precision (trackpad / Magic Mouse give pixel deltas)
    ///   bits 1-3  — momentum phase (none/began/stationary/changed/ended/…)
    /// see `src/input/mouse.zig` in ghostty for the source of truth.
    override func scrollWheel(with event: NSEvent) {
        guard let s = surface else { super.scrollWheel(with: event); return }
        var packed: Int32 = 0
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            packed |= 1
            // Match upstream Ghostty.app: raw trackpad deltas feel sluggish; ×2 is the
            // tuning the mainline app ships in SurfaceView_AppKit.scrollWheel.
            dx *= 2
            dy *= 2
        }
        let momentum: Int32
        switch event.momentumPhase {
        case .began:      momentum = 1
        case .stationary: momentum = 2
        case .changed:    momentum = 3
        case .ended:      momentum = 4
        case .cancelled:  momentum = 5
        case .mayBegin:   momentum = 6
        default:          momentum = 0
        }
        packed |= momentum << 1
        ghostty_surface_mouse_scroll(s, dx, dy, packed)
    }

    // MARK: - NSTextInputClient (printable text + IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let s as String: text = s
        case let s as NSAttributedString: text = s.string
        default: return
        }
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }
        guard !text.isEmpty, let s = surface else { return }
        text.withCString { ptr in
            // text_input is the IME-aware commit path. Use it for all
            // printable input; surface_text leaves preedit state behind,
            // which ghostty's renderer shows as a white-background highlight.
            ghostty_surface_text_input(s, ptr, UInt(strlen(ptr)))
        }
        // Explicitly clear any residual preedit (commit doesn't always wipe
        // it, leaving underlined ghost text trailing the real input).
        ghostty_surface_preedit(s, nil, 0)
        markedTextValue = NSAttributedString(string: "")
    }

    override func doCommand(by selector: Selector) {
        // During a chord-observation pass (see keyDown's Shift+Return branch)
        // swallow the command — otherwise insertNewline: etc. would beep or
        // double-insert. Normal input falls through to the default handling.
        guard keyTextAccumulator == nil else { return }
        super.doCommand(by: selector)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        switch string {
        case let s as String:
            text = s
        case let s as NSAttributedString:
            text = s.string
        default:
            text = ""
        }
        markedTextValue = NSAttributedString(string: text)
        guard let s = surface else { return }
        if text.isEmpty {
            ghostty_surface_preedit(s, nil, 0)
        } else {
            text.withCString { ptr in
                ghostty_surface_preedit(s, ptr, UInt(strlen(ptr)))
            }
        }
    }

    func unmarkText() {
        markedTextValue = NSAttributedString(string: "")
        guard let s = surface else { return }
        ghostty_surface_preedit(s, nil, 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        markedTextValue.length > 0
            ? NSRange(location: 0, length: markedTextValue.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedTextValue.length > 0
    }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// Anchor IME candidate windows under the real terminal cursor.
    /// Without `ghostty_surface_ime_point` IME would render at our view's
    /// top-left corner; Chinese / Japanese / Korean input would float in
    /// the wrong place.
    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        guard let window, let s = surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(s, &x, &y, &w, &h)
        // ghostty returns the cursor box in view points with top-left origin;
        // AppKit wants view-local points with bottom-left origin. Do not apply
        // backingScaleFactor here: upstream ghostty already reports points.
        let rectInView = NSRect(x: x, y: bounds.height - y, width: w, height: h)
        return window.convertToScreen(convert(rectInView, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }
}

// MARK: - Terminal scrollback restore (colored snapshot via render_grid_json)

/// On-disk store for per-pane scrollback snapshots (ANSI-colored text). Writes
/// run on a background serial queue; reads happen once at surface creation. Each
/// file is capped by `maxScrollbackLines`.
enum ScrollbackArchive {
    private static let queue = DispatchQueue(label: "app.glint.scrollback.io", qos: .utility)

    private static var dir: URL? {
        guard let base = SupportDir.url else { return nil }
        let d = base.appendingPathComponent("scrollback", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Filesystem-safe name from a pane key ("<uuid>:<seq>").
    static func fileID(forPaneKey paneKey: String) -> String {
        String(paneKey.map { ($0 == ":" || $0 == "/") ? "_" : $0 })
    }

    private static func url(for id: String) -> URL? {
        dir?.appendingPathComponent("\(id).ansi", isDirectory: false)
    }

    static func read(id: String) -> Data? {
        guard let u = url(for: id) else { return nil }
        return try? Data(contentsOf: u)
    }
    /// Hash of the raw render-grid JSON from each pane's previous flush.
    /// Guarded by `queue`. NOTE: full-content Hasher, not `Data.hashValue`
    /// (which only hashes a prefix — grid frames share a constant header, so
    /// prefix hashing would report every frame as "unchanged").
    private static var lastGridHash: [String: Int] = [:]

    private static func fullHash(_ data: Data) -> Int {
        var hasher = Hasher()
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    /// Decode a render-grid JSON frame and persist it as colored ANSI text,
    /// entirely off the main thread. When the grid is unchanged since the last
    /// flush (idle pane — the common case for a periodic timer) the frame is
    /// dropped after one cheap hash, skipping the JSON decode, the 3000-line
    /// ANSI rebuild, and the disk write.
    static func writeRendered(id: String, gridJSON: Data, maxLines: Int,
                              priorHistory: String? = nil, restoreMarker: String = "") {
        guard let u = url(for: id) else { return }
        queue.async {
            let h = fullHash(gridJSON)
            if lastGridHash[id] == h { return }
            lastGridHash[id] = h
            guard let full = GhosttySurfaceView.reconstructANSI(
                fromRenderGrid: gridJSON, maxLines: maxLines),
                !full.isEmpty else { return }

            // When this pane restored a prior session, the grid still holds that
            // restored history (we echoed it) plus our "── session restored ──"
            // marker plus this session's fresh output. Re-saving the whole grid
            // would re-render the restored part every flush — piling up dup
            // banners and freezing stale-width rows. Instead keep `priorHistory`
            // as a stable prefix and append only what came AFTER the last marker.
            var text = full
            if let prior = priorHistory, !prior.isEmpty, !restoreMarker.isEmpty {
                let strip = { (s: String) -> String in
                    s.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "",
                                           options: .regularExpression)
                }
                let lines = full.components(separatedBy: "\n")
                if let markerIdx = lines.lastIndex(where: { strip($0).contains(restoreMarker) }) {
                    let newLines = lines[(markerIdx + 1)...]
                    let hasNew = newLines.contains {
                        !strip($0).trimmingCharacters(in: .whitespaces).isEmpty
                    }
                    text = hasNew ? prior + "\n" + newLines.joined(separator: "\n") : prior
                }
                // Marker not found (scrolled past the snapshot window): fall back
                // to the full grid rather than dropping history.
            }

            // Re-cap after the merge — prior + new can exceed the line budget.
            var out = text.components(separatedBy: "\n")
            if out.count > maxLines { out = Array(out.suffix(maxLines)) }
            let final = out.joined(separator: "\n")
            guard !final.isEmpty else { return }
            try? Data(final.utf8).write(to: u, options: [.atomic])
        }
    }

    /// Block until every queued snapshot write has hit disk. Called on app
    /// terminate — the writes are async on a utility queue, so without this
    /// the process can exit with the final flush still in flight.
    static func drain() {
        queue.sync {}
    }

    static func delete(id: String) {
        guard let u = url(for: id) else { return }
        queue.async {
            // Forget the last-flush hash too: with it stale, an unchanged pane
            // would skip its next write and the deleted file would never come back.
            lastGridHash[id] = nil
            try? FileManager.default.removeItem(at: u)
        }
    }

    /// Wipe every snapshot — called when the user turns the feature off, so no
    /// previously-captured history lingers on disk.
    static func purgeAll() {
        queue.async {
            lastGridHash.removeAll()
            guard let dir,
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil) else { return }
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Remove snapshots whose pane no longer exists, plus any leftover files
    /// from earlier designs: `.raw` (byte-tee replay) and `.txt` (plain-text
    /// read_text) — one-time migration to the colored `.ansi` format.
    static func prune(keeping ids: Set<String>) {
        queue.async {
            guard let dir,
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil) else { return }
            for f in files {
                let ext = f.pathExtension
                if ext == "raw" || ext == "txt" { try? FileManager.default.removeItem(at: f); continue }
                guard ext == "ansi" else { continue }
                let id = f.deletingPathExtension().lastPathComponent
                if !ids.contains(id) { try? FileManager.default.removeItem(at: f) }
            }
        }
    }
}
