import Foundation

/// Locker's side of the Claude Code hooks: the script the hooks run, the per-terminal signal files it writes,
/// and installing the hook entries into a folder's `.claude/settings.local.json`.
struct ActivityHookStore {
    var base: URL
    var git = GitClient()

    init(base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Locker")) {
        self.base = base
    }

    var activityDir: URL { base.appendingPathComponent("activity") }
    var scriptURL: URL { base.appendingPathComponent("hooks/" + ActivityHooks.marker) }
    static let settingsPath = ".claude/settings.local.json"

    /// A silent no-op outside Locker terminals (no env vars), so normal Claude Code use is never affected.
    /// It only ever writes the signal file; `end` is stored as text and read back as "no signal".
    static let script = """
    #!/bin/sh
    # Locker activity hook: records the latest Claude Code event for this terminal. Safe to run anywhere.
    [ -n "$LOCKER_TERMINAL_ID" ] && [ -n "$LOCKER_ACTIVITY_DIR" ] || exit 0
    printf '%s' "$1" > "$LOCKER_ACTIVITY_DIR/$LOCKER_TERMINAL_ID"
    exit 0

    """

    /// Environment a Locker terminal's shell needs so the hooks can find their signal file.
    func environment(for terminal: UUID) -> [String] {
        ["LOCKER_TERMINAL_ID=\(terminal.uuidString)", "LOCKER_ACTIVITY_DIR=\(activityDir.path)"]
    }

    /// Writes the hook script and creates the signal folder. Cheap; safe to call on every launch.
    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: activityDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != Self.script {
            try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    func signal(for terminal: UUID) -> ActivityHooks.Signal? {
        let url = activityDir.appendingPathComponent(terminal.uuidString)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ActivityHooks.Signal(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Forgets a terminal's last signal (Claude left the foreground), so a stale one can't carry into the next run.
    func clear(_ terminal: UUID) {
        try? Data().write(to: activityDir.appendingPathComponent(terminal.uuidString))
    }

    /// Adds Locker's hooks to `dir/.claude/settings.local.json`, keeping every other setting.
    func install(in dir: String) throws {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(Self.settingsPath)
        let merged = try ActivityHooks.merge(into: try? Data(contentsOf: url), scriptPath: scriptURL.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try merged.write(to: url, options: .atomic)
    }

    /// Removes only Locker's hooks. If nothing else is in the file it is emptied to `{}` rather than deleted.
    func uninstall(from dir: String) throws {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(Self.settingsPath)
        guard let data = try? Data(contentsOf: url) else { return }
        let rest = try ActivityHooks.removing(from: data) ?? Data("{}".utf8)
        try rest.write(to: url, options: .atomic)
    }

    func isInstalled(in dir: String) -> Bool {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(Self.settingsPath)
        return (try? Data(contentsOf: url)).map(ActivityHooks.isInstalled(in:)) ?? false
    }

    /// True when git would not list the settings file as untracked in `dir` (Claude Code normally ignores it).
    func settingsIsIgnored(in dir: String) -> Bool {
        (try? git.run(["check-ignore", "-q", Self.settingsPath], in: dir)) != nil
    }
}
