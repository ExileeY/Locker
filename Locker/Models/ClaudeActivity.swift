import Foundation

/// Claude Code state for a terminal or a whole workspace. Higher `rawValue` wins when combining.
enum ClaudeActivity: Int, Comparable {
    case none = 0, running = 1, waiting = 2

    static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }

    var label: String {
        switch self {
        case .waiting: "Needs your input"
        case .running: "Claude Code running"
        case .none: "No Claude session"
        }
    }

    /// Priority: waiting, then running, then none.
    static func combined<S: Sequence>(_ all: S) -> ClaudeActivity where S.Element == ClaudeActivity {
        all.max() ?? .none
    }

    /// Classifies a terminal whose foreground job is Claude Code from its visible screen text.
    /// While working, Claude Code shows a status line with "esc to interrupt"; otherwise it is waiting for the
    /// user (a permission prompt, a question, or the input box after finishing a turn).
    static func classify(claudeInForeground: Bool, screen: [String]) -> ClaudeActivity {
        guard claudeInForeground else { return .none }
        let working = screen.contains { line in
            let l = line.lowercased()
            return l.contains("esc to interrupt") || l.contains("ctrl+c to interrupt")
        }
        return working ? .running : .waiting
    }

    /// True when a process looks like Claude Code: the native binary (`claude`, or `.../claude/versions/<v>`)
    /// or the npm package run by node. Aliases resolve to these; custom wrappers may not.
    static func isClaudeProcess(executablePath: String, arguments: [String]) -> Bool {
        let exe = executablePath
        if (exe as NSString).lastPathComponent == "claude" || exe.contains("/claude/versions/") { return true }
        if let a0 = arguments.first, (a0 as NSString).lastPathComponent == "claude" { return true }
        return arguments.contains { $0.contains("@anthropic-ai/claude-code") }
    }
}
