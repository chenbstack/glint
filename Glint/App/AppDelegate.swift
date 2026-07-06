import AppKit
import CoreServices
import CoreText
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let frameDefaultsKey = "glint.mainWindowFrame"
    private weak var mainWindow: NSWindow?
    private var closeGuard: CloseGuardWindowDelegate?
    /// Set when the user already confirmed termination through the window's
    /// close button — applicationShouldTerminate must not ask a second time.
    fileprivate var didConfirmViaWindowClose = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 通知点击由我们自己接:激活现有窗口 + 切到对应 pane,
        // 否则系统默认会再 launch 一个窗口。
        UNUserNotificationCenter.current().delegate = self
        DispatchQueue.main.async {
            self.configureMainWindow()
            self.patchMainMenu()
            // Re-apply the saved Dock icon override (no-op for .default).
            WorkspaceStore.current?.applyAppIcon()
        }
        // Declare the launch healthy once we've been alive and on-screen for a
        // few seconds — long enough to clear the window's first render, where a
        // bad sticky setting would crash. Until then the crash-loop marker
        // stays armed (see SettingsSafety).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            SettingsSafety.shared.markHealthy()
        }
        // 后台预热字体 cache:Settings ▸ Terminal 第一次打开会同步枚举所有
        // 已安装家族(可能 300+,每个再 availableMembers)。装得多的机器上
        // 主线程同步跑会卡住一帧;这里挪到 userInitiated queue 后台做掉,
        // 等用户走到 Settings 时 cache 已 ready。
        DispatchQueue.global(qos: .userInitiated).async {
            FontCatalog.warmCache()
        }
        // 用户中途装/删字体时让 cache 失效,下次访问按需重建。这是 Cocoa
        // 桥过来的 CFString 常量,用 raw value 包成 Notification.Name。
        NotificationCenter.default.addObserver(
            forName: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
            object: nil, queue: nil
        ) { _ in
            FontCatalog.invalidateCache()
            DispatchQueue.global(qos: .utility).async {
                FontCatalog.warmCache()
            }
        }
    }

    /// Intercept folder / file / `glint://` opens at the raw Apple-Event level,
    /// BEFORE NSApplication's default dispatch sees them.
    ///
    /// Why not `application(_:open:)` or `.onOpenURL`: Glint declares
    /// `CFBundleDocumentTypes` so Launch Services will deliver an `odoc` event
    /// for a folder/file — but on a running single-`Window` SwiftUI app, when
    /// SwiftUI/NSApplication's default handler processes that `odoc`, it tears
    /// the window down, and `applicationShouldTerminateAfterLastWindowClosed`
    /// then quits the app. Registering our own `kAEOpenDocuments` / `kAEOpenURLs`
    /// handlers pre-empts that: NSApplication sees a handler is already set and
    /// skips its default dispatch, so SwiftUI never reacts and the window stays.
    /// We route the paths to `WorkspaceStore` ourselves.
    ///
    /// Must run in `applicationWillFinishLaunching` (before NSApplication
    /// installs its own handlers during finishLaunching). Cold-launch timing is
    /// handled by the `pendingOpenURLs` queue + `WorkspaceStore.init` drain.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let aem = NSAppleEventManager.shared()
        aem.setEventHandler(self, andSelector: #selector(appleEventOpenDocuments(_:withReplyEvent:)),
                            forEventClass: kCoreEventClass, andEventID: kAEOpenDocuments)
        aem.setEventHandler(self, andSelector: #selector(appleEventOpenURLs(_:withReplyEvent:)),
                            forEventClass: AEEventClass(kInternetEventClass),
                            andEventID: AEEventID(kAEGetURL))
    }

    /// `kAEOpenDocuments` (odoc): Finder "Open With", dock drop, `open -a Glint
    /// <folder>`. The direct object is a list of file-ref descriptors; coerce
    /// each to a `file://` URL.
    @objc private func appleEventOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        Self.deliver(extractFileURLs(from: event))
    }

    /// `kAEGetURL` (GURL): a `glint://` link.
    @objc private func appleEventOpenURLs(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        Self.deliver(extractURLStrings(from: event))
    }

    private func extractFileURLs(from event: NSAppleEventDescriptor) -> [URL] {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return [] }
        // fileURLValue coerces each item (alias / file-ref descriptor) to a URL.
        return descriptorList(direct).compactMap { $0.fileURLValue }
    }

    private func extractURLStrings(from event: NSAppleEventDescriptor) -> [URL] {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return [] }
        // GURL's direct object is a URL string (sometimes a list of them).
        return descriptorList(direct).compactMap { $0.stringValue.flatMap(URL.init(string:)) }
    }

    /// Treat `desc` as a list of descriptors, or a single-element list if it
    /// isn't an AEList. `descriptorAtIndex:` isn't bridged to Swift on this SDK
    /// (and `perform(_:with:)`/`NSInvocation` can't pass a primitive NSInteger),
    /// so reach it through the `glint_aeDescriptorAtIndex` ObjC shim in
    /// AEBridge.m. Items are 1-indexed.
    private func descriptorList(_ desc: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard desc.descriptorType == typeAEList else { return [desc] }
        let n = desc.numberOfItems
        guard n > 0 else { return [] }
        return (1...n).compactMap { glint_aeDescriptorAtIndex(desc, $0) }
    }

    private static var pendingOpenURLs: [URL] = []
    /// Re-entry guard: `openURL` may run a modal (the execute-file confirm)
    /// whose nested run loop delivers more Apple Events → `deliver` → `flush`.
    /// The guard makes re-entrant calls a no-op; the outer `flush` loop keeps
    /// draining `pendingOpenURLs` after each modal returns, so confirms never
    /// stack on top of each other.
    private static var isFlushing = false
    private static func deliver(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingOpenURLs.append(contentsOf: urls)
        flush()
    }
    /// Drain anything queued before the store existed. Called from `deliver`
    /// (warm) and from `WorkspaceStore.init` (cold, once `current` is set).
    static func flush() {
        guard let store = WorkspaceStore.current, !pendingOpenURLs.isEmpty else { return }
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        while let url = pendingOpenURLs.first {
            pendingOpenURLs.removeFirst()
            store.openURL(url)
        }
    }

    /// SwiftUI auto-adds File > Close Window bound to Cmd+W; that competes with
    /// our "close pane" shortcut and ends up closing the entire window first.
    /// Strip the shortcut from the system close items so only our handler runs.
    private func patchMainMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            for item in submenu.items {
                if item.action == #selector(NSWindow.performClose(_:))
                    && item.keyEquivalent == "w" {
                    item.keyEquivalent = ""
                    item.keyEquivalentModifierMask = []
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Closing the window already ran this confirmation (and the window
        // is gone by now) — don't ask twice on the way out.
        if didConfirmViaWindowClose { return .terminateNow }
        if Self.confirmTerminationIfBusy() { return .terminateNow }
        return .terminateCancel
    }

    /// Shared by ⌘Q and the window close button: if any pane still has real
    /// work running (agent mid-turn, non-shell process), ask before killing
    /// everything. Returns true when termination should proceed.
    fileprivate static func confirmTerminationIfBusy() -> Bool {
        let busy = WorkspaceStore.current?.panesNeedingQuitConfirmation ?? 0
        guard busy > 0 else { return true }
        return WorkspaceStore.confirmDestruction(
            message: String(localized: "Quit Glint?"),
            informative: busy == 1
                ? String(localized: "1 pane still has something running; quitting will terminate it.")
                : String(format: String(localized: "%d panes still have something running; quitting will terminate all of them."), busy),
            confirmTitle: String(localized: "Quit"),
            suppressionKey: "glint.suppressQuitConfirm"
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Belt-and-suspenders: save the frame at quit even if didMove /
        // didEndLiveResize never fired this session (e.g. user opens, never
        // touches the window, quits).
        persistMainWindowFrame()
        // Clean quit: disarm the crash-loop marker so the next launch isn't
        // mistaken for a crash. Deliberately does NOT advance the healthy
        // high-water mark — a setting changed this session can still crash the
        // next launch (issue #15), so it must stay rollback-eligible.
        SettingsSafety.shared.markCleanExit()
        // Drop our delivered banners so they don't outlive the process. A
        // notification whose owner is gone is a dead link: clicking it
        // cold-launches a fresh instance instead of activating the running one.
        // These banners are transient attention cues, not anything to keep.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    private func configureMainWindow() {
        guard let window = NSApp.windows.first else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        // NSWindow + isOpaque=false 会在圆角内侧画一条 1pt 系统 frame line
        // (用来给"裸"圆角描个边)。原本 sidebar 不透明把它挡住,现在亮色主题
        // 走 vibrancy 半透,这条线全圈透出来,看着像窗口有一圈黑描边。让
        // contentView 自己 mask 圆角,那条线就贴到 mask 外的透明区里,进不来。
        if let cv = window.contentView {
            cv.wantsLayer = true
            cv.layer?.cornerRadius = 10        // macOS 26 默认窗口圆角 ~10pt
            cv.layer?.cornerCurve = .continuous
            cv.layer?.masksToBounds = true
        }
        GhosttyManager.shared.syncWindowAppearance()
        window.titlebarSeparatorStyle = .none
        // Sidebar inset to nothing — we draw chrome ourselves
        window.toolbar = nil
        // Install ghostty's window blur (no-op unless the terminal is
        // translucent with a blur radius set). Deferred to the next runloop so
        // the window's backing is fully realized and the ghostty app has
        // finished bootstrap — same async path reloadConfig uses, so a
        // blur preset set before launch still takes effect on first show.
        DispatchQueue.main.async {
            GhosttyManager.shared.applyWindowEffects()
        }

        // Intercept the close button so closing the (only) window — which
        // terminates the app — gets the same "work is still running"
        // confirmation as ⌘Q. All other delegate traffic forwards to the
        // delegate SwiftUI installed.
        let guardDelegate = CloseGuardWindowDelegate(original: window.delegate, appDelegate: self)
        window.delegate = guardDelegate
        closeGuard = guardDelegate

        // We manage the frame ourselves. SwiftUI's WindowGroup assigns its
        // own `frameAutosaveName` (derived from the modifier chain on
        // ContentView) and re-asserts it after we set our own — so
        // `setFrameAutosaveName` looked like it took effect but got
        // overwritten silently. Instead persist the frame in UserDefaults
        // and apply it on launch, listening for move/resize to update.
        mainWindow = window
        if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            let rect = NSRectFromString(saved)
            // Guard against restoring to a screen that no longer exists
            // (e.g. external display unplugged) — an off-screen window is
            // unrecoverable without defaults surgery.
            if rect.width > 0 && rect.height > 0 && Self.frameIsReasonablyVisible(rect) {
                window.setFrame(rect, display: true, animate: false)
            } else {
                applyDefaultFrame(window)
            }
        } else {
            applyDefaultFrame(window)
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(persistMainWindowFrame),
                       name: NSWindow.didMoveNotification, object: window)
        nc.addObserver(self, selector: #selector(persistMainWindowFrame),
                       name: NSWindow.didEndLiveResizeNotification, object: window)
    }

    /// True when enough of `rect` lands on some present screen for the user
    /// to grab the title-bar area and recover the window themselves.
    private static func frameIsReasonablyVisible(_ rect: NSRect) -> Bool {
        for screen in NSScreen.screens {
            let overlap = rect.intersection(screen.visibleFrame)
            if overlap.width >= 200 && overlap.height >= 100 { return true }
        }
        return false
    }

    private func applyDefaultFrame(_ window: NSWindow) {
        window.setContentSize(NSSize(width: 1320, height: 824))
        window.center()
    }

    @objc private func persistMainWindowFrame() {
        guard let window = mainWindow else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameDefaultsKey)
    }
}

/// NSWindowDelegate proxy: answers `windowShouldClose` itself (running the
/// busy-work confirmation) and forwards everything else to the delegate
/// SwiftUI installed, which does scene lifecycle bookkeeping we must not
/// break. Holds the original strongly — `NSWindow.delegate` is weak, so
/// once we replace it nothing else is guaranteed to keep it alive.
@MainActor
private final class CloseGuardWindowDelegate: NSObject, NSWindowDelegate {
    private let original: NSWindowDelegate?
    private weak var appDelegate: AppDelegate?

    init(original: NSWindowDelegate?, appDelegate: AppDelegate) {
        self.original = original
        self.appDelegate = appDelegate
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard AppDelegate.confirmTerminationIfBusy() else { return false }
        // Remember the confirmation: this close terminates the app, and
        // applicationShouldTerminate should not re-ask after the window
        // is already gone.
        appDelegate?.didConfirmViaWindowClose = true
        if let original,
           original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            return original.windowShouldClose?(sender) ?? true
        }
        return true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// 点击通知:激活 app 并把主窗前置;若通知带了 workspace+pane,再切过去。
    /// 设了 delegate 后系统不再走默认的「再开一个窗口」行为。
    /// `nonisolated` + 切主 actor:协议回调不保证在 main actor,而 AppDelegate 是
    /// @MainActor,直接 conformance 会跨隔离(Swift 6 会变错)。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            let info = response.notification.request.content.userInfo
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
            if let wsStr = info["workspace"] as? String,
               let ws = UUID(uuidString: wsStr),
               let paneStr = info["pane"] as? String,
               let paneSeq = UInt32(paneStr) {
                WorkspaceStore.current?.revealPane(workspace: ws, pane: PaneID(value: paneSeq))
            }
            completionHandler()
        }
    }
}
