import AppKit
import ApplicationServices

// Private but long-stable AX call that maps an AXUIElement to its
// WindowServer window number (used by yabai, Rectangle, etc.). Gives us an
// exact window identity that survives sleep/wake.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// Snapshots and restores window geometry for all regular apps via the
/// Accessibility API. Coordinates are global top-left-origin (AX/CG space).
enum Windows {

    static func accessibilityGranted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - AX helpers

    private static func axWindows(of pid: pid_t) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    private static func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttr(_ el: AXUIElement, _ attr: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func applyFrameOnce(_ el: AXUIElement, _ target: CGRect) {
        var point = target.origin
        var size = target.size
        if let v = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
        }
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
        }
        // Setting size can shift position when the window crosses displays;
        // apply the position once more so the origin wins.
        if let v = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
        }
    }

    private static func frameMatches(_ el: AXUIElement, _ target: CGRect, tolerance: CGFloat) -> Bool {
        guard let f = frame(of: el) else { return false }
        return abs(f.origin.x - target.origin.x) < tolerance
            && abs(f.origin.y - target.origin.y) < tolerance
            && abs(f.width - target.width) < tolerance
            && abs(f.height - target.height) < tolerance
    }

    /// WindowServer clamps a frame set while the window is still on another
    /// display (common for windows near screen edges), so verify the result
    /// and re-apply until it sticks.
    private static func setFrame(_ el: AXUIElement, _ target: CGRect) {
        for attempt in 0..<3 {
            applyFrameOnce(el, target)
            if frameMatches(el, target, tolerance: 5) { return }
            if attempt < 2 { usleep(100_000) }
        }
    }

    private static func windowNumber(of el: AXUIElement) -> UInt32? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(el, &id) == .success, id != 0 else { return nil }
        return id
    }

    private static func isStandardWindow(_ el: AXUIElement) -> Bool {
        guard stringAttr(el, kAXRoleAttribute) == kAXWindowRole as String else { return false }
        let subrole = stringAttr(el, kAXSubroleAttribute)
        return subrole == nil || subrole == kAXStandardWindowSubrole as String
    }

    private static func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    // MARK: - Snapshot

    static func snapshot() -> [WindowRecord] {
        var records: [WindowRecord] = []
        for app in regularApps() {
            let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
            let appName = app.localizedName ?? bundleID
            let wins = axWindows(of: app.processIdentifier)
            for (index, win) in wins.enumerated() {
                guard isStandardWindow(win) else { continue }
                let minimized = boolAttr(win, kAXMinimizedAttribute)
                // AX reports a minimized window's frame as it will be when
                // unminimized — record it, so the window can be placed later.
                guard let f = frame(of: win) ?? (minimized ? CGRect.zero : nil) else { continue }
                // Skip zero-sized ghosts.
                if !minimized && (f.width < 20 || f.height < 20) { continue }
                records.append(WindowRecord(
                    bundleID: bundleID,
                    appName: appName,
                    title: stringAttr(win, kAXTitleAttribute) ?? "",
                    index: index,
                    windowNumber: windowNumber(of: win),
                    x: f.origin.x, y: f.origin.y,
                    width: f.width, height: f.height,
                    isMinimized: minimized
                ))
            }
        }
        return records
    }

    private static func setMinimized(_ el: AXUIElement, _ minimized: Bool) {
        AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString,
                                     (minimized ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    // MARK: - Restore

    struct RestoreResult {
        var moved = 0
        var unminimized = 0
    }

    /// Moves windows back to their recorded frames. Windows are matched per
    /// app by WindowServer id, then exact title, then original index. A window
    /// that the snapshot recorded as open but is now minimized (macOS sometimes
    /// minimizes windows during a wake scramble) is unminimized and placed; a
    /// window the user minimized before the snapshot stays minimized.
    @discardableResult
    static func restore(_ records: [WindowRecord]) -> RestoreResult {
        let byBundle = Dictionary(grouping: records, by: \.bundleID)
        var result = RestoreResult()

        for app in regularApps() {
            let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
            guard let wanted = byBundle[bundleID] else { continue }

            let wins = axWindows(of: app.processIdentifier)
            var liveWindows: [(index: Int, el: AXUIElement, title: String, number: UInt32?, minimized: Bool)] = []
            for (index, win) in wins.enumerated() {
                guard isStandardWindow(win) else { continue }
                liveWindows.append((index, win, stringAttr(win, kAXTitleAttribute) ?? "",
                                    windowNumber(of: win), boolAttr(win, kAXMinimizedAttribute)))
            }

            var unclaimed = liveWindows
            var pairs: [(AXUIElement, WindowRecord)] = []

            // Pass 1: exact WindowServer window number — unambiguous for any
            // window that existed at snapshot time (the sleep/wake case).
            var unmatchedRecords: [WindowRecord] = []
            for record in wanted {
                if let number = record.windowNumber,
                   let i = unclaimed.firstIndex(where: { $0.number == number }) {
                    pairs.append((unclaimed[i].el, record))
                    unclaimed.remove(at: i)
                } else {
                    unmatchedRecords.append(record)
                }
            }
            // Pass 2: exact title match (helps after app relaunches).
            var titleUnmatched: [WindowRecord] = []
            for record in unmatchedRecords {
                if !record.title.isEmpty,
                   let i = unclaimed.firstIndex(where: { $0.title == record.title }) {
                    pairs.append((unclaimed[i].el, record))
                    unclaimed.remove(at: i)
                } else {
                    titleUnmatched.append(record)
                }
            }
            // Pass 3: match by original window index.
            var stillUnmatched: [WindowRecord] = []
            for record in titleUnmatched {
                if let i = unclaimed.firstIndex(where: { $0.index == record.index }) {
                    pairs.append((unclaimed[i].el, record))
                    unclaimed.remove(at: i)
                } else {
                    stillUnmatched.append(record)
                }
            }
            // Pass 4: pair leftovers in order — better than leaving them scrambled.
            for record in stillUnmatched {
                guard !unclaimed.isEmpty else { break }
                pairs.append((unclaimed.removeFirst().el, record))
            }

            for (el, record) in pairs {
                let liveMinimized = boolAttr(el, kAXMinimizedAttribute)
                if record.isMinimized {
                    // The user had this window minimized at snapshot time —
                    // don't pop it open. If they've since unminimized it, fall
                    // through and place it at its recorded frame (if we have one).
                    if liveMinimized { continue }
                } else if liveMinimized {
                    // Snapshot says open, but the wake scramble minimized it:
                    // bring it back before placing.
                    setMinimized(el, false)
                    result.unminimized += 1
                }
                let target = CGRect(x: record.x, y: record.y, width: record.width, height: record.height)
                if target.width < 20 || target.height < 20 { continue } // no usable frame recorded
                if let current = frame(of: el),
                   abs(current.origin.x - target.origin.x) < 5,
                   abs(current.origin.y - target.origin.y) < 5,
                   abs(current.width - target.width) < 5,
                   abs(current.height - target.height) < 5 {
                    continue // already where it belongs
                }
                setFrame(el, target)
                result.moved += 1
            }
        }
        return result
    }
}
