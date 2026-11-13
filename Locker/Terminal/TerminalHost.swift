import AppKit
import SwiftTerm

/// Abstraction over the terminal engine so SwiftTerm can be swapped later.
protocol TerminalHost: AnyObject {
    var view: NSView { get }
    var onExit: (() -> Void)? { get set }
    func start(cwd: String)
    func terminate()
}

final class SwiftTermHost: NSObject, TerminalHost, LocalProcessTerminalViewDelegate {
    private let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    var onExit: (() -> Void)?
    var view: NSView { term }

    override init() {
        super.init()
        term.processDelegate = self
        term.nativeBackgroundColor = NSColor(red: 0x17/255, green: 0x17/255, blue: 0x1A/255, alpha: 1)
        term.nativeForegroundColor = NSColor(red: 0xE6/255, green: 0xE6/255, blue: 0xE1/255, alpha: 1)
        term.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    }

    func start(cwd: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("COLORTERM=truecolor")
        term.startProcess(executable: shell, args: ["-l"], environment: env, execName: nil, currentDirectory: cwd)
    }

    func terminate() {
        term.processDelegate = nil
        term.terminate()
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in self?.onExit?() }
    }
}

/// Keeps live terminal views per terminal id so sessions survive workspace switching.
@MainActor
final class SessionRegistry {
    private var hosts: [UUID: TerminalHost] = [:]
    var onExit: ((UUID) -> Void)?

    func host(for spec: TerminalSpec) -> TerminalHost? {
        if let h = hosts[spec.id] { return h }
        guard FileManager.default.fileExists(atPath: spec.cwd) else { return nil }
        let h = SwiftTermHost()
        let id = spec.id
        h.onExit = { [weak self] in self?.onExit?(id) }
        hosts[spec.id] = h
        h.start(cwd: spec.cwd)
        return h
    }

    func close(_ id: UUID) {
        hosts[id]?.onExit = nil
        hosts[id]?.terminate()
        hosts[id] = nil
    }

    func isLive(_ id: UUID) -> Bool { hosts[id] != nil }
}
