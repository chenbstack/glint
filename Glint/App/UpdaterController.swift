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
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Bound to the "Check for updates automatically" toggle in Settings.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Bound to the "Check now" button label so it can disable while a
    /// check is in flight (Sparkle exposes this on the updater).
    @Published var canCheckForUpdates: Bool = true

    private var cancellables: Set<AnyCancellable> = []

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
