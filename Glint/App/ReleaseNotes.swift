import Foundation

/// Hand-authored, per-version "What's New" content. Deliberately INDEPENDENT of
/// the Sparkle appcast (whose notes are built from commit `CN:` trailers) — this
/// is curated, user-facing copy you edit by hand at release time.
///
/// Bilingual copy here is *data*, not UI chrome, so it does NOT go through the
/// string catalog: each entry carries both `en` and `zh` and the right one is
/// picked by the app's current locale (see `WorkspaceStore.whatsNewLines`).
///
/// Versioning model — you author ONE entry per BETA, keyed by its full
/// pre-release version ("0.1.25-beta.1"). Then:
/// - BETA users see the note for the exact pre-release they're on (each beta has
///   its own card).
/// - STABLE users, on reaching "0.1.25", see every "0.1.25-beta.*" entry MERGED
///   into a single "0.1.25" card — the betas roll up into the version's notes.
///   So you normally DON'T author a separate stable entry; the betas are it. (If
///   a version ships without ever going through beta, author a direct stable
///   entry whose `version` is the bare base string "0.1.26".)
struct ReleaseNote: Identifiable {
    /// BETA entry → full pre-release version ("0.1.25-beta.1").
    /// Direct STABLE entry (rare) → bare base version ("0.1.26").
    let version: String
    let en: [String]
    let zh: [String]

    var id: String { version }
}

enum ReleaseNotes {
    /// Strip a pre-release suffix: "0.1.25-beta.1" → "0.1.25"; "0.1.25"/"dev"
    /// pass through unchanged. This is the key the rollup groups betas by.
    static func baseVersion(_ v: String) -> String {
        String(v.prefix(while: { $0 != "-" }))
    }

    /// A pre-release build carries a `-beta.N` suffix; a stable build does not.
    static func isBeta(_ v: String) -> Bool { v.contains("-") }

    /// Display form of a version string: "v0.1.24" for a numeric version, the
    /// raw string otherwise (e.g. "dev"). Shared by the What's New card and the
    /// About pane so the two can't drift.
    static func displayVersion(_ v: String) -> String {
        v.first?.isNumber == true ? "v\(v)" : v
    }

    /// Newest first. Add a new entry at the top each beta.
    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "0.1.24",
            en: [
                "Fixed a launch crash on macOS 15.x where the app would quit immediately after opening (#43). The Sparkle auto-updater no longer starts during SwiftUI's StateObject creation phase, which is what tripped the crash on older macOS versions.",
                "Review Changes now has a keyboard shortcut — press ⌘⇧R from anywhere to open the diff window for the current workspace. The shortcut also shows on the git button's menu.",
                "After each update, a What's New card summarizes what changed in the version. You can reopen it anytime from Settings ▸ About.",
            ],
            zh: [
                "修复 macOS 15.x 上启动即闪退的问题(#43)。Sparkle 自动更新不再在 SwiftUI StateObject 创建阶段同步启动 —— 这正是老版本 macOS 上触发崩溃的根因。",
                "「审阅改动」新增快捷键 —— 在任意位置按 ⌘⇧R 即可为当前工作区打开 diff 窗口,git 按钮菜单里也会标出这个快捷键。",
                "每次更新后会弹出「更新内容」卡片,汇总这一版的变化;也可随时在 设置 ▸ 关于 中重新查看。",
            ]
        ),
    ]

    /// Distinct base versions present in `all`, newest-authored first.
    /// Derived purely from the immutable `all` table, so compute it once.
    private static let baseVersions: [String] = {
        var seen = Set<String>()
        var result: [String] = []
        for note in all {
            let b = baseVersion(note.version)
            if seen.insert(b).inserted { result.append(b) }
        }
        return result
    }()

    /// Roll every entry belonging to `base` (its betas, plus any direct stable
    /// entry) up into ONE note — oldest authored first, so beta.1's lines precede
    /// beta.2's. This is the card a stable user sees for that version.
    static func aggregatedStableNote(base: String) -> ReleaseNote? {
        let members = all.filter { baseVersion($0.version) == base }
        guard !members.isEmpty else { return nil }
        let ordered = Array(members.reversed())   // `all` is newest-first
        return ReleaseNote(version: base,
                           en: ordered.flatMap(\.en),
                           zh: ordered.flatMap(\.zh))
    }

    /// Notes to show when the running version differs from the last-seen one.
    /// - BETA build → every beta of the SAME version from just after the
    ///   last-seen beta up to (and including) `current`, each as its own card.
    ///   So jumping beta.1 → beta.3 still shows beta.2's changes — nothing is
    ///   skipped. When the last-seen build wasn't a beta of this version (fresh
    ///   into the cycle), all of this version's betas up to `current` are shown.
    /// - STABLE build → one aggregated note per base version newer than the
    ///   last-seen one, down to and including `current`. Each base rolls up its
    ///   betas, so a stable user never sees per-beta chatter — just the version.
    ///
    /// Returns [] when the running version has no authored entry (an unwritten
    /// beta, or local "dev" builds).
    static func notesToShow(lastSeen: String?, current: String) -> [ReleaseNote] {
        if isBeta(current) {
            // Betas of this version only, newest-first.
            let base = baseVersion(current)
            let betas = all.filter { isBeta($0.version) && baseVersion($0.version) == base }
            // Compared by full pre-release version. A current with no authored
            // entry yet is treated as the newest, so earlier betas of the cycle
            // still surface. Unknown last-seen (came from an older version /
            // stable) ⇒ the whole cycle, which is naturally bounded to this base.
            let slice = window(betas, key: { $0.version },
                               current: current, lastSeen: lastSeen,
                               fallbackEnd: { _ in betas.count })
            return slice
        }
        // STABLE: one aggregated card per base version. Compared by base, so a
        // beta→stable hop within the same version doesn't re-show it. Unknown or
        // pruned last-seen ⇒ only the current version (don't dump the whole
        // history), via the `currentIdx + 1` fallback.
        let slice = window(baseVersions, key: { $0 },
                           current: current, lastSeen: lastSeen.map(baseVersion),
                           fallbackEnd: { $0 + 1 })
        return slice.compactMap { aggregatedStableNote(base: $0) }
    }

    /// Slice an ordered (newest-first) list to the window strictly between the
    /// current entry and the last-seen one: indices `[currentIdx ..< endIdx)`.
    /// - `current` absent ⇒ treated as newest (index 0), so an as-yet-unauthored
    ///   running version still surfaces everything authored after `lastSeen`.
    /// - `lastSeen` absent ⇒ `fallbackEnd(currentIdx)` bounds the window (callers
    ///   choose: whole cycle for betas, just the current version for stable).
    private static func window<T>(_ items: [T],
                                  key: (T) -> String,
                                  current: String,
                                  lastSeen: String?,
                                  fallbackEnd: (Int) -> Int) -> [T] {
        guard !items.isEmpty else { return [] }
        let currentIdx = items.firstIndex { key($0) == current } ?? 0
        let endIdx = lastSeen
            .flatMap { ls in items.firstIndex { key($0) == ls } }
            ?? fallbackEnd(currentIdx)
        guard currentIdx < endIdx else { return [] }
        return Array(items[currentIdx..<endIdx])
    }

    /// Manual "What's New" (Settings ▸ About): the note for the exact running
    /// version — a beta's own card, or a stable version's rolled-up card. A
    /// real version with no authored entry returns [] rather than borrowing
    /// another version's note (which would mislabel it); only a local non-numeric
    /// build (e.g. "dev") falls back to the latest version so it can be previewed.
    static func currentOrLatest(version: String) -> [ReleaseNote] {
        if isBeta(version) {
            return all.first(where: { $0.version == version }).map { [$0] } ?? []
        }
        if let note = aggregatedStableNote(base: baseVersion(version)) { return [note] }
        guard version.first?.isNumber != true else { return [] }
        return all.first
            .flatMap { aggregatedStableNote(base: baseVersion($0.version)) }
            .map { [$0] } ?? []
    }
}
