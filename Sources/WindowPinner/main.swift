import AppKit

// Hidden diagnostic: `WindowPinner --dump-displays` prints the live display
// identity (UUID, physical-panel key, origin) and the desktop→panel mapping,
// then exits. Invaluable for the EDID-identical-monitor case, where the whole
// bug is that a UUID isn't stably bound to a physical panel.
if CommandLine.arguments.contains("--dump-displays") {
    print("Displays (uuid  panelKey  origin  size  main):")
    for d in Displays.currentDisplays() {
        let key = d.panelKey ?? d.uuid
        let marker = key == d.uuid ? "" : "  ← disambiguated"
        print("  \(d.uuid.prefix(8))  \(key)  (\(d.x),\(d.y))  \(d.width)x\(d.height)  main=\(d.isMain)\(marker)")
    }
    print("\nDesktop mapping (panelKey -> desktop UUIDs):")
    for (key, spaces) in Spaces.currentMapping(keyMap: Displays.uuidToPanelKey()).sorted(by: { $0.key < $1.key }) {
        print("  \(key) -> \(spaces.map { String($0.prefix(8)) })")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
