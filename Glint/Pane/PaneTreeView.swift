import SwiftUI
import AppKit

enum SplitLayoutPolicy {
    static let dividerLength: CGFloat = 1

    static func lengths(total: CGFloat,
                        ratio: CGFloat,
                        minPaneLength: CGFloat) -> (first: CGFloat, second: CGFloat) {
        guard total > dividerLength else { return (0, 0) }
        let minFraction = min(minPaneLength / total, 0.5)
        let clamped = min(max(ratio, minFraction), 1 - minFraction)
        let first = (total * clamped).rounded(.down)
        return (first, max(total - dividerLength - first, 0))
    }
}

final class SplitDragHandleView: NSView {
    var isHorizontal = true {
        didSet { discardCursorRects() }
    }
    var onTranslation: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private var dragStart: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(
            bounds,
            cursor: isHorizontal ? .resizeLeftRight : .resizeUpDown
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        onTranslation?(0)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = event.locationInWindow
        onTranslation?(
            isHorizontal ? current.x - dragStart.x : dragStart.y - current.y
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onEnded?()
    }
}

private struct SplitDragHandle: NSViewRepresentable {
    let isHorizontal: Bool
    let onTranslation: (CGFloat) -> Void
    let onEnded: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> SplitDragHandleView {
        SplitDragHandleView()
    }

    func updateNSView(_ nsView: SplitDragHandleView, context: Context) {
        nsView.isHorizontal = isHorizontal
        nsView.onTranslation = onTranslation
        nsView.onEnded = onEnded
        nsView.onHover = onHover
    }
}

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
            let lengths = SplitLayoutPolicy.lengths(
                total: total,
                ratio: ratio,
                minPaneLength: Self.minPaneLength
            )
            let firstLength = lengths.first

            ZStack(alignment: .topLeading) {
                if isHorizontal {
                    HStack(spacing: 0) {
                        PaneTreeView(node: a, workspaceID: workspaceID, path: path + [false])
                            .frame(width: firstLength)
                        divider
                        PaneTreeView(node: b, workspaceID: workspaceID, path: path + [true])
                            .frame(width: lengths.second)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                } else {
                    VStack(spacing: 0) {
                        PaneTreeView(node: a, workspaceID: workspaceID, path: path + [false])
                            .frame(height: firstLength)
                        divider
                        PaneTreeView(node: b, workspaceID: workspaceID, path: path + [true])
                            .frame(height: lengths.second)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }

                // The visible divider stays 1px so panes butt up against
                // each other like before; the grabbable area is this wider
                // transparent strip floating on top of the seam.
                SplitDragHandle(
                    isHorizontal: isHorizontal,
                    onTranslation: { translation in
                        let base = dragBaseRatio ?? ratio
                        if dragBaseRatio == nil { dragBaseRatio = base }
                        guard total > 0 else { return }
                        let minFraction = min(Self.minPaneLength / total, 0.5)
                        let next = min(max(base + translation / total, minFraction),
                                       1 - minFraction)
                        store.setSplitRatio(path: path, ratio: next)
                    },
                    onEnded: { dragBaseRatio = nil },
                    onHover: { hovering = $0 }
                )
                    .frame(
                        width: isHorizontal ? 9 : geo.size.width,
                        height: isHorizontal ? geo.size.height : 9
                    )
                    .offset(
                        x: isHorizontal ? firstLength - 4 : 0,
                        y: isHorizontal ? 0 : firstLength - 4
                    )
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(hovering ? Theme.overlay(0.18) : Theme.divider)
            .frame(
                width: isHorizontal ? 1 : nil,
                height: isHorizontal ? nil : 1
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
