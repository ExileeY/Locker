import Foundation

final class Store {
    let url: URL
    init(url: URL = Store.defaultURL) { self.url = url }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Locker/state.json")
    }

    func load() -> AppState {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AppState.self, from: data) else { return AppState() }
        return s
    }

    func save(_ state: AppState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(state).write(to: url, options: .atomic)
        } catch {
            NSLog("Locker: failed to save state: \(error)")
        }
    }
}
