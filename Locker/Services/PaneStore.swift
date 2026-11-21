import Foundation

/// Reads and writes `panes.json` (next to `state.json`): the side panel state per workspace id.
final class PaneStore {
    let url: URL
    init(url: URL = PaneStore.defaultURL) { self.url = url }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Locker/panes.json")
    }

    /// One entry that fails to decode is skipped; a missing or unreadable file gives no panels.
    private struct Lossy: Decodable {
        let value: PaneState?
        init(from d: Decoder) throws { value = try? PaneState(from: d) }
    }

    private struct File: Decodable {
        let panes: [String: Lossy]
    }

    func load() -> [UUID: PaneState] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        var out: [UUID: PaneState] = [:]
        for (key, entry) in file.panes {
            if let id = UUID(uuidString: key), let value = entry.value { out[id] = value }
        }
        return out
    }

    func save(_ panes: [UUID: PaneState]) {
        struct Out: Encodable { let panes: [String: PaneState] }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let body = Out(panes: Dictionary(uniqueKeysWithValues: panes.map { ($0.key.uuidString, $0.value) }))
            try enc.encode(body).write(to: url, options: .atomic)
        } catch {
            NSLog("Locker: failed to save panes: \(error)")
        }
    }
}
