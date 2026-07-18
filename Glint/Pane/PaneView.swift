import SwiftUI

struct PaneView: View {
    @EnvironmentObject var store: WorkspaceStore
    /// Captured by value when the tree was rendered — never read live from
    /// the store here. See the comment on `PaneTreeView.workspaceID` for why
    /// (stale evaluation of the outgoing tree during a workspace switch).
    let workspaceID: UUID?
    let paneID: PaneID

    /// When the terminal is translucent every SwiftUI fill behind the surface
    /// must be clear — an opaque `Theme.bgPane` here sits *between* the alpha
    /// IOSurface and the clear window and re-opacifies the pane (the original
    /// "终端没透" bug). At full opacity we keep bgPane as a flash-guard.
    private var paneBacking: Color {
        store.isTerminalTransparent ? Color.clear : Theme.bgPane
    }

    private var unfocusedDimOpacity: Double {
        if Theme.current.isDark {
            return store.isTerminalTransparent ? 0.18 : 0.28
        }
        // Light themes need only a subtle inactive hint. The old 0.28 black
        // wash turned white terminal panes into a heavy gray block.
        return store.isTerminalTransparent ? 0.05 : 0.035
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
            paneBacking
        }
    }

    private func paneBody(workspaceID: UUID,
                          focusedPane: PaneID,
                          cwd: String?) -> some View {
        if ProcessInfo.processInfo.environment["GLINT_LOG_VISIBLE"] != nil {
            NSLog("[glint.visible] PaneView.body pane=\(paneID.value) ws=\(workspaceID.uuidString.prefix(8))")
        }
        let isFocused = TerminalFocusPolicy.isPaneFocused(
            workspaceIsSelected: workspaceID == store.selectedWorkspaceID,
            paneIsFocused: focusedPane == paneID
        )
        return ZStack {
            paneBacking
            PaneSurfaceRepresentable(
                surfaceView: store.surfaceView(workspaceID: workspaceID, paneID: paneID, cwd: cwd),
                focused: isFocused,
                deferFocus: store.commandPaletteOpen || store.agentChooserIntent != nil
            )
            if !isFocused {
                // Use a black wash so translucent panes stay translucent; tune
                // the strength by theme so light terminals don't turn gray.
                Color.black.opacity(unfocusedDimOpacity)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.focus(paneID) }
    }
}
