import Foundation

/// A single physical display in a saved layout.
struct DisplayInfo: Codable {
    var uuid: String
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var isMain: Bool
}

/// One window's saved geometry.
struct WindowRecord: Codable {
    var bundleID: String
    var appName: String
    var title: String
    /// Position of this window within its app's window list at snapshot time,
    /// used as a fallback when titles don't match (titles change often).
    var index: Int
    /// WindowServer window number at snapshot time. Stable across sleep/wake
    /// (but not across app relaunches), so it's the primary match key.
    var windowNumber: UInt32?
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isMinimized: Bool
}

/// A full layout keyed by a display-set fingerprint.
struct Layout: Codable {
    var fingerprint: String
    var savedAt: Date
    var displays: [DisplayInfo]
    var windows: [WindowRecord]
    /// Mission Control mapping: display UUID -> ordered desktop (Space) UUIDs.
    var spaces: [String: [String]]?
}
