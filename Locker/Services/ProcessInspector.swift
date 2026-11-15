import Foundation
import Darwin

/// Reads which processes own a terminal's foreground, using libproc and sysctl (no subprocesses).
enum ProcessInspector {
    /// Processes in the pty's foreground process group, as (executable path, argv). Empty if none or on error.
    static func foregroundProcesses(ptyFD: Int32) -> [(path: String, args: [String])] {
        guard ptyFD >= 0 else { return [] }
        let pgid = tcgetpgrp(ptyFD)
        guard pgid > 0 else { return [] }
        return pids(inGroup: pgid).compactMap(arguments(of:))
    }

    static func isClaudeInForeground(ptyFD: Int32) -> Bool {
        foregroundProcesses(ptyFD: ptyFD).contains { ClaudeActivity.isClaudeProcess(executablePath: $0.path, arguments: $0.args) }
    }

    static func pids(inGroup pgid: pid_t) -> [pid_t] {
        let n = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) / MemoryLayout<pid_t>.size + 8)
        let got = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        return Array(buf.prefix(Int(got) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    /// Executable path and argv from KERN_PROCARGS2. Nil for processes we may not inspect.
    static func arguments(of pid: pid_t) -> (path: String, args: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return nil }
        let argc = data.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        func cString() -> String? {
            guard i < size else { return nil }
            let start = i
            while i < size, data[i] != 0 { i += 1 }
            let s = String(decoding: data[start..<i], as: UTF8.self)
            return s
        }
        guard let path = cString() else { return nil }
        while i < size, data[i] == 0 { i += 1 }   // padding after the exec path
        var args: [String] = []
        while args.count < argc, let a = cString() { args.append(a); i += 1 }
        return (path, args)
    }
}
