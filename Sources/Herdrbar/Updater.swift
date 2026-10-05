import AppKit
import Observation
import Sparkle

/// Sparkle, wrapped so the rest of the app never imports it: Settings reads this observable and calls one
/// method. Updates are signed with EdDSA and listed in `appcast.xml` on the repository's main branch, a static
/// file that `Scripts/release.sh` regenerates.
@MainActor @Observable
final class Updater {
    /// False until Sparkle has started, and while a check is running.
    private(set) var canCheckForUpdates = false
    /// The newest version Sparkle has seen, or nil when Herdrbar is current.
    private(set) var availableVersion: String?
    private(set) var lastCheckedAt: Date?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let updaterDelegate = UpdaterDelegate()
    @ObservationIgnored private let userDriverDelegate = UserDriverDelegate()
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// Stored, so Settings redraws when they change; Sparkle keeps the saved values.
    var automaticallyChecksForUpdates = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    var automaticallyDownloadsUpdates = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    /// Starts Sparkle once, at launch. A build without a feed (a `swift run` binary) never checks.
    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        updaterDelegate.updater = self
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: userDriverDelegate)
        guard let updater = controller?.updater else { return }
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        lastCheckedAt = updater.lastUpdateCheckDate
        canCheckForUpdates = updater.canCheckForUpdates
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    /// A check you asked for: Sparkle shows its own window, also when Herdrbar is up to date.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
        lastCheckedAt = .now
    }

    fileprivate func found(version: String?) {
        availableVersion = version
        lastCheckedAt = controller?.updater.lastUpdateCheckDate ?? .now
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var updater: Updater?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor [weak self] in self?.updater?.found(version: version) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak self] in self?.updater?.found(version: nil) }
    }
}

/// Herdrbar is a menu bar app (`LSUIElement`). Under the accessory activation policy Sparkle's window can open
/// unfocused or off-screen, so a check you asked for switches to the regular policy while the window is up,
/// and switches back when the update session ends.
private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard state.userInitiated else { return }
        // Sparkle calls its user driver on the main thread, but its protocol doesn't say so.
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
    }
}
