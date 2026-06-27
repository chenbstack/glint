import XCTest
@testable import Glint

/// Pure-logic guards for the diff-view tokenizer in `SyntaxHighlighter.swift`.
/// It's a mini char-scanner with cross-line state, so the highest-value checks
/// are: keywords/strings get tinted while plain identifiers don't, block-comment
/// state carries across lines within a hunk, and unknown extensions never tint
/// code as comments/keywords (strings only — never wrongly colored).
final class SyntaxHighlighterTests: XCTestCase {

    /// (substring, is-color-present) per run — lets assertions talk about which
    /// text got tinted without pinning exact Theme colors (those can move).
    private func segments(_ s: AttributedString) -> [(String, Bool)] {
        s.runs.map { (String(s.characters[$0.range]), $0.foregroundColor != nil) }
    }

    /// A Swift line: `let` (keyword) and the string literal are tinted; `name`
    /// (plain lowercase identifier) is not.
    func testColorsKeywordAndStringNotPlainIdentifier() {
        var state = SyntaxHighlighter.State()
        let attr = SyntaxHighlighter.highlight(#"let name = "Glint""#,
                                                language: SyntaxLanguage.from(path: "f.swift"),
                                                state: &state)
        let segs = segments(attr)
        XCTAssertTrue(segs.contains { $0.1 && $0.0 == "let" })              // keyword tinted
        XCTAssertTrue(segs.contains { $0.1 && $0.0.contains("Glint") })    // string tinted
        XCTAssertTrue(segs.contains { !$0.1 && $0.0.contains("name") })    // plain ident left base
        XCTAssertFalse(segs.contains { $0.1 && $0.0.contains("name") })    // …not wrongly tinted
    }

    /// A block comment opened on one line keeps tinting the next line via the
    /// carried `State`, and stays open when the closer is absent.
    func testBlockCommentCarriesAcrossLines() {
        let lang = SyntaxLanguage.from(path: "f.swift")
        var state = SyntaxHighlighter.State()
        SyntaxHighlighter.highlight("/* opening comment", language: lang, state: &state)
        XCTAssertTrue(state.inBlockComment)

        let second = SyntaxHighlighter.highlight("still inside the block", language: lang, state: &state)
        let segs = segments(second)
        XCTAssertEqual(segs.count, 1)                          // whole line is one run
        XCTAssertEqual(segs[0].0, "still inside the block")
        XCTAssertTrue(segs[0].1)                              // …and it's tinted
        XCTAssertTrue(state.inBlockComment)                   // still no closer
    }

    /// Unknown extension (nil language) tints strings but never code as
    /// comments or keywords — so a language we don't know can't be mis-tinted.
    func testUnknownLanguageTintsStringsOnly() {
        var state = SyntaxHighlighter.State()
        let attr = SyntaxHighlighter.highlight(#"x = "y""#, language: nil, state: &state)
        let segs = segments(attr)
        XCTAssertTrue(segs.contains { !$0.1 && $0.0.contains("x") })      // plain ident, base
        XCTAssertTrue(segs.contains { $0.1 && $0.0.contains("y") })       // string tinted
        XCTAssertFalse(state.inBlockComment)                              // no block comment parsing
    }

    /// Markdown tints only backtick inline code; prose must NOT be tinted —
    /// not apostrophe'd words, and crucially not sentence-initial Capitalized
    /// words ("Here", "The"), which the type-coloring rule would otherwise
    /// catch. Regression guard for the .md-over-coloring bug.
    func testMarkdownColorsInlineCodeNotProse() {
        var state = SyntaxHighlighter.State()
        let attr = SyntaxHighlighter.highlight("Here's prose, see `code` now",
                                                language: SyntaxLanguage.from(path: "f.md"),
                                                state: &state)
        let segs = segments(attr)
        XCTAssertTrue(segs.contains { $0.1 && $0.0.contains("code") })    // inline code tinted
        XCTAssertFalse(segs.contains { $0.1 && $0.0.contains("prose") })  // lowercase prose not tinted
        XCTAssertFalse(segs.contains { $0.1 && $0.0.contains("Here") })   // Capitalized prose not tinted
    }

    /// A ```lang fenced block switches to that language's profile for its
    /// body lines, then returns to prose on the closing fence.
    func testMarkdownFencedCodeBlockUsesFencedLanguage() {
        let md = SyntaxLanguage.from(path: "f.md")
        var state = SyntaxHighlighter.State()
        _ = SyntaxHighlighter.highlight("```java", language: md, state: &state)
        XCTAssertNotNil(state.fence)                                       // entered a java fence
        let code = SyntaxHighlighter.highlight("public class Foo {", language: md, state: &state)
        let segs = segments(code)
        XCTAssertTrue(segs.contains { $0.1 && $0.0 == "public" })          // java keyword tinted
        XCTAssertTrue(segs.contains { $0.1 && $0.0 == "class" })
        _ = SyntaxHighlighter.highlight("```", language: md, state: &state)
        XCTAssertNil(state.fence)                                          // fence closed
        // After closing, a Capitalized prose word is NOT tinted (back to prose).
        let after = SyntaxHighlighter.highlight("Back to prose now", language: md, state: &state)
        XCTAssertFalse(segments(after).contains { $0.1 && $0.0.contains("Back") })
    }

    /// ASCII scoping: non-ASCII letters/digits (Greek-uppercase Δ, fraction ½)
    /// must NOT start tinted runs. Character.isLetter/isNumber/isUppercase are
    /// Unicode-aware and would otherwise mis-tokenize code identifiers.
    func testASCIIScopedTokenization() {
        var state = SyntaxHighlighter.State()
        let attr = SyntaxHighlighter.highlight("Δfoo ½bar",
                                                language: SyntaxLanguage.from(path: "f.swift"),
                                                state: &state)
        XCTAssertFalse(segments(attr).contains { $0.1 })
    }
}
