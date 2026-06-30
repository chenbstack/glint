import Foundation

/// Idempotent fenced-block management for shell rc files (`~/.zshrc`,
/// `~/.bashrc`). Used by every installer that maintains a managed block in
/// the user's shell config so they share one set of edge-case handling
/// (line-anchored sentinel match, blank-line normalization on insert,
/// triple-newline collapse on remove) instead of each implementation
/// reinventing it with slightly different bugs.
enum ShellRcBlock {

    /// Insert or replace a fenced block delimited by `begin` and `end`. The
    /// returned text contains exactly one such block.
    ///
    /// - Empty input → just `block + "\n"`.
    /// - Existing block (located by line-anchored sentinel match) → replaced
    ///   in place; surrounding content untouched.
    /// - No existing block → appended with one blank line above so we don't
    ///   smash into a user's last line.
    static func upsert(in text: String,
                       begin: String,
                       end: String,
                       block: String) -> String {
        if let range = locate(in: text, begin: begin, end: end) {
            var out = text
            out.replaceSubrange(range, with: block)
            return out
        }
        if text.isEmpty { return block + "\n" }
        var out = text
        if !out.hasSuffix("\n") { out += "\n" }      // newline before block
        if !out.hasSuffix("\n\n") { out += "\n" }    // one blank line above block
        out += block + "\n"
        return out
    }

    /// Strip a previously-installed block, if any. Collapses any triple
    /// newline left where the block sat so we don't leave a stacked blank
    /// line behind. Returns `text` unchanged when no block is present.
    static func remove(from text: String,
                       begin: String,
                       end: String) -> String {
        guard let range = locate(in: text, begin: begin, end: end) else { return text }
        var out = text
        out.removeSubrange(range)
        if out.hasPrefix("\n") { out.removeFirst() }
        while let triple = out.range(of: "\n\n\n") {
            out.replaceSubrange(triple, with: "\n\n")
        }
        return out
    }

    /// Find the block's full span — `begin` sentinel through `end` sentinel,
    /// including the trailing newline if any. Both sentinels must sit at the
    /// start of their own line, which stops us from matching the sentinel
    /// substring embedded in a user's comment, heredoc, or another tool's
    /// docs — and from a block body that itself quotes the sentinels (an
    /// earlier managed block embedded an opt-out `sed` command containing
    /// both sentinels). To survive that, after a line-anchored `begin` we
    /// keep scanning past `end` matches that aren't at the start of their
    /// own line until we find one that is, instead of trusting the nearest
    /// `end` hit.
    static func locate(in text: String,
                       begin: String,
                       end: String) -> Range<String.Index>? {
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let r = text.range(of: begin, range: cursor..<text.endIndex) {
            let beginAtLineStart = r.lowerBound == text.startIndex ||
                text[text.index(before: r.lowerBound)] == "\n"
            if beginAtLineStart {
                var scan = r.upperBound
                while scan < text.endIndex,
                      let endR = text.range(of: end, range: scan..<text.endIndex) {
                    if text[text.index(before: endR.lowerBound)] == "\n" {
                        var upper = endR.upperBound
                        if upper < text.endIndex, text[upper] == "\n" {
                            upper = text.index(after: upper)
                        }
                        return r.lowerBound..<upper
                    }
                    scan = endR.upperBound
                }
            }
            cursor = r.upperBound
        }
        return nil
    }
}
