import SwiftUI
import AppKit

/// Centered modal overlay raised when `promptAgentOnNew` is on and the user
/// triggers a new tab / split / workspace. Pick an agent (or a bare shell) and
/// the pending `NewTerminalIntent` runs seeded with that command; click-out,
/// Esc, or picking nothing cancels. Same glass language as `CommandPalette`,
/// tuned to a compact Spotlight-style launcher.
struct AgentLaunchChooser: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var codexHomes: CodexHomeStore
    let intent: NewTerminalIntent

    @State private var selected = 0
    @FocusState private var focused: Bool

    private var items: [AgentLaunchItem] { AgentLaunchItem.all(codexHomes: codexHomes.homes) }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                rows
                footer
            }
            .frame(width: 340)
            // Solid `bgPane` card — NO Liquid Glass. The glass material lightens
            // its backing, which is exactly why this used to read lighter than
            // the New Worktree sheet; that sheet is a flat opaque `bgPane`, so to
            // be identical this one drops the glass and matches it 1:1.
            .background(
                Theme.bgPane
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.overlay(0.08), lineWidth: 0.5)
                    )
            )
            .shadow(color: Color.black.opacity(0.5), radius: 30, y: 12)
            .padding(.top, -80) // bias slightly above center
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()   // capture keys without the blue system focus ring
        .onKeyPress { press in handleKey(press) }
        .onAppear {
            // Pry first responder off the terminal surface so the keys land
            // here, not in the shell behind the scrim. The pane's own focus
            // sync is paused while the chooser is up (PaneView's `deferFocus`),
            // so it can't grab it back.
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async { focused = true }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 0) {
            Text("Open with")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Spacer(minLength: 8)
            Text(targetLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var rows: some View {
        VStack(spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { item in
                row(item.element, index: item.offset)
            }
        }
        .padding(.horizontal, 6)
    }

    private func row(_ item: AgentLaunchItem, index: Int) -> some View {
        let on = index == selected
        return Button {
            store.resolveAgentChooser(item)
        } label: {
            HStack(spacing: 11) {
                mark(item.choice).frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text1)
                        if let tag = item.tag {
                            Text(verbatim: tag)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.text4)
                        }
                    }
                    if let sub = item.subtitle {
                        Text(verbatim: sub)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.text4)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if index < 9 {
                    Text("\(index + 1)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(on ? Theme.text3 : Theme.text4)
                        .frame(width: 17, height: 17)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.overlay(on ? 0.10 : 0.05)))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: item.subtitle == nil ? 38 : 46)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? store.accent.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selected = index } }
    }

    @ViewBuilder private func mark(_ choice: AgentChoice) -> some View {
        if let asset = choice.brandAsset {
            Image(asset).resizable().scaledToFit()
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text3)
        }
    }

    private var footer: some View {
        Text("Return to launch · Esc to cancel")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.text4)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
    }

    private var targetLabel: LocalizedStringKey {
        switch intent {
        case .tab:                    return "New Tab"
        case .splitRight, .splitDown: return "Split pane"
        case .workspace:              return "New Workspace"
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let items = items
        switch press.key {
        case .upArrow:   move(-1); return .handled
        case .downArrow: move(1);  return .handled
        case .return:    store.resolveAgentChooser(items[selected]); return .handled
        case .escape:    store.resolveAgentChooser(nil); return .handled
        default:
            // Number shortcuts only address the first nine rows (badges stop at 9).
            if let n = Int(press.characters), (1...min(9, items.count)).contains(n) {
                store.resolveAgentChooser(items[n - 1]); return .handled
            }
            return .ignored
        }
    }

    private func move(_ delta: Int) {
        selected = min(max(0, selected + delta), items.count - 1)
    }
}
