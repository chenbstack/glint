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
                // Live language switching: AppleLanguages (set in init) only
                // applies on the next launch; this env value re-resolves
                // LocalizedStringKey lookups immediately when the user picks
                // a language in Settings.
                .environment(\.locale, workspaceStore.preferredLocale)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // Shortcut policy: a terminal app must leave the terminal's own
            // vocabulary alone. ⌘↑/⌘↓ (prompt-mark jumps) and ⌘F (future
            // scrollback search) deliberately have NO menu bindings so the
            // events reach ghostty; workspace switching uses the tab-like
            // ⌘⇧[ / ⌘⇧] plus ⌘1…⌘9 direct jumps instead.
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") { workspaceStore.addWorkspace() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Next Workspace") { workspaceStore.selectNextWorkspace() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Workspace") { workspaceStore.selectPreviousWorkspace() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                ForEach(1..<10, id: \.self) { n in
                    Button("Workspace \(n)") { workspaceStore.selectWorkspace(at: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
                Divider()
                // Direction-explicit names; "horizontal/vertical" read
                // opposite ways in different terminals and our own palette
                // copy had it backwards. `.horizontal` = side by side.
                Button("Split Right") { workspaceStore.splitFocused(.horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") { workspaceStore.splitFocused(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close Pane") { workspaceStore.closeFocused() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Focus Next Pane") { workspaceStore.focusNext() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Focus Previous Pane") { workspaceStore.focusPrevious() }
                    .keyboardShortcut("[", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") {
                    workspaceStore.commandPaletteOpen.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Find in Sidebar") {
                    workspaceStore.focusSidebarSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
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
