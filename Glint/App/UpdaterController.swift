import Combine
import Sparkle
import SwiftUI

/// SwiftUI-friendly wrapper around `SPUStandardUpdaterController`.
///
/// The feed URL and public EdDSA key are read from Info.plist (`SUFeedURL`,
/// `SUPublicEDKey`). Toggling `automaticallyChecksForUpdates` and
/// `checkForUpdates` are forwarded straight to Sparkle's updater so SwiftUI
/// controls stay in lockstep with the framework's own state.
@MainActor
final class UpdaterController: NSObject, ObservableObject {
    private var controller: SPUStandardUpdaterController!

    /// UserDefaults key backing the beta opt-in. Read directly in the
    /// (nonisolated) Sparkle delegate callback, so it lives outside the
    /// published property.
    private static let receiveBetaUpdatesKey = "GlintReceiveBetaUpdates"

    /// Bound to the "Check for updates automatically" toggle in Settings.
    @Published var automaticallyChecksForUpdates: Bool = false {
        didSet {
            guard let controller,
                  controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Bound to the "Check now" button label so it can disable while a
    /// check is in flight (Sparkle exposes this on the updater).
    @Published var canCheckForUpdates: Bool = true

    /// Bound to the "Receive beta updates" toggle in Settings. Opting in
    /// makes Sparkle consider appcast items tagged <sparkle:channel>beta;
    /// stable-only users never see them.
    @Published var receiveBetaUpdates: Bool {
        didSet {
            UserDefaults.standard.set(receiveBetaUpdates, forKey: Self.receiveBetaUpdatesKey)
        }
    }

    private var cancellables: Set<AnyCancellable> = []

    override init() {
        receiveBetaUpdates = UserDefaults.standard.bool(forKey: Self.receiveBetaUpdatesKey)
        super.init()
        #if DEBUG
        // Dev builds carry the placeholder 0.1.0 version (CI stamps the real
        // one at release time), so the appcast always looks newer and Sparkle
        // would offer to replace the dev binary with the production release.
        // Never start the updater in Debug.
        canCheckForUpdates = false
        #else
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        #endif
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

extension UpdaterController: SPUUpdaterDelegate {
    /// Sparkle may call this off the main thread; read the preference
    /// straight from UserDefaults (thread-safe) rather than touching
    /// main-actor published state.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Self.receiveBetaUpdatesKey) ? ["beta"] : []
    }
}
