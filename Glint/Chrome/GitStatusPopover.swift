import SwiftUI
import AppKit

// Lightweight git status popover, opened from the header git button
// (`HeaderGitButton` in ContentView). Requirement: full path/branch live in a
// popover, not a right-side panel. Status comes from the store's polled cache
// (Plan B git). Shows for either a worktree workspace (gold "WT") or any
// workspace whose focused pane cwd is inside a git repo.

struct GitStatusPopover: View {
    @EnvironmentObject var store: WorkspaceStore
    let ws: Workspace
    var close: () -> Void = {}

    private var status: GitStatus? { store.gitStatus(for: ws.id) }
    private var isWT: Bool { ws.source.isWorktree }
    private var path: String? { ws.source.worktreePath ?? store.effectiveGitPath(for: ws) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                if isWT {
                    Text("WT").font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.82))
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.orange))
                } else {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(store.accent)
                }
                Text(ws.displayName).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer(minLength: 12)
            }

            HStack(spacing: 7) {
                cell("BRANCH", ws.source.branch ?? status?.branch ?? "—", tint: Theme.text1)
                cell("UPSTREAM", status?.upstream ?? "—", tint: Theme.text1)
            }
            HStack(spacing: 7) {
                cell("AHEAD / BEHIND",
                     status.map { "↑\($0.ahead) ↓\($0.behind)" } ?? "—",
                     tint: (status?.ahead ?? 0) > 0 || (status?.behind ?? 0) > 0 ? Theme.green : Theme.text1)
                cell("CHANGES",
                     status.map(changesText) ?? "—",
                     tint: (status?.dirtyCount ?? 0) > 0 ? Theme.orange : Theme.green)
            }

            if let subj = status?.lastCommitSubject {
                cell("LAST COMMIT",
                     subj + (status?.lastCommitRelative.map { " · \($0)" } ?? ""),
                     tint: Theme.text2, full: true)
            }

            if let path {
                Text(path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.28)))
            }

            // Read-only review of the changes in this workspace: opens a separate
            // window with the changed-file list + unified diff (working-tree vs
            // HEAD, and — for worktrees — the whole branch vs its base).
            if path != nil {
                popButton("Review Changes…", prominent: true) {
                    close()
                    store.openReview(for: ws)
                }
            }

            // A plain git workspace isn't isolated — offer the one-click jump to
            // a worktree cut from this very repo (the "switch to a worktree"
            // affordance the tab branch chip implies).
            if !isWT, path != nil {
                popButton("New Worktree from Here…", prominent: true) {
                    close()
                    store.openNewWorkspace(repoHint: path)
                }
            }

            HStack(spacing: 7) {
                popButton("Reveal in Finder") { store.revealWorktreeInFinder(ws.id) }
                popButton("Copy Path") {
                    if let p = path {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(p, forType: .string)
                    }
                }
            }
        }
        .padding(13)
        .frame(width: 330)
        .background(Theme.bgPane)
        .onAppear { Task { await store.refreshGitStatus(for: ws.id) } }
    }

    /// Localized `CHANGES` value. Keeps the English singular/plural split (and
    /// gives each a catalog key) so other languages translate the noun freely.
    private func changesText(_ s: GitStatus) -> String {
        switch s.dirtyCount {
        case 0:  return String(localized: "clean")
        case 1:  return String(localized: "1 file")
        default: return String(localized: "\(s.dirtyCount) files")
        }
    }

    // `k`/`title` are LocalizedStringKey so the column headers and buttons go
    // through the string catalog; `v` stays a plain String — it's live data
    // (branch name, path, commit subject) that must not be translated.
    private func cell(_ k: LocalizedStringKey, _ v: String, tint: Color, full: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k).font(.system(size: 9, weight: .semibold)).kerning(0.3).foregroundStyle(Theme.text4)
            Text(v).font(.system(size: full ? 11.5 : 12.5, weight: full ? .medium : .semibold))
                .foregroundStyle(tint).lineLimit(full ? 2 : 1).truncationMode(.middle)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.overlay(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func popButton(_ title: LocalizedStringKey, prominent: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? store.accent : Theme.text2)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? store.accent.opacity(0.14) : Theme.overlay(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(prominent ? store.accent.opacity(0.30) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
