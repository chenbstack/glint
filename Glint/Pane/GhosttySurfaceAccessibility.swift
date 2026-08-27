import AppKit
import GhosttyKit

// MARK: - Accessibility
//
// Voice-input assistants (Qianwen dictation and friends) and screen readers
// probe the FOCUSED element's AX role to decide whether the frontmost app has
// a text field they can type into. Terminal.app / iTerm2 / Ghostty.app all
// expose their terminal surface as AXTextArea; without these overrides this
// view reports the NSView default (AXGroup), so Qianwen's hotkey input falls
// back to its "no input field" quick-action popup (记便签 / 问千问 / 复制)
// instead of typing here. Mirrors upstream ghostty's SurfaceView_AppKit
// accessibility extension, plus a settable AXSelectedText (the standard
// dictation insertion attribute) routed into the same pipe as `insertText`.

extension GhosttySurfaceView {
    /// Indicates that this view should be exposed to accessibility tools like VoiceOver.
    override func isAccessibilityElement() -> Bool {
        return true
    }

    /// We use .textArea because the terminal surface is essentially an editable
    /// text area where users can input commands and view output.
    override func accessibilityRole() -> NSAccessibility.Role? {
        return .textArea
    }

    override func accessibilityHelp() -> String? {
        return String(localized: "Terminal content area")
    }

    override func accessibilityValue() -> Any? {
        return cachedVisibleContents.get()
    }

    /// Range of text currently selected in the string exposed through AXValue.
    /// Ghostty's offsets are terminal-cell coordinates, so only report a range
    /// when the selected text maps unambiguously into that formatted string.
    ///
    /// The mapping is sound because both `ghostty_surface_read_selection` and
    /// `ghostty_surface_read_text` funnel into the same core path
    /// (`dumpTextLocked` → `selectionString` → `ScreenFormatter` with
    /// `.unwrap = true, .trim = false`), so a linear selection's text is a
    /// verbatim substring of the exposed text — soft-wrapped lines join the
    /// same way in both, and trailing blank cells are trimmed by the same
    /// per-row rule. Cases that can't map degrade to `NSNotFound` instead of
    /// reporting a wrong range: rectangle (alt-drag) selections join partial
    /// row segments with newlines that don't exist in the exposed text, and
    /// selections extending into scrollback history aren't contained in the
    /// viewport-only AXValue.
    override func accessibilitySelectedTextRange() -> NSRange {
        let notFound = NSRange(location: NSNotFound, length: 0)
        guard let surface = surface else { return notFound }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return notFound }
        defer { ghostty_surface_free_text(surface, &text) }
        let selectedText = String(cString: text.text)
        return AccessibilityText.uniqueRange(
            of: selectedText,
            in: cachedVisibleContents.get()
        ) ?? notFound
    }

    override func accessibilitySelectedText() -> String? {
        guard let surface = surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let str = String(cString: text.text)
        return str.isEmpty ? nil : str
    }

    /// Dictation-style insertion channel: setting AXSelectedText means "type
    /// this at the cursor". A terminal has no editable text, so the text goes
    /// straight down `insertText` — the IME-aware commit pipe — rather than a
    /// copy of it, so preedit cleanup, the marked-text reset and the
    /// chord-observation accumulator can't drift out of sync with it.
    /// Implementing the setter also makes
    /// `AXUIElementIsAttributeSettable(kAXSelectedText)` report true, which
    /// Qianwen's editable-element detection checks.
    ///
    /// This is the third path that injects outside text into the pty, but
    /// unlike clipboard paste and drag-drop it cannot *ask*: AX writes are
    /// synchronous IPC, so raising `confirmUnsafeTextInjection`'s modal here
    /// would block the caller until its AX request times out. Text a shell
    /// would act on immediately (newlines, C0 controls) is therefore refused
    /// outright instead of confirmed — dictation never needs it, and an AX
    /// client that wants to run commands has to say so through a channel the
    /// user can see.
    override func setAccessibilitySelectedText(_ text: String?) {
        guard let text, !text.isEmpty, surface != nil else { return }
        guard !injectedTextLooksUnsafe(text) else { return }
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func accessibilityNumberOfCharacters() -> Int {
        let content = cachedVisibleContents.get()
        return AccessibilityText.utf16Count(content)
    }

    /// For terminals, we typically show all content as visible.
    override func accessibilityVisibleCharacterRange() -> NSRange {
        let content = cachedVisibleContents.get()
        return NSRange(location: 0, length: AccessibilityText.utf16Count(content))
    }

    override func accessibilityLine(for index: Int) -> Int {
        let content = cachedVisibleContents.get()
        return AccessibilityText.lineNumber(in: content, atUTF16Index: index)
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let content = cachedVisibleContents.get()
        return AccessibilityText.substring(in: content, range: range)
    }

    /// Right now this only applies font information (same trade-off as
    /// upstream ghostty; per-run colors would need ghostty core support).
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let surface = surface,
              let plainString = accessibilityString(for: range) else { return nil }

        var attributes: [NSAttributedString.Key: Any] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }
        return NSAttributedString(string: plainString, attributes: attributes)
    }
}

/// Pure-string helpers behind the `NSTextInputClient`-style accessibility
/// overrides above. All indices/ranges are UTF-16 (`NSString`) coordinates,
/// which is what the AX APIs expect.
enum AccessibilityText {
    static func utf16Count(_ text: String) -> Int {
        (text as NSString).length
    }

    static func substring(in text: String, range: NSRange) -> String? {
        let text = text as NSString
        guard range.location != NSNotFound,
              range.location <= text.length,
              range.length <= text.length - range.location else { return nil }
        return text.substring(with: range)
    }

    static func lineNumber(in text: String, atUTF16Index index: Int) -> Int {
        let clampedIndex = min(max(index, 0), utf16Count(text))
        return text.utf16.prefix(clampedIndex).reduce(into: 0) { line, codeUnit in
            if codeUnit == 0x0A { line += 1 }
        }
    }

    /// Maps selected text into the exposed text's UTF-16 coordinates. Returns
    /// the range only when it is unambiguous: nil if the text is absent, or
    /// occurs more than once (a wrong-but-plausible range is worse for AX
    /// clients than no range at all).
    static func uniqueRange(of selectedText: String, in exposedText: String) -> NSRange? {
        let exposedText = exposedText as NSString
        guard !selectedText.isEmpty else { return nil }

        let first = exposedText.range(of: selectedText)
        guard first.location != NSNotFound else { return nil }

        let nextLocation = first.location + 1
        if nextLocation <= exposedText.length {
            let remaining = NSRange(
                location: nextLocation,
                length: exposedText.length - nextLocation
            )
            guard exposedText.range(of: selectedText, range: remaining).location == NSNotFound else {
                return nil
            }
        }
        return first
    }
}

/// Caches a value for a short period on the AppKit main actor. Expiration is
/// checked on demand so no background task can race with accessibility polls.
@MainActor
final class CachedValue<T> {
    private var value: T?
    private var expiresAt: ContinuousClock.Instant?
    private let fetch: @MainActor () -> T
    private let duration: Duration

    init(duration: Duration, fetch: @escaping @MainActor () -> T) {
        self.duration = duration
        self.fetch = fetch
    }

    func get() -> T {
        let now = ContinuousClock.now
        if let value, let expiresAt, now < expiresAt {
            return value
        }

        // No cached value (or it expired) — fetch and store.
        let result = fetch()
        self.value = result
        self.expiresAt = now + duration

        return result
    }
}
