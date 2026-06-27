import Foundation
import SwiftUI

// MARK: - Language model

/// A token-coloring profile for one language family — comment/string syntax
/// plus a keyword set. Pure data, `Sendable`, so a `DiffDocument` can be
/// parsed (and highlighted) off the main actor.
///
/// ponytail: this is token coloring, not a real grammar. It nails single-line
/// constructs (keywords, strings, line/block comments, numbers, Capitalized
/// types) and carries block-comment / triple-string state across lines within
/// a hunk. Known ceilings: a multi-line construct opening above a hunk's first
/// line isn't tracked, and deleted lines share the new-file state stream (a
/// del line inside an old-file block comment may be mis-tinted). Both are
/// low-salience for a read-only diff; upgrade to tree-sitter only if they bite.
struct SyntaxLanguage: Sendable {
    let lineComments: [String]                   // prefixes: "//", "#", "--"
    let blockComment: (open: String, close: String)?
    let tripleStrings: [String]                  // "\"\"\"", "'''"
    let stringQuotes: [Character]                // single-char: " ' `
    let escapes: Bool                            // honor backslash escapes inside strings
    let keywords: Set<String>
    /// Prose formats (markdown, plain text) set this false so stray digits in a
    /// sentence ("see section 3") aren't tinted as numbers.
    var highlightNumbers: Bool = true
    /// Prose formats set this false so sentence-initial Capitalized words
    /// ("The", "Here") aren't tinted as if they were type names.
    var highlightTypes: Bool = true
    /// Markdown fences a sub-language (```lang blocks); only the markdown
    /// profile sets this, switching to that language's profile inside a fence.
    var parsesFencedCode: Bool = false

    /// Resolve a profile from a path's extension. nil for unknown → caller
    /// colors strings + numbers only (no comment/keyword tinting), so nothing
    /// is ever wrongly colored on a language we don't know.
    static func from(path: String) -> SyntaxLanguage? {
        let ext = (path as NSString).pathExtension.lowercased()
        return table[ext]
    }

    /// Resolve a profile from a Markdown fence info string or language name
    /// (e.g. "java", "javascript", "ts"). Takes the first word. nil if not
    /// recognized → caller falls back to generic (strings + numbers).
    static func from(languageName: String) -> SyntaxLanguage? {
        guard let word = languageName.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true).first else { return nil }
        let key = String(word)
        return table[key] ?? fenceAliases[key]
    }

    private static let table: [String: SyntaxLanguage] = {
        var t: [String: SyntaxLanguage] = [:]
        for (exts, lang) in all { for e in exts { t[e] = lang } }
        return t
    }()

    private static let all: [([String], SyntaxLanguage)] = [
        (["swift"], swift),
        (["c", "h", "m", "mm", "cc", "cpp", "cxx", "c++", "hpp", "hxx", "hh",
          "java", "js", "mjs", "cjs", "jsx", "ts", "tsx", "cs", "kt", "kts",
          "scala", "dart", "php"], cLike),
        (["go", "golang"], go),
        (["rs", "rust"], rust),
        (["py", "pyi", "python", "rb", "ruby", "sh", "bash", "zsh", "fish",
          "cmake", "mk", "make"], script),
        // Config/data formats: `#` comments + strings + numbers, but NO
        // keywords and NO type tinting — YAML `if:`/`do:` keys and Capitalized
        // values must not be tinted as code.
        (["yaml", "yml", "toml", "ini", "cfg", "conf", "properties",
          "dockerfile"], config),
        (["sql"], sql),
        // Prose: don't treat ' / " as strings (apostrophes in English would
        // otherwise gulp whole sentences). Markdown tints only inline `code`.
        (["md", "markdown", "mdx"], markdown),
        (["txt", "text", "rst", "log", "csv", "tsv"], plain),
    ]

    // MARK: profiles

    private static let blockC = (open: "/*", close: "*/")

    private static let cLike = SyntaxLanguage(
        lineComments: ["//"], blockComment: blockC, tripleStrings: [],
        stringQuotes: ["\"", "'"], escapes: true,
        keywords: [
            // C / C++ / ObjC / Java / JS / TS / C# / Kotlin shared core.
            "abstract", "as", "async", "await", "boolean", "break", "byte",
            "case", "catch", "char", "class", "const", "continue", "default",
            "delete", "do", "double", "else", "enum", "extends", "extern",
            "final", "finally", "float", "for", "friend", "function", "goto",
            "if", "implements", "import", "in", "inline", "instanceof", "int",
            "interface", "let", "long", "namespace", "native", "new", "nil",
            "nullptr", "operator", "override", "package", "private", "protected",
            "public", "register", "restrict", "return", "short", "signed",
            "sizeof", "static", "struct", "super", "switch", "synchronized",
            "template", "this", "throw", "throws", "transient", "try", "typedef",
            "typename", "typeof", "union", "unsigned", "using", "var", "virtual",
            "void", "volatile", "while", "yield", "true", "false", "NULL",
            "record", "sealed", "readonly", "partial", "get", "set", "value",
            "dynamic", "alias", "type",
        ])

    private static let swift = SyntaxLanguage(
        lineComments: ["//"], blockComment: blockC, tripleStrings: ["\"\"\""],
        stringQuotes: ["\""], escapes: true,
        keywords: [
            "func", "let", "var", "if", "else", "guard", "for", "while", "switch",
            "case", "default", "return", "struct", "class", "enum", "protocol",
            "extension", "import", "init", "deinit", "self", "Self", "super",
            "nil", "true", "false", "public", "private", "internal", "fileprivate",
            "open", "package", "static", "final", "throw", "throws", "rethrows",
            "try", "catch", "defer", "where", "as", "is", "in", "override",
            "convenience", "required", "mutating", "nonmutating", "lazy",
            "subscript", "operator", "associatedtype", "typealias", "weak",
            "unowned", "repeat", "break", "continue", "fallthrough", "async",
            "await", "some", "any", "actor", "distributed", "didSet", "willSet",
            "get", "set", "indirect", "consuming", "borrowing", "macro",
        ])

    private static let go = SyntaxLanguage(
        lineComments: ["//"], blockComment: blockC, tripleStrings: [],
        stringQuotes: ["\"", "'", "`"], escapes: true,
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer",
            "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
            "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var", "nil", "true", "false", "iota",
        ])

    private static let rust = SyntaxLanguage(
        lineComments: ["//"], blockComment: blockC, tripleStrings: [],
        stringQuotes: ["\""], escapes: true,
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn",
            "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
            "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
            "self", "Self", "static", "struct", "super", "trait", "true", "type",
            "unsafe", "use", "where", "while", "Some", "None", "Ok", "Err",
        ])

    private static let script = SyntaxLanguage(
        lineComments: ["#"], blockComment: nil,
        tripleStrings: ["\"\"\"", "'''"], stringQuotes: ["\"", "'"], escapes: true,
        keywords: [
            // Python / Ruby / shell common.
            "def", "class", "if", "elif", "else", "for", "while", "return",
            "import", "from", "as", "pass", "break", "continue", "in", "is",
            "not", "and", "or", "with", "try", "except", "finally", "raise",
            "yield", "lambda", "global", "nonlocal", "assert", "del", "True",
            "False", "None", "self", "end", "do", "then", "begin", "case",
            "when", "until", "unless", "function", "echo", "export", "local",
            "source", "unset", "set", "alias",
        ])

    /// Config/data formats (YAML, TOML, INI, …): `#` comments, strings, and
    /// numbers only. No keyword set and no type tinting, so keys like `if:`/
    /// `do:` and Capitalized values aren't tinted as code.
    private static let config = SyntaxLanguage(
        lineComments: ["#"], blockComment: nil, tripleStrings: [],
        stringQuotes: ["\"", "'"], escapes: true, keywords: [],
        highlightTypes: false)

    private static let sql = SyntaxLanguage(
        lineComments: ["--"], blockComment: blockC, tripleStrings: [],
        stringQuotes: ["'", "\""], escapes: false,
        keywords: [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE",
            "SET", "DELETE", "CREATE", "TABLE", "DROP", "ALTER", "ADD", "JOIN",
            "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AS", "AND", "OR", "NOT",
            "NULL", "IS", "IN", "LIKE", "BETWEEN", "ORDER", "BY", "GROUP",
            "HAVING", "LIMIT", "OFFSET", "DISTINCT", "UNION", "INDEX", "PRIMARY",
            "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "CONSTRAINT", "UNIQUE",
            "CHECK", "CASE", "WHEN", "THEN", "ELSE", "END", "BEGIN", "COMMIT",
            "ROLLBACK", "TRUE", "FALSE",
        ])

    /// Markdown: only backtick inline `code` and fenced code blocks are tinted;
    /// prose (including apostrophes like "it's") is left alone, and `#`
    /// headers aren't comments.
    private static let markdown = SyntaxLanguage(
        lineComments: [], blockComment: nil, tripleStrings: [],
        stringQuotes: ["`"], escapes: false, keywords: [],
        highlightNumbers: false, highlightTypes: false, parsesFencedCode: true)

    /// Plain text: tint nothing.
    private static let plain = SyntaxLanguage(
        lineComments: [], blockComment: nil, tripleStrings: [],
        stringQuotes: [], escapes: false, keywords: [],
        highlightNumbers: false, highlightTypes: false)

    /// Fence info-string aliases not already covered by the extension table
    /// (java / py / ts / ... resolve via `table`). For ```lang code blocks.
    private static let fenceAliases: [String: SyntaxLanguage] = [
        "javascript": cLike, "typescript": cLike,
        "csharp": cLike, "kotlin": cLike,
        "objc": cLike, "objective-c": cLike, "objectivec": cLike,
        "shell": script, "console": script, "terminal": script,
        "text": plain, "plaintext": plain,
    ]

    /// Unknown-extension profile: strings + numbers only. No comment or
    /// keyword tinting, so it never colors anything wrongly.
    fileprivate static let generic = SyntaxLanguage(
        lineComments: [], blockComment: nil, tripleStrings: [],
        stringQuotes: ["\"", "'"], escapes: true, keywords: [])
}

// MARK: - Tokenizer

enum SyntaxHighlighter {
    /// Cross-line state carried between lines within one hunk so a block
    /// comment / triple-quoted string opened on an earlier line keeps tinting
    /// its continuation lines. Reset at each `@@` hunk header by the caller.
    struct State: Sendable {
        var inBlockComment = false
        var inTriple: String? = nil
        /// Non-nil while inside a Markdown ``` / ~~~ fenced code block; lines
        /// are then tinted with `lang`'s profile instead of markdown prose.
        struct Fence: Sendable { let lang: SyntaxLanguage; let char: Character }
        var fence: Fence? = nil
    }

    /// Color `line`'s tokens into an `AttributedString`. Token ranges carry a
    /// `.foregroundColor` attribute; everything else is left unattributed so
    /// the caller's base `.foregroundStyle` shows through (keeps the row's
    /// add/delete tint on neutral text).
    static func highlight(_ line: String, language: SyntaxLanguage?, state: inout State) -> AttributedString {
        let lang = language ?? .generic
        if lang.parsesFencedCode {
            return scanMarkdown(line, markdown: lang, state: &state)
        }
        return scan(Array(line), lang: lang, state: &state)
    }

    // MARK: Markdown fence handling

    private static func scanMarkdown(_ line: String, markdown: SyntaxLanguage, state: inout State) -> AttributedString {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })

        // Closing fence (only meaningful inside one): same char, nothing after.
        if state.fence != nil, let m = fenceMarker(trimmed), m.char == state.fence?.char, m.rest.isEmpty {
            state.fence = nil
            state.inBlockComment = false; state.inTriple = nil
            return tinted(line, Theme.text3)
        }
        // Opening fence: 3+ backticks/tildes; the info string names the lang.
        if state.fence == nil, let m = fenceMarker(trimmed) {
            state.fence = State.Fence(lang: resolveFenceLang(m.rest), char: m.char)
            state.inBlockComment = false; state.inTriple = nil
            return tinted(line, Theme.text3)
        }
        // Inside a fence: tint with the fenced language's profile.
        if let f = state.fence {
            return scan(Array(line), lang: f.lang, state: &state)
        }
        // Markdown prose — only inline `code` tints.
        return scan(Array(line), lang: markdown, state: &state)
    }

    private struct Marker { let char: Character; let rest: String }

    /// `s` begins with 3+ backticks or tildes → marker char + the trailing
    /// info string (e.g. "java"). ` ```java ` → ('`', "java"). nil otherwise.
    private static func fenceMarker(_ s: Substring) -> Marker? {
        guard let first = s.first, first == "`" || first == "~" else { return nil }
        var idx = s.startIndex
        while idx < s.endIndex && s[idx] == first { idx = s.index(after: idx) }
        guard s.distance(from: s.startIndex, to: idx) >= 3 else { return nil }
        let rest = String(s[idx...]).trimmingCharacters(in: .whitespaces)
        return Marker(char: first, rest: rest)
    }

    /// Resolve a fence info string (e.g. "java", "javascript") to a profile,
    /// falling back to generic (strings + numbers) if unrecognized.
    private static func resolveFenceLang(_ info: String) -> SyntaxLanguage {
        SyntaxLanguage.from(languageName: info) ?? .generic
    }

    private static func tinted(_ line: String, _ color: Color) -> AttributedString {
        var s = AttributedString(line)
        s.foregroundColor = color
        return s
    }

    // ASCII-scoped class checks. Code tokens are ASCII; using Character's
    // Unicode-aware isNumber/isLetter/isUppercase would let non-ASCII digits
    // (½, fullwidth １) and letters (Δ, É) start or over-extend tinted runs.
    @inline(__always) private static func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
    @inline(__always) private static func isLetter(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }
    @inline(__always) private static func isUpper(_ c: Character) -> Bool { c >= "A" && c <= "Z" }

    private static func scan(_ a: [Character], lang: SyntaxLanguage, state: inout State) -> AttributedString {
        let n = a.count
        var i = 0
        var runs: [(String, Color?)] = []

        let linePrefixes = lang.lineComments.map { Array($0) }
        let blockOpen = lang.blockComment.map { Array($0.0) }
        let blockClose = lang.blockComment.map { Array($0.1) }
        let triples = lang.tripleStrings.map { Array($0) }
        let quotes = Set(lang.stringQuotes)
        let keywords = lang.keywords

        @inline(__always)
        func match(_ pre: [Character], _ t: Int) -> Bool {
            guard t + pre.count <= n else { return false }
            for k in 0..<pre.count where a[t + k] != pre[k] { return false }
            return true
        }
        func find(_ needle: [Character], from t: Int) -> Int? {
            let m = needle.count
            guard m > 0 else { return nil }
            var j = t
            while j + m <= n {
                var ok = true
                for k in 0..<m where a[j + k] != needle[k] { ok = false; break }
                if ok { return j }
                j += 1
            }
            return nil
        }
        func slice(_ lo: Int, _ hi: Int) -> String { String(a[lo..<hi]) }

        // Entering mid-construct from a previous line: finish it first.
        if state.inBlockComment, let close = blockClose {
            if let c = find(close, from: i) {
                let e = c + close.count
                runs.append((slice(i, e), Theme.text3))
                i = e
                state.inBlockComment = false
            } else {
                runs.append((slice(i, n), Theme.text3))
                return build(runs)
            }
        }
        if let triple = state.inTriple {
            let needle = Array(triple)
            if let c = find(needle, from: i) {
                let e = c + needle.count
                runs.append((slice(i, e), Theme.green))
                i = e
                state.inTriple = nil
            } else {
                runs.append((slice(i, n), Theme.green))
                return build(runs)
            }
        }

        while i < n {
            let c = a[i]

            // Line comment → rest of line.
            if linePrefixes.contains(where: { match($0, i) }) {
                runs.append((slice(i, n), Theme.text3))
                break
            }

            // Block comment (may run past EOL → carry state).
            if let open_ = blockOpen, match(open_, i) {
                if let close = blockClose, let c = find(close, from: i + open_.count) {
                    let e = c + close.count
                    runs.append((slice(i, e), Theme.text3))
                    i = e
                } else {
                    runs.append((slice(i, n), Theme.text3))
                    state.inBlockComment = true
                    break
                }
                continue
            }

            // Triple-quoted string (may run past EOL → carry state).
            if let t = triples.first(where: { match($0, i) }) {
                if let c = find(t, from: i + t.count) {
                    let e = c + t.count
                    runs.append((slice(i, e), Theme.green))
                    i = e
                } else {
                    runs.append((slice(i, n), Theme.green))
                    state.inTriple = String(t)
                    break
                }
                continue
            }

            // Single-quoted string (unterminated → tint to EOL, no state).
            if quotes.contains(c) {
                var j = i + 1
                while j < n {
                    if lang.escapes && a[j] == "\\" { j += 2; continue }
                    if a[j] == c { j += 1; break }
                    j += 1
                }
                runs.append((slice(i, min(j, n)), Theme.green))
                i = min(j, n)
                continue
            }

            // Number (loose: digits + hex/exp/suffix letters + ._).
            if lang.highlightNumbers && (isDigit(c) || (c == "." && i + 1 < n && isDigit(a[i + 1]))) {
                var j = i + 1
                while j < n {
                    let d = a[j]
                    if isLetter(d) || isDigit(d) || d == "." || d == "_" { j += 1 } else { break }
                }
                runs.append((slice(i, j), Theme.orange))
                i = j
                continue
            }

            // Identifier / keyword / Type.
            if isLetter(c) || c == "_" {
                var j = i + 1
                while j < n {
                    let d = a[j]
                    if isLetter(d) || isDigit(d) || d == "_" { j += 1 } else { break }
                }
                let word = slice(i, j)
                if keywords.contains(word) {
                    runs.append((word, Theme.accentBright))
                } else if lang.highlightTypes && isUpper(c) {
                    runs.append((word, Theme.cyan))
                } else {
                    runs.append((word, nil))
                }
                i = j
                continue
            }

            runs.append((slice(i, i + 1), nil))
            i += 1
        }

        return build(runs)
    }

    /// Fold runs into one `AttributedString`, coalescing adjacent uncolored
    /// runs so a line of plain punctuation isn't a hundred tiny appends.
    private static func build(_ runs: [(String, Color?)]) -> AttributedString {
        var out = AttributedString()
        var pending = ""
        for (text, color) in runs {
            guard !text.isEmpty else { continue }
            if let color {
                if !pending.isEmpty { out += AttributedString(pending); pending = "" }
                var s = AttributedString(text)
                s.foregroundColor = color
                out += s
            } else {
                pending += text
            }
        }
        if !pending.isEmpty { out += AttributedString(pending) }
        return out
    }
}
