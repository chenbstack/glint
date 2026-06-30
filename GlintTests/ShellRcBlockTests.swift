import XCTest
@testable import Glint

/// `ShellRcBlock.locate` is the engine behind every managed `~/.zshrc` block's
/// install / remove (inline suggestions, shell keybinds). The hard case is a
/// block whose body itself quotes the sentinel text — Glint's own inline
/// suggestion block used to embed an opt-out `sed` command containing both
/// sentinels, and the nearest `end` match was that embedded (non-line-anchored)
/// one, so `locate` returned nil and toggling the setting off never stripped
/// the block. These tests lock the line-anchored scan that fixed it.
final class ShellRcBlockTests: XCTestCase {

    private let begin = "# >>> glint inline suggestions >>>"
    private let end   = "# <<< glint inline suggestions <<<"

    /// The regression: a block body that quotes the sentinels (the old managed
    /// block, which embedded a sed one-liner referencing both) must still be
    /// located and fully removed.
    func testRemoveBlockWhoseBodyQuotesSentinels() {
        let block = """
        \(begin)
        # Managed by Glint. Toggle in Settings → Terminal → Command suggestions.
        #   sed -i '' '/\(begin)/,/\(end)/d' ~/.zshrc
        [ -f "$HOME/.config/glint/inline-suggestions.zsh" ] && source "$HOME/.config/glint/inline-suggestions.zsh"
        \(end)
        """
        let text = "alias ss=moshpit\n\n" + block + "\nalias foo=bar\n"

        let removed = ShellRcBlock.remove(from: text, begin: begin, end: end)

        XCTAssertFalse(removed.contains("inline-suggestions"),
                       "block body should be gone; got:\n\(removed)")
        XCTAssertTrue(removed.contains("alias ss=moshpit"), "content above must survive")
        XCTAssertTrue(removed.contains("alias foo=bar"), "content below must survive")
    }

    func testRemovePlainBlock() {
        let text = "a\n\(begin)\nsource x\n\(end)\nb\n"
        XCTAssertEqual(ShellRcBlock.remove(from: text, begin: begin, end: end),
                       "a\nb\n")
    }

    func testRemoveIsNoOpWhenNoBlock() {
        let text = "just user config\n"
        XCTAssertEqual(ShellRcBlock.remove(from: text, begin: begin, end: end), text)
    }

    func testRemoveIsNoOpWhenOnlySentinelSubstringInAComment() {
        // Sentinel text not at line start must not be treated as a block.
        let text = "# see \(begin) somewhere\nuser config\n"
        XCTAssertEqual(ShellRcBlock.remove(from: text, begin: begin, end: end), text)
    }

    func testUpsertReplacesBlockInPlace() {
        // `upsert` consumes the newline after `end`, so the replacement block
        // must carry its own trailing newline (the real managed block does).
        let old = "pre\n\(begin)\nold body\n\(end)\npost\n"
        let new = "\(begin)\nnew body\n\(end)\n"
        let result = ShellRcBlock.upsert(in: old, begin: begin, end: end, block: new)
        XCTAssertEqual(result, "pre\n\(begin)\nnew body\n\(end)\npost\n")
    }

    func testUpsertAppendsWhenAbsent() {
        let result = ShellRcBlock.upsert(in: "user config\n",
                                         begin: begin, end: end,
                                         block: "\(begin)\nx\n\(end)")
        XCTAssertEqual(result, "user config\n\n\(begin)\nx\n\(end)\n")
    }

    func testUpsertReplacesBlockThatQuotesSentinelsInBody() {
        // Idempotent re-apply on launch must rewrite a block whose body quotes
        // the sentinels (the regression), not append a second block.
        let old = "pre\n\(begin)\n#   sed -i '' '/\(begin)/,/\(end)/d' ~/.zshrc\n\(end)\npost\n"
        let updated = "\(begin)\nnew\n\(end)\n"
        let result = ShellRcBlock.upsert(in: old, begin: begin, end: end, block: updated)
        XCTAssertEqual(result, "pre\n\(begin)\nnew\n\(end)\npost\n")
    }
}
