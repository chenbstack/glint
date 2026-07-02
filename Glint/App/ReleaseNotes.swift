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

    /// Newest first. **Do not pre-write entries** — only add the new entry
    /// at the moment a version is being tagged. Pre-written placeholders
    /// drift from what actually ships (a `0.1.24-beta.1` placeholder once
    /// went out as a bare `0.1.24` after a hotfix detour, and lines added
    /// to that placeholder later got mis-attributed). See CLAUDE.md
    /// "发版「更新内容」" for the release-time workflow.
    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "0.1.25-beta.6",
            en: [
                "Review now refreshes automatically when its window regains focus, keeps the selected file in sync with filters, and stays smoother while resizing the file sidebar. The file list also handles narrow sidebars better so change counts no longer wrap awkwardly.",
                "Light mode multi-pane terminals now use a much lighter inactive-pane tint, so unfocused panes still read as the same white terminal surface instead of turning gray."
            ],
            zh: [
                "Review 窗口重新获得焦点时会自动刷新改动,筛选文件后选中项和右侧 diff 会保持同步;拖动左侧文件栏时也更稳定。文件列表在窄侧栏下也更耐挤,改动数量不再竖着换行。",
                "亮色模式下多终端窗格的失焦遮罩大幅变轻,未聚焦窗格仍然像同一个白色终端表面,不会再明显发灰。"
            ]
        ),
        ReleaseNote(
            version: "0.1.25-beta.5",
            en: [
                "zsh panes now show your most recent matching history command as faint inline text right after the cursor — press → or End to accept. Toggle in Settings ▸ Terminal ▸ Command suggestions (defaults on). Glint installs a small fenced block in ~/.zshrc that sources the vendored zsh-autosuggestions script; flipping the toggle off strips that block cleanly. If you already load zsh-autosuggestions through oh-my-zsh / prezto / your own config, Glint detects it and stays out of the way. Bash / fish panes are unaffected. The ghost text is rendered by zsh as real terminal cells, so font, spacing, and alignment always match the surrounding line — no SwiftUI overlay drift."
            ],
            zh: [
                "zsh 窗格在你输入时,光标后会用浅色显示最近一条匹配的历史命令 —— 按 → 或 End 接受。在 设置 ▸ 终端 ▸ 命令提示 控制开关(默认开)。Glint 会在 ~/.zshrc 末尾维护一小段带围栏的代码块,引入随包发行的 zsh-autosuggestions 脚本;关掉开关会把这段干净地删除。如果你已经通过 oh-my-zsh / prezto / 自己的配置 加载了 zsh-autosuggestions,Glint 会让路、不重复加载、不打扰你既有设置。bash / fish 窗格不受影响。提示文本由 zsh 直接渲染成真实终端字符,字体、间距与上下文完全对齐,不会再有任何浮层错位。"
            ]
        ),
        ReleaseNote(
            version: "0.1.25-beta.4",
            en: [
                "Review goes remote — start an SSH session in a pane, run Review, and Glint follows the remote shell's cwd to diff changes there just like a local repo. Hardened single-quoting on the SSH layer so funky path characters can't break the wire command, and remote-title parsing now handles IPv6 bracketed hosts.",
                "Diff view now does syntax highlighting (Swift, TS/JS, Python, Go, Rust, JSON, YAML, and more), walked independently for old/new sides so a `/*` you removed doesn't bleed comment color onto the lines after it.",
                "Changes Only mode now takes an adjustable context-line count — grow the surrounding lines when the default isn't enough to make a hunk read.",
                "Launch focuses the terminal instead of the sidebar search field — no more ⌘1 / Esc to snap focus back.",
                "Small polish: selected workspace no longer shows the extra left accent bar (just the wash); the macOS notification toggle description now states clearly that it only fires while Glint is in the background."
            ],
            zh: [
                "Review 跨 SSH 了 —— 在窗格里开远程 shell,直接 Review,Glint 跟着远程当前目录抓 diff,跟本地仓库体验一致。SSH 那一层做了严格的单引号转义,路径里的特殊字符不会破坏远端命令;远程标题解析也兼容 IPv6 方括号格式。",
                "Diff 视图加入语法高亮(Swift、TS/JS、Python、Go、Rust、JSON、YAML 等),新旧两侧各自独立走状态机,删掉的 `/*` 不会把后面的行误染成注释。",
                "「仅显示改动」模式可调上下文行数 —— 默认行数看着不够时随手往上加。",
                "启动后焦点直接落到终端,不再先停在左侧搜索框 —— 不用再 ⌘1 / Esc 把焦点抢回来。",
                "细节:选中的工作区不再多一根左侧 accent 竖条,只留底色;通用设置里的 macOS 通知说明改成「仅 Glint 后台时触发」,避免误以为前台也会弹。"
            ]
        ),
        ReleaseNote(
            version: "0.1.25-beta.3",
            en: [
                "Review window got a big upgrade: side-by-side (split) and unified diff modes, a Changes Only toggle, ignore-whitespace, and Opt+↑/↓ to jump between changes — all switchable from the file header. Plus a root-vs-current-directory toggle so Review (and Reveal in Finder) reads diffs from the side you actually meant when you're in a subdirectory.",
                "Settings ▸ Terminal now has a CJK fallback font picker — pick a separate font for Chinese / Japanese / Korean characters when your main monospace font doesn't cover them.",
                "Optional macOS notification when an agent finishes or needs your attention (Settings ▸ General). Routes through Notification Center, so it still reaches you when Glint is in the background.",
                "Codex Home is now remembered per pane, so workspaces with non-default Homes resume correctly after a restart (#49)."
            ],
            zh: [
                "Review 窗口大升级：并排（split）和统一（unified）两种 diff 视图、Changes Only 切换、忽略空白差异、Opt+↑/↓ 在改动间跳转，全部在文件 header 一键切换。子目录场景还新增了「仓库根 vs 当前目录」开关，让 Review 和「在访达中显示」从你真正想看的那一侧读 diff。",
                "终端设置新增 CJK 回退字体下拉 —— 主等宽字体不覆盖中日韩字符时，可独立挑一款 fallback。",
                "Agent 任务完成或需要关注时可选弹原生 macOS 通知（设置 ▸ 通用），通过通知中心送达，Glint 在后台时也能收到。",
                "Codex Home 按窗格独立记忆，非默认 Home 的工作区重启后能正确 resume (#49)。"
            ]
        ),
        ReleaseNote(
            version: "0.1.25-beta.2",
            en: [
                "Light mode now applies to the whole app, not just the terminal — chrome (window, sidebar, glass capsules, dropdowns, sheets) follows your Glint theme instead of staying dark.",
                "Reworked the light sidebar: real `.sidebar` vibrancy with an app-active-aware wash, a beveled inner-shadow + hairline + highlight divider, slimmer accent-tinted selection (with a 3pt accent indicator on the active row), and quieter metadata chips.",
                "Scrollback is now a memory budget (5 / 10 / 25 / 50 / 100 / 250 MB) instead of a row count, matching what Ghostty actually enforces. The picker shows an estimated line range that varies with pane width; old row-count settings auto-migrate."
            ],
            zh: [
                "亮色模式现在覆盖整个应用，不只是终端 —— 窗口、sidebar、玻璃浮岛、下拉菜单、Sheet 等 chrome 都跟 Glint 主题走，不再被钉死在暗色。",
                "亮色 sidebar 整体重做：真 `.sidebar` vibrancy + 跟随应用前/后台的色温微调，立体的内阴影 + 发丝线 + 高光分隔条，更轻的 accent 染色选中态（当前行左侧加一根 3pt accent 指示条），metadata 标签也调成低噪样式。",
                "Scrollback 改成按内存预算配置（5 / 10 / 25 / 50 / 100 / 250 MB），跟 Ghostty 实际的限制语义对齐。下拉里给出基于面板宽度的估算行数范围；老的行数设置会自动迁移到对应档位。"
            ]
        ),
        ReleaseNote(
            version: "0.1.25-beta.1",
            en: [
                "Hardened the dock badge code path that triggered a launch crash on macOS 15.1 (#43) — `NSApp` is now treated as optional during early init so a brief nil window can't trap.",
                "Each agent pane now resumes its own session on restart instead of every pane in a workspace collapsing onto the most recent one (#45). Captures session ids from Claude / Codex / OpenCode / Devin hook events, falls back to the prior `--continue` form when no id has been captured yet.",
                "Added ⌘⇧F to reveal the focused pane's working directory in Finder — works in any workspace, not just git ones."
            ],
            zh: [
                "加固 macOS 15.1 启动崩溃路径 (#43)：dock 徽章里 `NSApp` 在启动早期可能仍为 nil，强解触发 trap；现改为可选解包，nil 时静默 no-op、并把首次刷新推到 launch 完成之后。",
                "重启恢复时每个 agent 窗格各自接回自己的会话 (#45)，不再被合并到工作区里最近一次的会话。Claude / Codex / OpenCode / Devin 各自从 hook 事件里抓 session id 写入对应窗格，恢复时精确 `--resume <id>` / `--session <id>`；老数据没抓到 id 时退回原 `--continue` / `--last`。",
                "新增 ⌘⇧F「在访达中显示」全局快捷键，定位当前窗格的工作目录，非 git 工作区也能用。"
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
