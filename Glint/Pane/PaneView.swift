import SwiftUI

struct PaneView: View {
    @EnvironmentObject var store: WorkspaceStore
    /// Captured by value when the tree was rendered — never read live from
    /// the store here. See the comment on `PaneTreeView.workspaceID` for why
    /// (stale evaluation of the outgoing tree during a workspace switch).
    let workspaceID: UUID?
    let paneID: PaneID
    private var terminalBacking: Color {
        store.terminalUseGhosttyConfig ? .clear : Theme.bgPane
    }

    var body: some View {
        // Resolve a surface only for a (workspace, pane) pair that exists in
        // the model. A miss means we're either mid-teardown (workspace
        // deleted, pane closed) or a stale evaluation — rendering a plain
        // background for one frame is correct there; minting a surface for a
        // synthetic key would spawn a shell that nothing ever shows again.
        if let wsID = workspaceID,
           let ws = store.workspaces.first(where: { $0.id == wsID }),
           let pane = ws.panes[paneID] {
            paneBody(workspaceID: wsID,
                     focusedPane: ws.selectedTab?.focusedPane ?? paneID,
                     cwd: pane.workingDirectory)
        } else {
            terminalBacking
        }
    }

    private func paneBody(workspaceID: UUID,
                          focusedPane: PaneID,
                          cwd: String?) -> some View {
        if ProcessInfo.processInfo.environment["GLINT_LOG_VISIBLE"] != nil {
            NSLog("[glint.visible] PaneView.body pane=\(paneID.value) ws=\(workspaceID.uuidString.prefix(8))")
        }
        let isFocused = focusedPane == paneID
        return ZStack {
            terminalBacking
            PaneSurfaceRepresentable(
                surfaceView: store.surfaceView(workspaceID: workspaceID, paneID: paneID, cwd: cwd),
                focused: isFocused
            )
            if !isFocused {
                Color.black.opacity(store.terminalUseGhosttyConfig ? 0.18 : 0.45)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.focus(paneID) }
    }
}
