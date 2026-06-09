import SwiftUI
import AppKit

/// Hosts a stable, store-owned `GhosttySurfaceView` inside a fresh container
/// NSView. SwiftUI may rebuild the container any time the split tree reshapes;
/// the surface itself outlives that and just re-parents.
struct PaneSurfaceRepresentable: NSViewRepresentable {
    let surfaceView: GhosttySurfaceView
    @Binding var focused: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NoDragContainerView()
        container.wantsLayer = true
        attach(surfaceView, to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if surfaceView.superview !== nsView {
            attach(surfaceView, to: nsView)
        }
        // Don't yank focus out of a text editor (sidebar search, rename
        // field, …). SwiftUI re-runs updateNSView roughly every second
        // because of the sidebar's per-workspace elapsed-time
        // TimelineView, so any unconditional sync here would steal focus
        // and re-light the terminal cursor ~1s after the user clicks the
        // search box. resignFirstResponder already pushed ghostty into
        // the unfocused state; leave it alone until the responder dance
        // unwinds naturally.
        let textEditorActive = surfaceView.window?.firstResponder is NSText
        if !textEditorActive {
            surfaceView.setGhosttyFocus(focused)
        }
        if focused, !textEditorActive, surfaceView.window?.firstResponder !== surfaceView {
            DispatchQueue.main.async {
                surfaceView.window?.makeFirstResponder(surfaceView)
            }
        } else if !focused, surfaceView.window?.firstResponder === surfaceView {
            DispatchQueue.main.async {
                surfaceView.window?.makeFirstResponder(nil)
            }
        }
    }

    /// Container subclass that disables borderless-window drag in the pane
    /// area. Without this, any whitespace not covered by the ghostty surface
    /// (e.g. during a resize) would let the user drag the window.
    ///
    /// Also snaps its own frame to backing-store pixels — SwiftUI's layout
    /// regularly hands us fractional origins (e.g. y=52.5 after the 52pt
    /// toolbar on an odd-height window). Ghostty's CAMetalLayer then lives
    /// at a fractional screen position, Core Animation resamples it to the
    /// pixel grid, and during fast scrollback (`cat` of a big file) each
    /// row falls on a slightly different sub-pixel offset — the eye reads
    /// the result as a 1px "fault line" tearing through the rows.
    private final class NoDragContainerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(snappedOrigin(newOrigin))
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(snappedSize(newSize))
        }

        private func snappedOrigin(_ p: NSPoint) -> NSPoint {
            guard window != nil else { return p }
            return backingAlignedRect(
                NSRect(origin: p, size: frame.size),
                options: [.alignAllEdgesNearest]
            ).origin
        }

        private func snappedSize(_ s: NSSize) -> NSSize {
            guard window != nil else { return s }
            return backingAlignedRect(
                NSRect(origin: frame.origin, size: s),
                options: [.alignAllEdgesNearest]
            ).size
        }
    }

    private func attach(_ surface: GhosttySurfaceView, to container: NSView) {
        // Evict any stale surface left over from another workspace's pane that
        // happened to use this container. With the workspace `.id()` removed
        // above, SwiftUI re-uses the same hosting NSView across switches, so
        // we have to actively clean up rather than rely on full teardown.
        for child in container.subviews where child !== surface {
            child.removeFromSuperview()
        }
        if surface.superview !== container {
            surface.removeFromSuperview()
            surface.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(surface)
            NSLayoutConstraint.activate([
                surface.topAnchor.constraint(equalTo: container.topAnchor),
                surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
    }
}
