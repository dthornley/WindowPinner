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
    // Drift repair can restart the Dock, so rate-limit the periodic catch-all
    // in case a drift is detected that we can't actually fix.
    private var lastDriftRepair = Date.distantPast
    private let driftRepairCooldown: TimeInterval = 300

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
        // Display sleep (screen saver / monitors powering down) does NOT post
        // willSleep/didWake — those are system sleep only. Monitors coming back
        // from display sleep is one of the most common ways macOS scrambles the
        // arrangement, so watch for it explicitly.
        wsCenter.addObserver(self, selector: #selector(screensDidWake),
                             name: NSWorkspace.screensDidWakeNotification, object: nil)
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
        log.info("System woke → scheduling restores")
        suppressSnapshotsUntil = Date().addingTimeInterval(35)
        // Displays keep settling for a while after wake; re-apply several
        // times so a late re-scramble by macOS still gets corrected. Each
        // attempt is idempotent — it no-ops once the arrangement and desktop
        // mapping already match.
        scheduleRestores(delays: [3, 8, 16, 28], reason: "didWake")
    }

    /// Monitors woke from display sleep (screen saver, blanked displays). The
    /// display *set* is usually unchanged, so this never reaches the
    /// fingerprint-changed path — but the arrangement and desktop grouping may
    /// well have been scrambled while the panels were off.
    @objc private func screensDidWake() {
        guard autoEnabled, !isSleeping else { return }
        log.info("Screens woke → scheduling restores")
        suppressSnapshotsUntil = Date().addingTimeInterval(35)
        cancelPendingRestores()
        scheduleRestores(delays: [3, 8, 16, 28], reason: "screensDidWake")
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
            // Debounce: monitors often enumerate one at a time when plugged in,
            // and keep settling afterwards — re-apply across a wider window.
            scheduleRestores(delays: [4, 10, 20], reason: "displayChange")
        } else if driftedFromSavedLayout(fingerprint: fingerprint) {
            // Same monitors as before, so the fingerprint is unchanged — but
            // macOS has moved them (or their desktops) since the snapshot.
            // Without this branch the whole scramble goes unnoticed, because
            // the fingerprint only encodes *which* displays are attached, not
            // where they sit.
            log.info("Display arrangement/desktops drifted from saved layout → scheduling restores")
            cancelPendingRestores()
            scheduleRestores(delays: [2, 6, 14], reason: "drift")
        }
    }

    /// Live UUID→panel-key map to translate `com.apple.spaces` data into
    /// panel-stable keys — but only for layouts saved with panel keys (1.6+).
    /// Legacy layouts stored their spaces keyed by UUID, so they get an empty
    /// map (identity) to preserve their original matching semantics.
    private func spacesKeyMap(for layout: Layout) -> [String: String] {
        let usesPanelKeys = !layout.displays.isEmpty && layout.displays.allSatisfy { $0.panelKey != nil }
        return usesPanelKeys ? Displays.uuidToPanelKey() : [:]
    }

    /// True when the saved layout for this display set no longer matches
    /// reality in the ways we know how to repair.
    private func driftedFromSavedLayout(fingerprint: String) -> Bool {
        guard let layout = store.layout(for: fingerprint) else { return false }
        if restoreArrangementEnabled, !Displays.arrangementMatches(layout.displays) {
            return true
        }
        if restoreSpacesEnabled, let spaces = layout.spaces, !spaces.isEmpty,
           !Spaces.mappingMatches(spaces, keyMap: spacesKeyMap(for: layout)) {
            return true
        }
        return false
    }

    // MARK: - Snapshot logic

    private func periodicSnapshot() {
        guard autoEnabled else { return }
        // Safety net: the notifications above don't reliably fire for every way
        // macOS rearranges displays (display sleep is the notable offender), so
        // re-check on every tick and repair drift even if no event arrived.
        if !isSleeping, pendingRestores.isEmpty,
           Date().timeIntervalSince(lastDriftRepair) >= driftRepairCooldown,
           driftedFromSavedLayout(fingerprint: Displays.currentFingerprint()) {
            log.info("Periodic check: arrangement/desktops drifted → scheduling restore")
            lastDriftRepair = Date()
            scheduleRestores(delays: [1], reason: "periodicDrift")
            return
        }
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

        let fingerprint = Displays.fingerprint(of: displays)
        let existing = store.layout(for: fingerprint)
        let isManual = (reason == "manual")

        // The display arrangement and the desktop→monitor mapping are treated
        // as "reference" data: they describe how you deliberately set up this
        // display set. We capture them the first time a display set is seen,
        // and refresh them whenever you snapshot manually — but an *automatic*
        // snapshot must never overwrite them. Otherwise a transient post-wake
        // or replug scramble gets recorded as the new "correct" layout, and
        // every later restore faithfully reproduces the mess. Window geometry
        // still updates on every snapshot (that part is never scrambled).
        let referenceDisplays: [DisplayInfo]
        let referenceSpaces: [String: [String]]?
        let preserved: Bool
        if let existing, !isManual {
            referenceDisplays = existing.displays
            referenceSpaces = existing.spaces
            preserved = true
        } else {
            referenceDisplays = displays
            // Capture the desktop mapping keyed by physical panel so it survives
            // UUID swaps between EDID-identical monitors.
            referenceSpaces = Spaces.currentMapping(keyMap: Displays.uuidToPanelKey())
            preserved = false
        }

        let layout = Layout(
            fingerprint: fingerprint,
            savedAt: Date(),
            displays: referenceDisplays,
            windows: windows,
            spaces: referenceSpaces
        )
        store.save(layout)
        let note = preserved ? " (arrangement & desktops preserved)" : " (arrangement & desktops captured)"
        log.info("Snapshot (\(reason, privacy: .public)): \(windows.count) windows on \(displays.count) display(s)\(note)")
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
        guard Windows.accessibilityGranted() else {
            log.warning("Restore (\(reason, privacy: .public)): skipped — no Accessibility permission")
            return
        }
        let fingerprint = Displays.currentFingerprint()
        guard let layout = store.layout(for: fingerprint) else {
            log.info("Restore (\(reason, privacy: .public)): no saved layout for current display set")
            return
        }
        let spacesKeyMap = self.spacesKeyMap(for: layout)
        let arrangementOK = Displays.arrangementMatches(layout.displays)
        let spacesOK: Bool
        if let savedSpaces = layout.spaces, !savedSpaces.isEmpty {
            spacesOK = Spaces.mappingMatches(savedSpaces, keyMap: spacesKeyMap)
        } else {
            spacesOK = true
        }
        log.info("Restore (\(reason, privacy: .public)): arrangement \(arrangementOK ? "matches" : "DIFFERS", privacy: .public), desktops \(spacesOK ? "match" : "DIFFER", privacy: .public)")

        let arrangementFixed = restoreArrangementEnabled && Displays.restoreArrangement(layout.displays)
        // Give WindowServer time to settle if displays were just rearranged,
        // so the desktop→display mapping is read against the final geometry.
        DispatchQueue.main.asyncAfter(deadline: .now() + (arrangementFixed ? 2.5 : 0)) { [weak self] in
            guard let self else { return }
            var spacesFixed = false
            if self.restoreSpacesEnabled,
               let savedSpaces = layout.spaces, !savedSpaces.isEmpty,
               !Spaces.mappingMatches(savedSpaces, keyMap: spacesKeyMap) {
                log.info("Restore (\(reason, privacy: .public)): desktops are on the wrong displays")
                self.suppressSnapshotsUntil = Date().addingTimeInterval(45)
                spacesFixed = Spaces.restoreMapping(savedSpaces, keyMap: spacesKeyMap)
            }
            // After a Dock restart, wait for Mission Control to settle
            // before placing windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + (spacesFixed ? 4 : 0)) {
                let moved = Windows.restore(layout.windows)
                self.noteRestore(moved: moved, arrangementFixed: arrangementFixed, spacesFixed: spacesFixed)
                // Build the suffix separately and mark it public: os.log
                // redacts dynamic string interpolation by default, which
                // otherwise hides exactly the part worth reading.
                let extras = (arrangementFixed ? ", displays rearranged" : "")
                    + (spacesFixed ? ", desktops re-mapped" : "")
                log.info("Restore (\(reason, privacy: .public)): \(moved) window(s) moved\(extras, privacy: .public)")
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
