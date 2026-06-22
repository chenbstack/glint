import SwiftUI

/// ⌘W 关闭附着的 sheet。
///
/// 主菜单的 ⌘W 绑的是终端「Close Pane」(终端动作),会抢走这个事件。
/// sheet 没有独立 NSWindow(它附在主窗口上),所以不能像 Review 审阅窗口
/// 那样重写 `performKeyEquivalent`;改成在 sheet 的视图树里抢先注册一个
/// 同名 shortcut —— `NSWindow.performKeyEquivalent` 遍历视图树**先于**
/// mainMenu,所以 sheet 显示时这里先匹配到并 dismiss。
struct CloseOnCmdW: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.background {
            Button(action: { dismiss() }) { EmptyView() }
                .keyboardShortcut("w", modifiers: .command)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// 让附着的 sheet 用 ⌘W 关闭(见 `CloseOnCmdW`)。
    func closeOnCmdW() -> some View { modifier(CloseOnCmdW()) }
}
