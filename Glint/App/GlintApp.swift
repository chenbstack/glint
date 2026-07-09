import SwiftUI

@main
struct GlintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var updater = UpdaterController()
    @StateObject private var usage = UsageStore()
    @StateObject private var codexHomes = CodexHomeStore()

    init() {
        #if DEBUG
        // Dev builds run under their own defaults domain (app.glint.Glint.dev).
        // The first dev launch copies the production app's glint.* preferences
        // so it starts where production left off; after that the two domains
        // diverge independently. Must run before the language read below.
        if !UserDefaults.standard.bool(forKey: "glint.devDefaultsSeeded"),
           let prod = UserDefaults.standard.persistentDomain(forName: "app.glint.Glint") {
            for (key, value) in prod where key.hasPrefix("glint.") {
                UserDefaults.standard.set(value, forKey: key)
            }
            UserDefaults.standard.set(true, forKey: "glint.devDefaultsSeeded")
        }
        #endif

        // Crash-loop guard: if the previous launch died before going healthy,
        // roll back the setting change that most likely caused it BEFORE we
        // read any preference below — otherwise a bad sticky value (issue #15)
        // replays the same crash on every launch. Also starts journaling
        // subsequent setting changes so the next crash can be undone.
        SettingsSafety.shared.beginLaunch()

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
        // Single-instance `Window` scene: it can never spawn a second window,
        // so any external activation (a clicked macOS notification, a reopen)
        // lands on the existing window instead of creating a new one. The
        // UNUserNotificationCenterDelegate handles the pane switch.
        // NB: `handlesExternalEvents` does NOT help here — it only routes
        // URL-scheme / NSUserActivity events, and a local-notification click
        // produces neither. WindowGroup would open a fresh window on reopen.
        Window("Glint", id: "glint-main") {
            ContentView()
                .environmentObject(workspaceStore)
                .environmentObject(updater)
                .environmentObject(usage)
                .environmentObject(codexHomes)
                .frame(minWidth: 980, minHeight: 600)
                .preferredColorScheme(Theme.colorScheme)
                .onAppear { updater.startDeferred() }
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
                Button("New Workspace") { workspaceStore.requestNewWorkspace() }
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
                Button("Split Right") { workspaceStore.requestSplit(.horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") { workspaceStore.requestSplit(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close Pane") { workspaceStore.closeFocused() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Focus Next Pane") { workspaceStore.focusNext() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Focus Previous Pane") { workspaceStore.focusPrevious() }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                // Tabs deliberately avoid the workspace vocabulary (⌘1…9,
                // ⌘⇧[ ]) so existing muscle memory is untouched: ⌘T opens,
                // ⌘⇧W closes, and ⌃Tab / ⌃⇧Tab cycle (iTerm-compatible, and
                // not a sequence the terminal itself needs).
                Button("New Tab") { workspaceStore.requestNewTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") {
                    if let ws = workspaceStore.selectedWorkspace {
                        workspaceStore.closeTab(ws.selectedTabID)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Next Tab") { workspaceStore.nextTab() }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Tab") { workspaceStore.previousTab() }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") {
                    workspaceStore.commandPaletteOpen.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Find in Sidebar") {
                    workspaceStore.focusSidebarSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                // Read-only diff window for the selected workspace; mirrors the
                // git button's "Review Changes…" affordance. Disabled when the
                // selection has no reviewable git path.
                Button("Review Changes…") {
                    if let ws = workspaceStore.selectedWorkspace {
                        workspaceStore.openReview(for: ws)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(workspaceStore.selectedWorkspace.flatMap {
                    workspaceStore.effectiveGitPath(for: $0)
                } == nil)
                // Reveal the focused pane's cwd in Finder from anywhere — even
                // outside a git repo (unlike Review Changes). Never disabled.
                Button("Reveal in Finder") {
                    workspaceStore.revealCurrentInFinder()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                // Copy the focused pane's cwd (⌘⇧C) — cwd-first, so it works
                // outside a git repo too. Never disabled; beeps if unknown.
                Button("Copy Path") {
                    workspaceStore.copyCurrentPath()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
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
