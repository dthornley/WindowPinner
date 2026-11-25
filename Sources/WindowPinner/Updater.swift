import AppKit
import Sparkle

/// In-app updates via Sparkle. The appcast and the EdDSA-signed zip live on
/// the GitHub release (`build.sh release` publishes both); `SUFeedURL` and
/// `SUPublicEDKey` in Info.plist tell Sparkle where to look and whose
/// signature to trust. Checks run automatically once a day and shortly after
/// launch; "Check for Updates…" in the menu runs one on demand.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        // A build straight out of `swift build` has no feed/key in its plist;
        // only start when the bundle is set up for updates.
        guard Self.configured else {
            log.info("Updater disabled: no SUFeedURL/SUPublicEDKey in Info.plist")
            return
        }
        controller.startUpdater()
    }

    /// True when Info.plist carries the feed URL and public key.
    static var configured: Bool {
        let info = Bundle.main.infoDictionary
        return (info?["SUFeedURL"] as? String).map { !$0.isEmpty } ?? false
            && (info?["SUPublicEDKey"] as? String).map { !$0.isEmpty } ?? false
    }

    var canCheck: Bool { Self.configured && controller.updater.canCheckForUpdates }

    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        // The app is a menu-bar accessory; bring Sparkle's window to the front.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(sender)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// The app has no Dock icon, so a scheduled update alert would open behind
    /// the frontmost app and go unnoticed. Opt in to "gentle reminders" and
    /// bring the alert forward ourselves.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !state.userInitiated {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log.notice("Update available: \(item.displayVersionString, privacy: .public)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        log.info("No update available")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        log.notice("Update \(item.displayVersionString, privacy: .public) will install on quit")
        return true
    }
}
