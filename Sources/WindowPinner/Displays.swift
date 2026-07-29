import CoreGraphics
import Foundation
import IOKit

// Public CoreGraphics symbol that isn't surfaced in the Swift overlay.
@_silgen_name("CGDisplayCreateUUIDFromDisplayID")
private func CGDisplayCreateUUIDFromDisplayID(_ display: CGDirectDisplayID) -> Unmanaged<CFUUID>?

// Private CoreDisplay call (used by many display tools) returning a rich info
// dictionary for a display, including its macOS UUID and the IOKit location of
// the physical port it's attached to. Resolved at runtime so a symbol change
// degrades gracefully instead of failing to launch.
private typealias CoreDisplayInfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
private let coreDisplayInfo: CoreDisplayInfoFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDisplay_DisplayCreateInfoDictionary")
    else { return nil }
    return unsafeBitCast(sym, to: CoreDisplayInfoFn.self)
}()

/// Reads the current display set and restores a saved display arrangement.
enum Displays {

    static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuidRef) as String?
    }

    // MARK: - Physical panel identity

    /// The `dispextN@ADDR` / `dispN@ADDR` token identifying a physical display
    /// port, extracted from an IOKit registry path or IODisplayLocation.
    private static func portToken(_ path: String) -> String? {
        guard let r = path.range(of: #"disp(ext)?[0-9]+@[0-9a-fA-F]+"#, options: .regularExpression)
        else { return nil }
        return String(path[r])
    }

    /// Live map of physical-port token -> the monitor's own alphanumeric serial,
    /// read from the display framebuffers. Two EDID-identical monitors share a
    /// numeric EDID serial (hence a shared macOS UUID) but still carry distinct
    /// alphanumeric serials, which is what lets us tell them apart.
    private static func serialByPort() -> [String: String] {
        var out: [String: String] = [:]
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                            IOServiceMatching("IOMobileFramebufferAP"), &iter) == KERN_SUCCESS
        else { return out }
        defer { IOObjectRelease(iter) }
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(iter) }
            var pathC = [CChar](repeating: 0, count: 1024)
            IORegistryEntryGetPath(svc, kIOServicePlane, &pathC)
            guard let token = portToken(String(cString: pathC)),
                  let da = IORegistryEntryCreateCFProperty(svc, "DisplayAttributes" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let pa = da["ProductAttributes"] as? [String: Any],
                  let serial = pa["AlphanumericSerialNumber"] as? String, !serial.isEmpty
            else { continue }
            out[token] = serial
        }
        return out
    }

    /// EDID identity (vendor/model/serial) used to detect when two connected
    /// displays are indistinguishable to macOS and therefore have unreliable
    /// UUID<->panel bindings.
    private static func edidKey(_ id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))/\(CGDisplayModelNumber(id))/\(CGDisplaySerialNumber(id))"
    }

    private static func portToken(for id: CGDirectDisplayID) -> String? {
        guard let dict = coreDisplayInfo?(id)?.takeRetainedValue() as? [String: Any],
              let loc = dict["IODisplayLocation"] as? String else { return nil }
        return portToken(loc)
    }

    /// Computes the stable panel key for every online display. A display keeps
    /// its plain UUID unless another *connected* display shares its EDID, in
    /// which case we switch to a serial- (or, failing that, port-) based key so
    /// the two identical panels stay distinguishable across sleep/wake. Normal,
    /// distinguishable setups are unaffected — their key is exactly the UUID.
    static func panelKeys() -> [CGDirectDisplayID: String] {
        let ids = onlineDisplayIDs()
        var edidCounts: [String: Int] = [:]
        for id in ids { edidCounts[edidKey(id), default: 0] += 1 }

        var serialByPortCache: [String: String]? = nil
        var result: [CGDirectDisplayID: String] = [:]
        for id in ids {
            guard let uuid = uuidString(for: id) else { continue }
            if edidCounts[edidKey(id)] ?? 0 <= 1 {
                result[id] = uuid                     // unique EDID: UUID is reliable
                continue
            }
            // Ambiguous: prefer the monitor's own serial, then its physical port.
            let token = portToken(for: id)
            if serialByPortCache == nil { serialByPortCache = serialByPort() }
            if let token, let serial = serialByPortCache?[token] {
                result[id] = "SN:\(serial)"
            } else if let token {
                result[id] = "PORT:\(token)"
            } else {
                result[id] = uuid                     // no disambiguator available; degrade
            }
        }
        return result
    }

    /// Live map of macOS display UUID -> stable panel key, for translating the
    /// UUID-keyed `com.apple.spaces` data into panel-stable keys.
    static func uuidToPanelKey() -> [String: String] {
        let keys = panelKeys()
        var out: [String: String] = [:]
        for (id, key) in keys {
            if let uuid = uuidString(for: id) { out[uuid] = key }
        }
        return out
    }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func currentDisplays() -> [DisplayInfo] {
        let keys = panelKeys()
        return onlineDisplayIDs().compactMap { id in
            guard let uuid = uuidString(for: id) else { return nil }
            let bounds = CGDisplayBounds(id)
            return DisplayInfo(
                uuid: uuid,
                x: Int(bounds.origin.x),
                y: Int(bounds.origin.y),
                width: Int(bounds.width),
                height: Int(bounds.height),
                isMain: CGDisplayIsMain(id) != 0,
                panelKey: keys[id] ?? uuid
            )
        }
    }

    /// Stable identifier for a *set* of connected displays, independent of
    /// arrangement. "Laptop only" and "laptop + office monitors" get
    /// different fingerprints and therefore separate saved layouts.
    static func fingerprint(of displays: [DisplayInfo]) -> String {
        displays.map(\.uuid).sorted().joined(separator: "+")
    }

    static func currentFingerprint() -> String {
        fingerprint(of: currentDisplays())
    }

    /// True if every saved display origin matches what's on screen now.
    /// Displays are matched by physical-panel key so that two EDID-identical
    /// monitors whose UUIDs have swapped are correctly seen as *not* matching.
    /// Legacy layouts (no panel keys) fall back to UUID matching.
    static func arrangementMatches(_ saved: [DisplayInfo]) -> Bool {
        let usePanel = saved.allSatisfy { $0.panelKey != nil }
        func key(_ d: DisplayInfo) -> String { usePanel ? d.matchKey : d.uuid }
        let current = Dictionary(currentDisplays().map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        for d in saved {
            guard let cur = current[key(d)] else { return false }
            if cur.x != d.x || cur.y != d.y { return false }
        }
        return true
    }

    /// Re-applies saved display origins (fixes macOS swapping left/right
    /// monitors after sleep). Returns true if a change was applied.
    @discardableResult
    static func restoreArrangement(_ saved: [DisplayInfo]) -> Bool {
        guard !arrangementMatches(saved) else { return false }

        // Map each display's physical-panel key to its *current* display id, so
        // a saved origin lands on the right physical monitor even if macOS has
        // reassigned the UUIDs of two identical panels. Legacy layouts (no panel
        // keys) match by UUID.
        let usePanel = saved.allSatisfy { $0.panelKey != nil }
        let keys = usePanel ? panelKeys() : [:]
        let idsByKey: [String: CGDirectDisplayID] = Dictionary(
            onlineDisplayIDs().compactMap { id -> (String, CGDirectDisplayID)? in
                let key = usePanel ? keys[id] : uuidString(for: id)
                return key.map { ($0, id) }
            },
            uniquingKeysWith: { a, _ in a }
        )

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            log.error("CGBeginDisplayConfiguration failed")
            return false
        }
        var changed = false
        for d in saved {
            guard let id = idsByKey[usePanel ? d.matchKey : d.uuid] else { continue }
            let bounds = CGDisplayBounds(id)
            if Int(bounds.origin.x) != d.x || Int(bounds.origin.y) != d.y {
                CGConfigureDisplayOrigin(config, id, Int32(d.x), Int32(d.y))
                changed = true
            }
        }
        if changed {
            let result = CGCompleteDisplayConfiguration(config, .permanently)
            if result != .success {
                log.error("CGCompleteDisplayConfiguration failed: \(result.rawValue)")
                return false
            }
            log.info("Display arrangement restored")
            return true
        } else {
            CGCancelDisplayConfiguration(config)
            return false
        }
    }
}
