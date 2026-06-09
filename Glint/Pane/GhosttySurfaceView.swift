import AppKit
import Darwin
import GhosttyKit

/// AppKit view hosting one `ghostty_surface_t`.
///
/// We give ghostty an `NSView*` via `ghostty_surface_config_s.platform.macos.nsview`;
/// ghostty attaches its own `CAMetalLayer` to the view's layer hierarchy and
/// drives it. We forward keyboard / resize events back into the surface.
final class GhosttySurfaceView: NSView, NSTextInputClient {

    private var surface: ghostty_surface_t?
    private var trackingArea: NSTrackingArea?
    private var markedTextValue: NSAttributedString = NSAttributedString(string: "")
    private let initialCwd: String?
    /// Identifier (`"<wsuuid>:<paneSeq>"`) passed into the pty as
    /// `$GLINT_PANE_ID` so CLI-agent hooks can address us back.
    private let paneKey: String?
    private let agentSocketPath: String?
    /// Latest cwd pushed by ghostty via OSC 7 / PWD action. Preferred over
    /// proc_pidinfo polling because it's event-driven.
    var cachedCwd: String?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    /// NSView's default in borderless windows is YES — that lets the terminal
    /// area drag the whole window. Force NO so clicks here only go to ghostty.
    override var mouseDownCanMoveWindow: Bool { false }

    init(frame: NSRect,
         initialCwd: String? = nil,
         paneKey: String? = nil,
         agentSocketPath: String? = nil) {
        self.initialCwd = initialCwd
        self.paneKey = paneKey
        self.agentSocketPath = agentSocketPath
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.043, green: 0.039, blue: 0.078, alpha: 1.0).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let s = surface { ghostty_surface_free(s) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, surface == nil else { return }
        createSurface()
    }

    private func createSurface() {
        guard let app = GhosttyManager.shared.app else {
            NSLog("GhosttySurfaceView: ghostty app not ready")
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

        // Env vars for CLI-agent hooks (Claude Code etc.) — same strdup
        // discipline; ghostty copies the array during surface_new.
        var envPairs: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        if let pk = paneKey { envPairs.append((strdup("GLINT_PANE_ID"), strdup(pk))) }
        if let sock = agentSocketPath { envPairs.append((strdup("GLINT_AGENT_SOCK"), strdup(sock))) }
        defer { envPairs.forEach { free($0.0); free($0.1) } }

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
            return
        }
        self.surface = s

        let scale = window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_size(s,
                                 UInt32(bounds.width * scale),
                                 UInt32(bounds.height * scale))
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

    /// Read `KERN_PROCARGS2` for `pid` and return the basename of `argv[0]`.
    /// Layout: `int argc; char exec_path[]; char argv[0][]; …`.
    private static func processBasenameFromArgv(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var sz: Int = 0
        if sysctl(&mib, 3, nil, &sz, nil, 0) != 0 || sz == 0 { return nil }
        var buf = [UInt8](repeating: 0, count: sz)
        if sysctl(&mib, 3, &buf, &sz, nil, 0) != 0 { return nil }
        guard sz > MemoryLayout<Int32>.size else { return nil }
        // Skip argc, then the exec_path C-string and any nul padding.
        var i = MemoryLayout<Int32>.size
        // exec_path: read until first \0
        while i < sz && buf[i] != 0 { i += 1 }
        while i < sz && buf[i] == 0 { i += 1 }
        // Now i points at argv[0]. Read until next \0.
        let start = i
        while i < sz && buf[i] != 0 { i += 1 }
        guard i > start else { return nil }
        let argv0 = String(decoding: buf[start..<i], as: UTF8.self)
        // Return basename only; the icon table matches on short names.
        return (argv0 as NSString).lastPathComponent
    }

    // MARK: - resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let s = surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_size(s,
                                 UInt32(newSize.width * scale),
                                 UInt32(newSize.height * scale))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let s = surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_size(s,
                                 UInt32(bounds.width * scale),
                                 UInt32(bounds.height * scale))
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
        let hasBindingMod = mods.contains(.control) || mods.contains(.command)
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
        // Modifier-only events — forward as a key press w/ empty text so
        // ghostty stays in sync with mods.
        guard let s = surface else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = currentMods(event.modifierFlags)
        key.consumed_mods = ghostty_input_mods_e(rawValue: 0)
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.unshifted_codepoint = 0
        key.composing = false
        _ = ghostty_surface_key(s, key)
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

    // MARK: - mouse (minimal: focus on click)

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

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
        if event.hasPreciseScrollingDeltas { packed |= 1 }
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
        ghostty_surface_mouse_scroll(s,
                                     event.scrollingDeltaX,
                                     event.scrollingDeltaY,
                                     packed)
    }

    // MARK: - NSTextInputClient (printable text + IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let s as String: text = s
        case let s as NSAttributedString: text = s.string
        default: return
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

    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let rectInView = NSRect(x: 0, y: 0, width: 1, height: 16)
        let rectInWindow = convert(rectInView, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }
}
