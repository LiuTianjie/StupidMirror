import AppKit
import Combine
import OSLog
import Sparkle

/// Checks for and installs app updates with Sparkle, like LinkShell's desktop
/// app: Sparkle reads the appcast, verifies the archive's EdDSA signature and
/// the new app's code signature, and replaces the app in place.
///
/// The updater only runs in a packaged release whose Info.plist names a feed
/// and its public key (`scripts/build-app.sh` writes them for Developer ID
/// builds). `swift run`, tests and ad hoc builds leave it inert.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    private static let logger = Logger(subsystem: "com.stupidmirror.app", category: "AppUpdater")

    /// Whether this build can update itself at all.
    @Published private(set) var isConfigured = false
    @Published private(set) var canCheckForUpdates = false
    /// Version found by the last check, when it is newer than this app.
    @Published private(set) var availableVersion: String?
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var automaticallyChecksForUpdates = false

    private var controller: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func start() {
        guard controller == nil, Self.isConfigured(Bundle.main.infoDictionary) else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        do {
            try controller.updater.start()
        } catch {
            Self.logger.error("Sparkle did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.controller = controller
        let updater = controller.updater
        updater.sendsSystemProfile = false
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
            .store(in: &cancellables)
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
        isConfigured = true
    }

    /// Shows Sparkle's standard update window: release notes, then download,
    /// install and relaunch after the user agrees.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    nonisolated static func isConfigured(_ info: [String: Any]?) -> Bool {
        guard let feed = info?["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https",
              let key = info?["SUPublicEDKey"] as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { availableVersion = nil }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated { lastCheckDate = updater.lastUpdateCheckDate }
    }
}
