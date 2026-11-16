import Foundation

/// Git-ignored files (local settings, `.env`, `.mcp.json`…) live only in a repo's original checkout, so a new
/// worktree starts without them. `CarryOver` lists them for the composer and copies the chosen ones across.
struct CarryOver {
    var git = GitClient()

    /// Why an entry is offered, in the order the composer lists them.
    enum Source: Int, Comparable {
        /// Chosen last time for this repo (`Repo.carryOver`).
        case remembered
        /// Matched by the repo's own `.worktreeinclude` (gitignore syntax).
        case worktreeinclude
        /// Ignored by git, nothing else known.
        case detected
        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    struct Candidate: Identifiable, Hashable {
        /// Relative to the repo's top level; folders end in "/".
        var path: String
        /// Bytes; nil for a folder, whose total is computed later with `size(of:fileCap:)`.
        var size: Int64?
        /// The size scan stopped early: `size` is a lower bound.
        var sizeCapped = false
        var source: Source
        /// Build output or a dependency folder: never preselected by detection.
        var heavy: Bool
        var id: String { path }
        var preselected: Bool { source != .detected }
    }

    static let includeFile = ".worktreeinclude"
    /// Folder names treated as build output or installed dependencies.
    static let heavyNames: Set<String> = [
        "node_modules", "build", "Build", "DerivedData", ".build", "dist", "out", "target", "Pods", "Carthage",
        ".gradle", ".venv", "venv", "__pycache__", ".next", ".nuxt", ".turbo", ".parcel-cache", "coverage",
        ".cache", ".swiftpm", ".tox", "vendor", "tmp", ".terraform",
    ]
    /// Ignored noise that is never offered unless it was remembered.
    static let junkNames: Set<String> = [".DS_Store"]
    static let sizeCap: Int64 = 1 << 30
    static let fileCap = 50_000
    /// Build output and dependency folders are sized last with this lower file cap.
    static let heavyFileCap = 10_000
    /// The most `.worktreeinclude` matches read from inside ignored folders.
    static let includeListCap = 5_000

    /// A file or folder inside an ignored folder, from `entries(in:root:)`.
    struct Entry: Equatable {
        /// Relative to the repo's top level; folders end in "/".
        var path: String
        var isDir: Bool
        /// Bytes for a file; 0 for a folder.
        var size: Int64
    }

    /// What decides the candidate list, so a cached list can tell when it is stale.
    struct Stamp: Equatable {
        var modified: [Date?]
        var remembered: [String]
    }

    /// The ignored entries of `repo`'s original checkout, with remembered and `.worktreeinclude` matches first.
    /// Files carry their size; folders are left unsized (see `size(of:fileCap:)`). Runs git: call it off the main thread.
    func candidates(for repo: Repo) -> [Candidate] {
        let root = repo.path
        let ignored = git.ignoredEntries(in: root).filter { !Self.junkNames.contains(Self.name(of: $0)) }
        let ignoredSet = Set(ignored)
        let dirs = ignored.filter { $0.hasSuffix("/") }
        let dirSet = Set(dirs)
        /// The ignored entry `p` is, or lies inside; nil when git doesn't ignore it.
        func ignoredContainer(_ p: String) -> String? {
            ignoredSet.contains(p) ? p : Self.ancestors(of: p).first(where: dirSet.contains)
        }
        /// Ignored entries below each folder path.
        var under: [String: [String]] = [:]
        for p in ignored { for a in Self.ancestors(of: p) { under[a, default: []].append(p) } }

        var source: [String: Source] = [:]
        func offer(_ p: String, _ s: Source) {
            guard Self.normalized(p) != nil, ignoredContainer(p) != nil, Self.exists(root + "/" + p) else { return }
            source[p] = min(source[p] ?? .detected, s)
        }
        for p in ignored { source[p] = .detected }
        // An include match that is an ignored entry, or a folder holding some, preselects those entries. A match
        // inside an ignored folder is offered on its own, so the whole folder isn't preselected for one file.
        if Self.exists(root + "/" + Self.includeFile) {
            var matches = git.ignoredEntries(in: root, excludeFrom: Self.includeFile)
            let matchedDirs = Set(matches.filter { $0.hasSuffix("/") })
            // The collapsed listing doesn't look inside untracked folders, so list the files of ignored folders
            // the first pass didn't match whole. Heavy folders are skipped, and the listing is capped: both can be huge.
            let unmatched = dirs.filter { d in
                !Self.isHeavy(d) && !matchedDirs.contains(d) && !Self.ancestors(of: d).contains(where: matchedDirs.contains)
            }
            if !unmatched.isEmpty {
                matches += git.ignoredEntries(in: root, excludeFrom: Self.includeFile, collapse: false, within: unmatched)
                    .prefix(Self.includeListCap)
            }
            for w in matches {
                let inside = w.hasSuffix("/") ? (ignoredSet.contains(w) ? [w] : []) + (under[w] ?? []) : []
                if inside.isEmpty { offer(w, .worktreeinclude) } else { inside.forEach { offer($0, .worktreeinclude) } }
            }
        }
        for p in repo.carryOver { offer(p, .remembered) }

        return source.map { p, s in
            Candidate(path: p, size: p.hasSuffix("/") ? nil : Self.fileSize(root + "/" + p), source: s, heavy: Self.isHeavy(p))
        }
        .sorted { a, b in
            if a.source != b.source { return a.source < b.source }
            if a.heavy != b.heavy { return !a.heavy }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }

    /// Copies each relative path from the original checkout `from` into the worktree `to`, as APFS clones where
    /// possible (`FileManager.copyItem`; symlinks are copied as links). Never overwrites: a path already in the
    /// worktree (a tracked file) is skipped. Returns one message per path that wasn't copied; it never throws.
    func copy(paths: [String], from: String, to: String) -> [String] {
        let fm = FileManager.default
        var warnings: [String] = []
        var valid: [String] = []
        for p in paths {
            if let n = Self.normalized(p) { valid.append(n) }
            else { warnings.append("“\(p)” wasn't copied: only paths inside the repository can be copied.") }
        }
        // A path inside another chosen folder is copied with that folder.
        let unique = Set(valid)
        let roots = unique.sorted().filter { p in !unique.contains { $0 != p && p.hasPrefix($0 + "/") } }
        for p in roots {
            let src = from + "/" + p, dst = to + "/" + p
            guard Self.exists(src) else {
                warnings.append("“\(p)” wasn't copied: it no longer exists in the original checkout."); continue
            }
            guard Self.exists(dst) == false else {
                warnings.append("“\(p)” wasn't copied: the workspace already has it (tracked by git)."); continue
            }
            // A symlinked folder on the way must not lead the copy outside either checkout.
            guard Self.resolvesInside(Self.parent(of: src), from), Self.resolvesInside(Self.parent(of: dst), to) else {
                warnings.append("“\(p)” wasn't copied: its folder links outside the repository."); continue
            }
            do {
                try fm.createDirectory(atPath: Self.parent(of: dst), withIntermediateDirectories: true)
                try fm.copyItem(atPath: src, toPath: dst)
            } catch {
                try? fm.removeItem(atPath: dst)   // don't leave half a folder behind
                warnings.append("“\(p)” wasn't copied: \(error.localizedDescription)")
            }
        }
        return warnings
    }

    /// One level of the ignored folder `folder` (relative, ending in "/"), without `junkNames`. Symlinks are listed as
    /// files and never followed. Nil when the folder can't be read. Reads the disk: call it off the main thread.
    static func entries(in folder: String, root: String) -> [Entry]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let url = URL(fileURLWithPath: root + "/" + folder)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return nil }
        return urls.compactMap { u in
            let name = u.lastPathComponent
            guard !junkNames.contains(name) else { return nil }
            let v = try? u.resourceValues(forKeys: Set(keys))
            let dir = v?.isDirectory == true && v?.isSymbolicLink != true
            return Entry(path: folder + name + (dir ? "/" : ""), isDir: dir, size: dir ? 0 : Int64(v?.fileSize ?? 0))
        }
    }

    static func stamp(for repo: Repo) -> Stamp {
        let files = [".gitignore", includeFile, ".git/info/exclude"]
        let dates = files.map { (try? FileManager.default.attributesOfItem(atPath: repo.path + "/" + $0))?[.modificationDate] as? Date }
        return Stamp(modified: dates, remembered: repo.carryOver)
    }

    // MARK: Helpers

    /// The folder paths `p` lies inside, outermost first: "a/b/c.txt" -> ["a/", "a/b/"]. A folder isn't its own ancestor.
    static func ancestors(of p: String) -> [String] {
        var out: [String] = []
        var i = p.startIndex
        while let slash = p[i...].firstIndex(of: "/") {
            let end = p.index(after: slash)
            if end == p.endIndex { break }
            out.append(String(p[..<end]))
            i = end
        }
        return out
    }

    /// The path without a trailing "/", or nil when it is empty, absolute, or steps outside with "..".
    static func normalized(_ p: String) -> String? {
        var s = p
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, !s.hasPrefix("/"), !s.hasPrefix("~") else { return nil }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        return s
    }

    static func isHeavy(_ p: String) -> Bool {
        p.split(separator: "/").contains { heavyNames.contains(String($0)) }
    }

    private static func name(of p: String) -> String {
        p.split(separator: "/").last.map(String.init) ?? p
    }

    private static func parent(of p: String) -> String {
        (p as NSString).deletingLastPathComponent
    }

    /// True when something (even a dangling symlink) is at `path`.
    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Whether `path`'s deepest existing ancestor, with symlinks resolved, is `root` or inside it.
    private static func resolvesInside(_ path: String, _ root: String) -> Bool {
        var p = path
        while !exists(p), p != "/", !p.isEmpty { p = parent(of: p) }
        let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        return real == base || real.hasPrefix(base + "/")
    }

    /// The size of the file or symlink itself at `path`; 0 when nothing is there.
    static func fileSize(_ path: String) -> Int64 {
        var st = stat()
        return lstat(path, &st) == 0 ? Int64(st.st_size) : 0
    }

    /// Bytes under `path`, without following symlinks. Stops at `sizeCap` bytes or `fileCap` files. Throws
    /// `CancellationError` when the calling task is cancelled, so a walk nobody needs any more stops early.
    static func size(of path: String, fileCap: Int = fileCap) throws -> (Int64, capped: Bool) {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return (0, false) }
        if v.isSymbolicLink == true || v.isDirectory != true { return (Int64(v.fileSize ?? 0), false) }
        // The enumerator prefetches `fileSizeKey`, so reading it below doesn't touch the disk again.
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, false) }
        var total: Int64 = 0, files = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            files += 1
            if files & 255 == 0 { try Task.checkCancellation() }
            if total >= sizeCap || files >= fileCap { return (total, true) }
        }
        return (total, false)
    }
}
