import CoreGraphics
import Foundation

// Public CoreGraphics symbol that isn't surfaced in the Swift overlay.
@_silgen_name("CGDisplayCreateUUIDFromDisplayID")
private func CGDisplayCreateUUIDFromDisplayID(_ display: CGDirectDisplayID) -> Unmanaged<CFUUID>?

/// Reads the current display set and restores a saved display arrangement.
enum Displays {

    static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuidRef) as String?
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
        onlineDisplayIDs().compactMap { id in
            guard let uuid = uuidString(for: id) else { return nil }
            let bounds = CGDisplayBounds(id)
            return DisplayInfo(
                uuid: uuid,
                x: Int(bounds.origin.x),
                y: Int(bounds.origin.y),
                width: Int(bounds.width),
                height: Int(bounds.height),
                isMain: CGDisplayIsMain(id) != 0
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
    static func arrangementMatches(_ saved: [DisplayInfo]) -> Bool {
        let current = Dictionary(uniqueKeysWithValues: currentDisplays().map { ($0.uuid, $0) })
        for d in saved {
            guard let cur = current[d.uuid] else { return false }
            if cur.x != d.x || cur.y != d.y { return false }
        }
        return true
    }

    /// Re-applies saved display origins (fixes macOS swapping left/right
    /// monitors after sleep). Returns true if a change was applied.
    @discardableResult
    static func restoreArrangement(_ saved: [DisplayInfo]) -> Bool {
        guard !arrangementMatches(saved) else { return false }

        let idsByUUID: [String: CGDirectDisplayID] = Dictionary(
            uniqueKeysWithValues: onlineDisplayIDs().compactMap { id in
                uuidString(for: id).map { ($0, id) }
            }
        )

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            log.error("CGBeginDisplayConfiguration failed")
            return false
        }
        var changed = false
        for d in saved {
            guard let id = idsByUUID[d.uuid] else { continue }
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
