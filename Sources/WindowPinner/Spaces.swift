import AppKit
import CoreGraphics

// Private SkyLight/CoreGraphics calls for reading the live desktop->display
// mapping. Read-only and stable for many macOS versions (used by yabai etc.).
private typealias CGSConnectionID = Int32
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

/// Snapshots and restores which Mission Control desktops (Spaces) live on
/// which display. macOS sometimes swaps whole desktop groups between
/// monitors after sleep/reconnect; the mapping is persisted in the
/// com.apple.spaces preference domain and re-read when the Dock launches,
/// so restoring = rewrite the mapping + restart the Dock.
enum Spaces {

    private static let domain = "com.apple.spaces" as CFString
    private static let configKey = "SpacesDisplayConfiguration" as CFString

    private static func mainDisplayUUID() -> String? {
        Displays.currentDisplays().first(where: \.isMain)?.uuid
    }

    private static func resolve(_ identifier: String) -> String {
        identifier == "Main" ? (mainDisplayUUID() ?? identifier) : identifier
    }

    /// Translates a live display UUID (as it appears in `com.apple.spaces`) into
    /// the key used by the saved layout — the physical-panel key when one is
    /// supplied, otherwise the UUID unchanged.
    private static func key(_ uuid: String, _ keyMap: [String: String]) -> String {
        keyMap[uuid] ?? uuid
    }

    /// Live mapping: saved key (panel key or display UUID) -> ordered
    /// user-desktop (type 0) UUIDs. Pass `keyMap` (live UUID -> panel key) to
    /// key the result by physical panel so it survives UUID swaps between
    /// EDID-identical monitors; omit it for plain UUID keying.
    static func currentMapping(keyMap: [String: String] = [:]) -> [String: [String]] {
        guard let raw = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue(),
              let monitors = raw as? [[String: Any]] else { return [:] }
        var mapping: [String: [String]] = [:]
        for monitor in monitors {
            guard let identifier = monitor["Display Identifier"] as? String,
                  let spaces = monitor["Spaces"] as? [[String: Any]] else { continue }
            let userSpaces = spaces.compactMap { space -> String? in
                guard (space["type"] as? Int) == 0 else { return nil }
                return space["uuid"] as? String
            }
            mapping[key(resolve(identifier), keyMap)] = userSpaces
        }
        return mapping
    }

    /// True when every desktop that exists in both snapshot and present sits
    /// on its saved display, in the saved order. Desktops created or removed
    /// since the snapshot are ignored.
    static func mappingMatches(_ saved: [String: [String]], keyMap: [String: String] = [:]) -> Bool {
        let current = currentMapping(keyMap: keyMap)
        let allCurrent = Set(current.values.flatMap { $0 })
        for (display, savedList) in saved {
            guard let liveList = current[display] else { continue } // display offline
            let expected = savedList.filter(allCurrent.contains)
            let live = liveList.filter(expected.contains)
            if live != expected { return false }
        }
        return true
    }

    /// Rewrites the persisted desktop->display mapping to match `saved` and
    /// restarts the Dock so it takes effect. Returns true if the Dock was
    /// restarted. Refuses to write anything that would lose or duplicate a
    /// desktop.
    @discardableResult
    static func restoreMapping(_ saved: [String: [String]], keyMap: [String: String] = [:]) -> Bool {
        guard var config = CFPreferencesCopyAppValue(configKey, domain) as? [String: Any],
              var management = config["Management Data"] as? [String: Any],
              var monitors = management["Monitors"] as? [[String: Any]] else {
            log.error("Spaces: could not read com.apple.spaces configuration")
            return false
        }

        // Pool every space record from the active (non-collapsed) monitor
        // entries; those are the ones we may regroup.
        var pool: [String: [String: Any]] = [:]
        var activeIndices: [Int] = []
        for (i, monitor) in monitors.enumerated() {
            guard let spaces = monitor["Spaces"] as? [[String: Any]] else { continue }
            activeIndices.append(i)
            for space in spaces {
                if let uuid = space["uuid"] as? String { pool[uuid] = space }
            }
        }
        let claimed = Set(saved.values.flatMap { $0 })
        var assigned = Set<String>()
        var newArrays: [Int: [[String: Any]]] = [:]

        for i in activeIndices {
            guard let identifier = monitors[i]["Display Identifier"] as? String,
                  let currentSpaces = monitors[i]["Spaces"] as? [[String: Any]] else { continue }
            let display = key(resolve(identifier), keyMap)
            var newList: [[String: Any]] = []
            // Desktops the snapshot assigns to this display, in saved order.
            for uuid in saved[display] ?? [] {
                if let record = pool[uuid], !assigned.contains(uuid) {
                    newList.append(record)
                    assigned.insert(uuid)
                }
            }
            // Keep whatever else currently lives here (fullscreen spaces,
            // desktops created after the snapshot) unless the snapshot
            // claims it for a different display.
            for record in currentSpaces {
                guard let uuid = record["uuid"] as? String,
                      !assigned.contains(uuid), !claimed.contains(uuid) else { continue }
                newList.append(record)
                assigned.insert(uuid)
            }
            newArrays[i] = newList
        }
        // Anything claimed by the snapshot for a display that is offline
        // right now would be dropped — put it back where it currently is.
        for i in activeIndices {
            guard let currentSpaces = monitors[i]["Spaces"] as? [[String: Any]] else { continue }
            for record in currentSpaces {
                guard let uuid = record["uuid"] as? String, !assigned.contains(uuid) else { continue }
                newArrays[i, default: []].append(record)
                assigned.insert(uuid)
            }
        }

        // Conservation check: same set of desktops before and after, and no
        // display left with zero desktops.
        guard assigned == Set(pool.keys), newArrays.values.allSatisfy({ !$0.isEmpty }) else {
            log.error("Spaces: regrouping would lose a desktop — aborting")
            return false
        }

        backupCurrentConfig(config)

        for (i, list) in newArrays {
            monitors[i]["Spaces"] = list
            monitors[i]["Current Space"] = list[0]
        }
        management["Monitors"] = monitors
        config["Management Data"] = management
        CFPreferencesSetAppValue(configKey, config as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            log.error("Spaces: failed to write com.apple.spaces")
            return false
        }

        log.notice("Spaces: desktop mapping rewritten, restarting Dock")
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        do {
            try killall.run()
            killall.waitUntilExit()
            return killall.terminationStatus == 0
        } catch {
            log.error("Spaces: failed to restart Dock: \(error.localizedDescription)")
            return false
        }
    }

    /// Keeps the last few pre-modification copies of the spaces config in
    /// Application Support, in case anything ever needs manual recovery.
    private static func backupCurrentConfig(_ config: [String: Any]) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowPinner/spaces-backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let url = dir.appendingPathComponent("spaces-\(formatter.string(from: Date())).plist")
        if let data = try? PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0) {
            try? data.write(to: url)
        }
        // Prune to the 10 most recent backups.
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }),
           files.count > 10 {
            files.dropFirst(10).forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }
}
