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

    /// What the visible Claude Code screen shows right now. Only `.busy`, `.prompt` and `.idle` are positive
    /// matches; anything else is `.unknown`, which must never be read as "waiting for the user".
    enum Reading: Equatable { case busy, prompt, idle, unknown }

    /// Reads the visible screen of a terminal whose foreground job is Claude Code.
    /// - busy: a status line with "esc to interrupt", or background subagents still running (while the main agent
    ///   waits for them the interrupt hint disappears, but the subagent panel stays on screen).
    /// - prompt: a permission or choice menu ("Do you want to…", "❯ 1. Yes").
    /// - idle: the empty input box ("❯ …") with nothing busy on screen.
    static func read(screen: [String]) -> Reading {
        let lines = screen.map { $0.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces) }
        let lower = lines.map { $0.lowercased() }
        if lower.contains(where: { $0.contains("esc to interrupt") || $0.contains("ctrl+c to interrupt") }) { return .busy }
        if showsSubagents(lines: lines) { return .busy }
        if lower.contains(where: { $0.contains("do you want to") }) || lines.contains(where: { $0.hasPrefix("❯ 1.") }) {
            return .prompt
        }
        if lines.contains(where: { $0 == "❯" || $0.hasPrefix("❯ ") || $0 == ">" || $0.hasPrefix("> ") }) { return .idle }
        return .unknown
    }

    /// Subagents still running: the agent panel under the input box (a `⏺ main` row followed by `◯ <agent>` rows).
    /// The "Waiting for N background agents" status line is not used: it stays in the scrollback after they finish.
    private static func showsSubagents(lines: [String]) -> Bool {
        guard let main = lines.firstIndex(of: "⏺ main") else { return false }
        return lines.dropFirst(main + 1).contains { $0.hasPrefix("◯") }
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

/// Per-terminal memory that turns raw screen readings into a stable state, so one odd frame cannot flip the row.
/// busy => running now; prompt => waiting now; empty input box => waiting after `idleSamplesNeeded` consecutive
/// samples (a first sighting of Claude shows immediately); unknown => keep the previous state.
struct ActivityTracker {
    static let idleSamplesNeeded = 3
    private(set) var state: ClaudeActivity = .none
    private var idleSamples = 0

    /// `reading` is nil when Claude Code is not the terminal's foreground job.
    mutating func update(_ reading: ClaudeActivity.Reading?) -> ClaudeActivity {
        guard let reading else {
            self = ActivityTracker()
            return .none
        }
        switch reading {
        case .busy:
            state = .running; idleSamples = 0
        case .prompt:
            state = .waiting; idleSamples = 0
        case .idle:
            idleSamples += 1
            if state == .none || idleSamples >= Self.idleSamplesNeeded { state = .waiting }
        case .unknown:
            if state == .none { state = .waiting }
        }
        return state
    }
}
