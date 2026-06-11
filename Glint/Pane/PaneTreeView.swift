import SwiftUI
import AppKit

struct PaneTreeView: View {
    let node: SplitNode
    /// The workspace this tree belongs to, captured by value at render time.
    /// PaneView must NOT read `store.selectedWorkspaceID` live instead: when
    /// the selection changes, SwiftUI still evaluates the outgoing tree's
    /// PaneViews once before dismantling them, and a live read there pairs
    /// the NEW workspace ID with the OLD tree's pane IDs — minting phantom
    /// surfaces (spawning shells!) and re-parenting the new workspace's
    /// surface into a container that is about to be torn down, leaving the
    /// real pane blank.
    let workspaceID: UUID?
    /// Branch choices from the root to `node` (false = first child, true =
    /// second). Identifies this subtree to `WorkspaceStore.setSplitRatio`.
    var path: [Bool] = []

    var body: some View {
        switch node {
        case .leaf(let id):
            PaneView(workspaceID: workspaceID, paneID: id)
        case .split(let dir, let ratio, let a, let b):
            SplitContainer(direction: dir, ratio: ratio, path: path,
                           workspaceID: workspaceID, a: a, b: b)
        }
    }
}

/// Two child trees laid out by the split's stored ratio, separated by a 1px
/// line with an invisible 9pt drag handle floating over it. Dragging writes
/// the ratio back to the store, so it persists with the rest of the tree.
private struct SplitContainer: View {
    @EnvironmentObject var store: WorkspaceStore
    let direction: SplitDirection
    let ratio: CGFloat
    let path: [Bool]
    let workspaceID: UUID?
    let a: SplitNode
    let b: SplitNode

    /// Ratio at drag start; nil when not dragging. Drag math works off this
    /// base so the divider tracks the cursor instead of compounding deltas.
    @State private var dragBaseRatio: CGFloat?
    @State private var hovering = false

    /// Don't let either side shrink below this. Roughly a minimal readable
    /// terminal strip; the ratio clamp in the store is the second guard.
    private static let minPaneLength: CGFloat = 100

    private var isHorizontal: Bool { direction == .horizontal }

    var body: some View {
        GeometryReader { geo in
            let total = isHorizontal ? geo.size.width : geo.size.height
            let firstLength = firstLength(total: total)

            ZStack(alignment: .topLeading) {
                if isHorizontal {
                    HStack(spacing: 0) {
                        PaneTreeView(node: a, workspaceID: workspaceID, path: path + [false])
                            .frame(width: firstLength)
                        divider
                        PaneTreeView(node: b, workspaceID: workspaceID, path: path + [true])
                    }
                } else {
                    VStack(spacing: 0) {
                        PaneTreeView(node: a, workspaceID: workspaceID, path: path + [false])
                            .frame(height: firstLength)
                        divider
                        PaneTreeView(node: b, workspaceID: workspaceID, path: path + [true])
                    }
                }

                // The visible divider stays 1px so panes butt up against
                // each other like before; the grabbable area is this wider
                // transparent strip floating on top of the seam.
                Color.clear
                    .frame(
                        width: isHorizontal ? 9 : geo.size.width,
                        height: isHorizontal ? geo.size.height : 9
                    )
                    .contentShape(Rectangle())
                    .offset(
                        x: isHorizontal ? firstLength - 4 : 0,
                        y: isHorizontal ? 0 : firstLength - 4
                    )
                    .onHover { inside in
                        hovering = inside
                        if inside {
                            (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let base = dragBaseRatio ?? ratio
                                if dragBaseRatio == nil { dragBaseRatio = base }
                                guard total > 0 else { return }
                                let delta = (isHorizontal ? value.translation.width : value.translation.height) / total
                                let minFraction = min(Self.minPaneLength / total, 0.5)
                                let next = min(max(base + delta, minFraction), 1 - minFraction)
                                store.setSplitRatio(path: path, ratio: next)
                            }
                            .onEnded { _ in dragBaseRatio = nil }
                    )
            }
        }
    }

    private func firstLength(total: CGFloat) -> CGFloat {
        guard total > 1 else { return 0 }
        let minFraction = min(Self.minPaneLength / total, 0.5)
        let clamped = min(max(ratio, minFraction), 1 - minFraction)
        // Floor to whole points so the ghostty surfaces sit on integral
        // boundaries (fractional frames cause the scroll "fault line" —
        // see NoDragContainerView in PaneSurfaceRepresentable).
        return (total * clamped).rounded(.down)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(hovering ? 0.18 : 0.05))
            .frame(
                width: isHorizontal ? 1 : nil,
                height: isHorizontal ? nil : 1
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
