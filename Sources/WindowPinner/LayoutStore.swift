import Foundation
import os.log

let log = Logger(subsystem: "com.darnt.WindowPinner", category: "main")

/// Persists one layout per display-configuration fingerprint as JSON in
/// ~/Library/Application Support/WindowPinner/layouts.json
final class LayoutStore {
    private(set) var layouts: [String: Layout] = [:]

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowPinner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layouts.json")
    }()

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            layouts = try decoder.decode([String: Layout].self, from: data)
            log.info("Loaded \(self.layouts.count) saved layout(s)")
        } catch {
            log.error("Failed to decode layouts.json: \(error.localizedDescription)")
        }
    }

    func save(_ layout: Layout) {
        layouts[layout.fingerprint] = layout
        persist()
    }

    func layout(for fingerprint: String) -> Layout? {
        layouts[fingerprint]
    }

    func clearAll() {
        layouts = [:]
        persist()
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(layouts).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to write layouts.json: \(error.localizedDescription)")
        }
    }
}
