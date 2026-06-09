import SwiftUI

@main
struct GlintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var updater = UpdaterController()

    init() {
        // Apply the stored language choice BEFORE any view materializes so
        // Bundle.main picks the right .lproj at its first lookup. "system"
        // clears the override so macOS falls back to the user's OS-level
        // language. Any explicit choice writes into `AppleLanguages`,
        // which is what NSBundle reads to resolve localized strings.
        let stored = UserDefaults.standard.string(forKey: "glint.preferredLanguage") ?? "system"
        if stored == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([stored], forKey: "AppleLanguages")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspaceStore)
                .environmentObject(updater)
                .frame(minWidth: 980, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") { workspaceStore.addWorkspace() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Next Workspace") { workspaceStore.selectNextWorkspace() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Workspace") { workspaceStore.selectPreviousWorkspace() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("Split Horizontal") { workspaceStore.splitFocused(.horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Vertical") { workspaceStore.splitFocused(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close Pane") { workspaceStore.closeFocused() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Focus Next Pane") { workspaceStore.focusNext() }
                    .keyboardShortcut("]", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") {
                    workspaceStore.commandPaletteOpen.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Find in Sidebar") {
                    workspaceStore.focusSidebarSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            // Hijack the App menu's Settings… so ⌘, opens our in-window
            // sheet instead of trying to summon a separate scene.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    workspaceStore.settingsOpen = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
