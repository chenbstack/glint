import XCTest
import GhosttyKit
@testable import Glint

/// String-level regression tests for the terminal accessibility layer
/// (GhosttySurfaceAccessibility.swift). The shapes exercised here mirror
/// what ghostty core's `ScreenFormatter` (`.plain`, `.unwrap = true`,
/// `.trim = false`) emits for `read_text` / `read_selection`.
@MainActor
final class AccessibilityTests: XCTestCase {
    /// The AX layer must read the VIEWPORT, not the whole screen. The
    /// viewport is bounded by window size, so a per-poll `read_text` and
    /// `lineNumber`'s O(index) walk stay cheap however deep the scrollback
    /// gets, and history contents are never handed to an AX client that asks.
    /// Nothing else in the app observes this tag, so without an assertion the
    /// choice reverts to `GHOSTTY_POINT_SCREEN` silently.
    func testAccessibilityReadsViewportNotScrollback() {
        let selection = GhosttySurfaceView.viewportSelection()

        XCTAssertEqual(selection.top_left.tag, GHOSTTY_POINT_VIEWPORT)
        XCTAssertEqual(selection.bottom_right.tag, GHOSTTY_POINT_VIEWPORT)
        XCTAssertEqual(selection.top_left.coord, GHOSTTY_POINT_COORD_TOP_LEFT)
        XCTAssertEqual(selection.bottom_right.coord, GHOSTTY_POINT_COORD_BOTTOM_RIGHT)
        // A rectangle (alt-drag) shape joins partial row segments with
        // newlines the exposed text doesn't contain, which would break
        // `uniqueRange`'s substring mapping.
        XCTAssertFalse(selection.rectangle)
    }

    func testTextUsesUTF16Coordinates() {
        let content = "😀a\n界b"

        XCTAssertEqual(AccessibilityText.utf16Count(content), 6)
        XCTAssertEqual(
            AccessibilityText.substring(in: content, range: NSRange(location: 0, length: 2)),
            "😀"
        )
        XCTAssertEqual(
            AccessibilityText.substring(in: content, range: NSRange(location: 2, length: 1)),
            "a"
        )
        XCTAssertEqual(AccessibilityText.lineNumber(in: content, atUTF16Index: 4), 1)
    }

    func testSelectionMapsAgainstExposedText() {
        let content = "short\nselected 😀 text\nend"
        let selectedText = "selected 😀"

        let range = AccessibilityText.uniqueRange(of: selectedText, in: content)

        XCTAssertEqual(range, NSRange(location: 6, length: 11))
        XCTAssertEqual(range.flatMap { AccessibilityText.substring(in: content, range: $0) }, selectedText)
    }

    func testSelectionRejectsMissingOrAmbiguousMapping() {
        XCTAssertNil(AccessibilityText.uniqueRange(of: "padded", in: "trimmed"))
        XCTAssertNil(AccessibilityText.uniqueRange(of: "same", in: "same\nsame"))
    }

    /// A soft-wrapped line is joined without a newline in the exposed text
    /// (`.unwrap = true`), and a linear selection crossing the wrap junction
    /// is formatted the same way — so it must still map into the exposed
    /// text. The fixture is hand-written, so this pins `uniqueRange` against
    /// a shape the formatter is known to emit; it cannot detect the formatter
    /// itself changing (that claim rests on both calls sharing
    /// `dumpTextLocked`, and would go stale silently).
    func testSelectionSpansSoftWrapJunction() {
        // A 16-col terminal shows "echo 一二三四 five six" as two visual
        // rows ("prompt$ echo 一二三四" / "five six"); the dump joins them
        // into one logical line with no newline at the junction.
        let exposed = "prompt$ echo 一二三四 five six\ndone"
        let selected = "三四 five"

        let range = AccessibilityText.uniqueRange(of: selected, in: exposed)

        XCTAssertEqual(range, NSRange(location: 15, length: 7))
        XCTAssertEqual(range.flatMap { AccessibilityText.substring(in: exposed, range: $0) }, selected)
    }

    /// `.trim = false` keeps mid-line spaces; the formatter only drops blank
    /// cells at the END of a row. A selection padded with trailing spaces
    /// that the formatter trimmed on both sides must still map by its
    /// non-blank text; one whose text simply isn't present must not map.
    func testSelectionAgainstTrailingBlankTrimmedRows() {
        // Visible rows "abc   " and "def" dump as "abc\ndef" — trailing blank
        // cells are trimmed, on both sides, so a user selection of the first
        // row maps by its non-blank text.
        let exposed = "abc\ndef"
        XCTAssertEqual(AccessibilityText.uniqueRange(of: "abc", in: exposed), NSRange(location: 0, length: 3))
        // A selection spanning "abc" through the start of "def" crosses a
        // hard newline and includes it verbatim.
        XCTAssertEqual(AccessibilityText.uniqueRange(of: "abc\nd", in: exposed), NSRange(location: 0, length: 5))
        // Spaces that were never on screen don't map.
        XCTAssertNil(AccessibilityText.uniqueRange(of: "abc   ", in: exposed))
    }

    func testCacheRefetchesOnlyAfterExpiry() async throws {
        var fetchCount = 0
        let cache = CachedValue(duration: .milliseconds(20)) {
            fetchCount += 1
            return fetchCount
        }

        XCTAssertEqual(cache.get(), 1)
        XCTAssertEqual(cache.get(), 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(cache.get(), 2)
    }
}
