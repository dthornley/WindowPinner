import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let store = LayoutStore()

    // Snapshots are only taken when the display configuration has been
    // stable for a while, so we never save a scrambled post-wake layout.
    private let snapshotInterval: TimeInterval = 30
    private let stabilityWindow: TimeInterval = 20

    private var lastConfigChange = Date.distantPast
    private var suppressSnapshotsUntil = Date.distantPast
    private var isSleeping = false
    private var pendingRestores: [DispatchWorkItem] = []
    private var lastFingerprint = ""
    private var lastRestoreSummary: String?

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    private var autoEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoEnabled") }
    }
    private var restoreArrangementEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "restoreArrangement") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "restoreArrangement") }
    }
    private var restoreSpacesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "restoreSpaces") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "restoreSpaces") }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Windows.accessibilityGranted(prompt: true) {
            log.warning("Accessibility permission not granted yet — windows cannot be read or moved until it is")
        }

        setupStatusItem()
        lastFingerprint = Displays.currentFingerprint()

        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(self, selector: #selector(willSleep),
                             name: NSWorkspace.willSleepNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(didWake),
                             name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        Timer.scheduledTimer(withTimeInterval: snapshotInterval, repeats: true) { [weak self] _ in
            self?.periodicSnapshot()
        }

        // Take a first snapshot shortly after launch once things settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.snapshotIfStable(reason: "initial")
        }
        log.info("WindowPinner started, fingerprint \(self.lastFingerprint, privacy: .public)")
    }

    // MARK: - Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "WindowPinner")
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let version = NSMenuItem(title: "WindowPinner \(Self.versionString)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        info.isEnabled = false
        info.tag = 99
        menu.addItem(info)

        let restoreInfo = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        restoreInfo.isEnabled = false
        restoreInfo.tag = 98
        menu.addItem(restoreInfo)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Snapshot Now", action: #selector(snapshotNow), keyEquivalent: "s").target = self
        menu.addItem(withTitle: "Restore Now", action: #selector(restoreNow), keyEquivalent: "r").target = self
        menu.addItem(.separator())

        let auto = NSMenuItem(title: "Automatic Snapshot & Restore", action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)

        let arr = NSMenuItem(title: "Also Restore Display Arrangement", action: #selector(toggleArrangement), keyEquivalent: "")
        arr.target = self
        menu.addItem(arr)

        let spaces = NSMenuItem(title: "Also Restore Desktops to Displays", action: #selector(toggleSpaces), keyEquivalent: "")
        spaces.target = self
        spaces.toolTip = "Puts Mission Control desktops back on their saved displays. Applying it briefly restarts the Dock."
        menu.addItem(spaces)

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Forget All Layouts", action: #selector(forgetAll), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit WindowPinner", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func snapshotNow() { takeSnapshot(reason: "manual") }

    @objc private func restoreNow() { restoreLayout(reason: "manual") }

    @objc private func toggleAuto() { autoEnabled.toggle() }

    @objc private func toggleArrangement() { restoreArrangementEnabled.toggle() }

    @objc private func toggleSpaces() { restoreSpacesEnabled.toggle() }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            log.error("Login item toggle failed: \(error.localizedDescription)")
        }
    }

    @objc private func forgetAll() { store.clearAll() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Sleep / wake / display events

    @objc private func willSleep() {
        isSleeping = true
        cancelPendingRestores()
        // Only trust the current layout if displays have been stable —
        // closing the lid sometimes reconfigures displays *before* sleep fires.
        snapshotIfStable(reason: "willSleep")
    }

    @objc private func didWake() {
        isSleeping = false
        guard autoEnabled else { return }
        suppressSnapshotsUntil = Date().addingTimeInterval(30)
        scheduleRestores(delays: [3, 10], reason: "didWake")
    }

    @objc private func screensChanged() {
        lastConfigChange = Date()
        let fingerprint = Displays.currentFingerprint()
        let changed = fingerprint != lastFingerprint
        lastFingerprint = fingerprint
        guard autoEnabled, !isSleeping else { return }
        suppressSnapshotsUntil = Date().addingTimeInterval(25)
        if changed {
            log.info("Display set changed → \(fingerprint, privacy: .public)")
            cancelPendingRestores()
            // Debounce: monitors often enumerate one at a time when plugged in.
            scheduleRestores(delays: [4, 12], reason: "displayChange")
        }
    }

    // MARK: - Snapshot logic

    private func periodicSnapshot() {
        guard autoEnabled else { return }
        snapshotIfStable(reason: "periodic")
    }

    private func snapshotIfStable(reason: String) {
        guard !isSleeping else { return }
        guard Date() >= suppressSnapshotsUntil else { return }
        guard Date().timeIntervalSince(lastConfigChange) >= stabilityWindow else { return }
        guard pendingRestores.isEmpty else { return }
        takeSnapshot(reason: reason)
    }

    private func takeSnapshot(reason: String) {
        guard Windows.accessibilityGranted() else { return }
        let displays = Displays.currentDisplays()
        guard !displays.isEmpty else { return }
        let windows = Windows.snapshot()
        guard !windows.isEmpty else { return }
        let layout = Layout(
            fingerprint: Displays.fingerprint(of: displays),
            savedAt: Date(),
            displays: displays,
            windows: windows,
            spaces: Spaces.currentMapping()
        )
        store.save(layout)
        log.info("Snapshot (\(reason, privacy: .public)): \(windows.count) windows on \(displays.count) display(s)")
    }

    // MARK: - Restore logic

    private func scheduleRestores(delays: [TimeInterval], reason: String) {
        cancelPendingRestores()
        for delay in delays {
            var item: DispatchWorkItem!
            item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.restoreLayout(reason: "\(reason)+\(Int(delay))s")
                self.pendingRestores.removeAll { $0 === item }
            }
            pendingRestores.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func cancelPendingRestores() {
        pendingRestores.forEach { $0.cancel() }
        pendingRestores.removeAll()
    }

    private func restoreLayout(reason: String) {
        guard Windows.accessibilityGranted() else { return }
        let fingerprint = Displays.currentFingerprint()
        guard let layout = store.layout(for: fingerprint) else {
            log.info("Restore (\(reason, privacy: .public)): no saved layout for current display set")
            return
        }
        let arrangementFixed = restoreArrangementEnabled && Displays.restoreArrangement(layout.displays)
        // Give WindowServer a moment if displays were just rearranged.
        DispatchQueue.main.asyncAfter(deadline: .now() + (arrangementFixed ? 1.5 : 0)) { [weak self] in
            guard let self else { return }
            var spacesFixed = false
            if self.restoreSpacesEnabled,
               let savedSpaces = layout.spaces, !savedSpaces.isEmpty,
               !Spaces.mappingMatches(savedSpaces) {
                log.info("Restore (\(reason, privacy: .public)): desktops are on the wrong displays")
                self.suppressSnapshotsUntil = Date().addingTimeInterval(45)
                spacesFixed = Spaces.restoreMapping(savedSpaces)
            }
            // After a Dock restart, wait for Mission Control to settle
            // before placing windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + (spacesFixed ? 4 : 0)) {
                let moved = Windows.restore(layout.windows)
                self.noteRestore(moved: moved, arrangementFixed: arrangementFixed, spacesFixed: spacesFixed)
                log.info("Restore (\(reason, privacy: .public)): \(moved) window(s) moved\(arrangementFixed ? ", displays rearranged" : "")\(spacesFixed ? ", desktops re-mapped" : "")")
            }
        }
    }

    private func noteRestore(moved: Int, arrangementFixed: Bool, spacesFixed: Bool) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        var summary = "Last restore: \(moved) window\(moved == 1 ? "" : "s") moved at \(time)"
        if arrangementFixed { summary += ", displays rearranged" }
        if spacesFixed { summary += ", desktops re-mapped" }
        lastRestoreSummary = summary
    }
}

// MARK: - Menu state

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(toggleAuto): item.state = autoEnabled ? .on : .off
            case #selector(toggleArrangement): item.state = restoreArrangementEnabled ? .on : .off
            case #selector(toggleSpaces): item.state = restoreSpacesEnabled ? .on : .off
            case #selector(toggleLogin): item.state = SMAppService.mainApp.status == .enabled ? .on : .off
            default: break
            }
        }
        if let info = menu.items.first(where: { $0.tag == 99 }) {
            let displayCount = Displays.currentDisplays().count
            let setup = "\(displayCount) display\(displayCount == 1 ? "" : "s")"
            if let layout = store.layout(for: Displays.currentFingerprint()) {
                let formatter = RelativeDateTimeFormatter()
                let when = formatter.localizedString(for: layout.savedAt, relativeTo: Date())
                info.title = "Current setup (\(setup)): \(layout.windows.count) windows saved \(when)"
            } else {
                info.title = "Current setup (\(setup)): no layout saved yet"
            }
        }
        if let restoreInfo = menu.items.first(where: { $0.tag == 98 }) {
            restoreInfo.title = lastRestoreSummary ?? "No restore yet this session"
            restoreInfo.isHidden = false
        }
    }
}
