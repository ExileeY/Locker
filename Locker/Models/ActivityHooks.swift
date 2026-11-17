import Foundation

/// Claude Code hooks that tell Locker exactly what a terminal's Claude is doing, so the sidebar does not depend
/// only on reading the screen. The hook script writes the latest signal to a per-terminal file; this type builds
/// and strips the matching entries in a project's `.claude/settings.local.json` without touching anything else.
enum ActivityHooks {
    /// What the hook script records for a terminal. Any other content (such as `end`) means "no signal".
    enum Signal: String {
        /// A turn or tool call is in progress (UserPromptSubmit, PreToolUse, PostToolUse).
        case busy
        /// Claude asked the user something: permission, question or idle reminder (Notification).
        case prompt
        /// The main agent finished its turn (Stop). Subagent stops are deliberately not hooked.
        case stop
    }

    /// Part of every Locker hook command; entries containing it belong to Locker and are the only ones rewritten.
    static let marker = "locker-hook.sh"

    /// Hook event → argument passed to the script. `end` (SessionEnd) clears the terminal's signal.
    static let events: [(event: String, arg: String)] = [
        ("UserPromptSubmit", "busy"), ("PreToolUse", "busy"), ("PostToolUse", "busy"),
        ("Notification", "prompt"), ("Stop", "stop"), ("SessionEnd", "end"),
    ]

    struct InvalidSettings: Error, LocalizedError {
        var errorDescription: String? { "The existing .claude/settings.local.json is not valid JSON, so Locker left it alone." }
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] else { throw InvalidSettings() }
        return dict
    }

    private static func encode(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func isLockerEntry(_ entry: Any) -> Bool {
        guard let e = entry as? [String: Any], let hooks = e["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    /// Settings JSON with Locker's hooks added (replacing any earlier Locker entries) and everything else kept.
    static func merge(into existing: Data?, scriptPath: String) throws -> Data {
        var root = try parse(existing)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, arg) in events {
            var entries = (hooks[event] as? [Any] ?? []).filter { !isLockerEntry($0) }
            entries.append(["hooks": [["type": "command", "command": "\"\(scriptPath)\" \(arg)"]]])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        return try encode(root)
    }

    /// Settings JSON without Locker's hooks, or nil when nothing else is left (the file can be deleted).
    static func removing(from existing: Data) throws -> Data? {
        var root = try parse(existing)
        if var hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                let kept = (value as? [Any] ?? []).filter { !isLockerEntry($0) }
                if kept.isEmpty { hooks[event] = nil } else { hooks[event] = kept }
            }
            if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        }
        return root.isEmpty ? nil : try encode(root)
    }

    static func isInstalled(in data: Data) -> Bool {
        guard let root = try? parse(data), let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [Any] ?? []).contains(where: isLockerEntry) }
    }
}
