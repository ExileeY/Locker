import Foundation

/// One repo's carry-over candidates as a folder tree that loads lazily. Git's collapsed listing gives the top level.
/// An ignored folder's contents are added one level at a time with `setChildren(of:_:)` when the user expands it.
/// A tracked folder holding ignored entries becomes a *group*: it can't be picked itself, but ticking it ticks what's
/// inside. A group with a single child is dropped, so its child shows with the longer path, e.g. ".claude/settings.local.json".
///
/// Selection lives outside, as a flat set of relative paths (`carryPicked`), so remembering choices and
/// `CarryOver.copy(paths:)` don't change. A ticked folder covers everything below it.
struct CarryTree: Equatable {
    enum Kind: Equatable { case file, folder, group }

    struct Node: Equatable {
        /// Relative to the repo's top level; folders and groups end in "/".
        var path: String
        var kind: Kind
        /// Bytes; nil while a folder's total isn't known yet. Groups are computed from their children (`size(of:)`).
        var size: Int64?
        var capped = false
        var source: CarryOver.Source = .detected
        var heavy = false
        var isDir: Bool { kind != .file }
    }

    enum CheckState: Equatable { case off, on, mixed }

    /// A line of the flattened tree.
    struct Row: Identifiable, Equatable {
        enum Note: Equatable { case loading, unreadable, empty }
        var id: String
        var depth: Int
        /// The node's path relative to its parent row.
        var name: String
        /// The parent row's path ("" at the top level).
        var parent: String
        var node: Node?
        /// A placeholder line under an expanded folder instead of its contents.
        var note: Note?
        var isOpen = false
    }

    private(set) var nodes: [String: Node] = [:]
    /// Children of the top level (""), of groups, and of folders whose contents were loaded. Nil for a folder not loaded yet.
    private(set) var children: [String: [String]] = [:]
    private(set) var unreadable: Set<String> = []
    /// Remembered or `.worktreeinclude` candidates inside an ignored folder, applied when that folder's contents load.
    private var pending: [String: CarryOver.Source] = [:]
    /// The paths to tick when the list first loads.
    private(set) var preselected: Set<String> = []

    var isEmpty: Bool { (children[""] ?? []).isEmpty }
    var topLevelCount: Int { children[""]?.count ?? 0 }

    init() {}

    init(candidates: [CarryOver.Candidate]) {
        preselected = Set(candidates.filter(\.preselected).map(\.path))
        let folders = Set(candidates.filter { $0.path.hasSuffix("/") }.map(\.path))
        var kids: [String: Set<String>] = [:]
        for c in candidates {
            let ancestors = CarryOver.ancestors(of: c.path)
            if ancestors.contains(where: folders.contains) { pending[c.path] = c.source; continue }
            nodes[c.path] = Node(path: c.path, kind: c.path.hasSuffix("/") ? .folder : .file, size: c.size,
                                 capped: c.sizeCapped, source: c.source, heavy: c.heavy)
            var child = c.path
            for a in ancestors.reversed() {
                kids[a, default: []].insert(child)
                if nodes[a] == nil { nodes[a] = Node(path: a, kind: .group) }
                child = a
            }
            kids["", default: []].insert(child)
        }
        children[""] = finishGroups(under: "", kids)
    }

    /// Sorts the children of `key`, dropping single-child groups and giving each group the best source of what it holds.
    private mutating func finishGroups(under key: String, _ kids: [String: Set<String>]) -> [String] {
        var out: [String] = []
        for var c in kids[key] ?? [] {
            while nodes[c]?.kind == .group, let only = kids[c], only.count == 1 {
                nodes[c] = nil
                c = only.first!
            }
            if nodes[c]?.kind == .group {
                let inside = finishGroups(under: c, kids)
                children[c] = inside
                let ns = inside.compactMap { nodes[$0] }
                nodes[c]?.source = ns.map(\.source).min() ?? .detected
                nodes[c]?.heavy = ns.allSatisfy(\.heavy)
            }
            out.append(c)
        }
        return sorted(out)
    }

    private func sorted(_ paths: [String]) -> [String] {
        paths.sorted { a, b in
            let x = nodes[a]!, y = nodes[b]!
            if x.source != y.source { return x.source < y.source }
            if x.heavy != y.heavy { return !x.heavy }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    // MARK: Loading

    /// Adds the contents of the ignored folder `folder`; nil `entries` marks it unreadable.
    mutating func setChildren(of folder: String, _ entries: [CarryOver.Entry]?) {
        guard let parent = nodes[folder], parent.kind == .folder else { return }
        guard let entries else { unreadable.insert(folder); children[folder] = []; return }
        unreadable.remove(folder)
        for e in entries where nodes[e.path] == nil {
            nodes[e.path] = Node(path: e.path, kind: e.isDir ? .folder : .file, size: e.isDir ? nil : e.size,
                                 source: pending.removeValue(forKey: e.path) ?? .detected,
                                 heavy: parent.heavy || CarryOver.isHeavy(e.path))
        }
        children[folder] = sorted(entries.map(\.path))
    }

    mutating func setSize(_ path: String, _ size: Int64, capped: Bool) {
        guard nodes[path] != nil else { return }
        nodes[path]?.size = size
        nodes[path]?.capped = capped
    }

    /// Keeps the folder totals `old` already knows, for a list reloaded in the background.
    mutating func adoptSizes(from old: CarryTree) {
        for (p, n) in nodes where n.kind == .folder && n.size == nil {
            if let o = old.nodes[p], let s = o.size { setSize(p, s, capped: o.capped) }
        }
    }

    /// Open folders whose contents aren't loaded yet, outermost first.
    func unloaded(in open: Set<String>) -> [String] {
        open.filter { nodes[$0]?.kind == .folder && children[$0] == nil }.sorted { $0.count < $1.count }
    }

    /// The next folder to size: top level first, then loaded folders breadth-first; build output after everything else.
    func nextUnsized(excluding busy: Set<String>) -> (path: String, heavy: Bool)? {
        var heavy: String?
        var queue = children[""] ?? []
        var i = 0
        while i < queue.count {
            let p = queue[i]; i += 1
            guard let n = nodes[p] else { continue }
            if n.kind == .folder, n.size == nil, !busy.contains(p) {
                if !n.heavy { return (p, false) }
                if heavy == nil { heavy = p }
            }
            queue += children[p] ?? []
        }
        return heavy.map { ($0, true) }
    }

    /// Folders to open at first so preselected entries inside them are visible.
    var initialOpen: Set<String> {
        var out: Set<String> = []
        for p in preselected {
            for a in CarryOver.ancestors(of: p) where nodes[a] != nil || isInsideFolder(a) { out.insert(a) }
        }
        return out
    }

    private func isInsideFolder(_ p: String) -> Bool {
        CarryOver.ancestors(of: p).contains { nodes[$0]?.kind == .folder }
    }

    // MARK: Sizes

    /// A node's size; a group adds up its children and is nil until all of them are known.
    func size(of path: String) -> (Int64, capped: Bool)? {
        guard let n = nodes[path] else { return nil }
        guard n.kind == .group else { return n.size.map { ($0, n.capped) } }
        var total: Int64 = 0, capped = false
        for c in children[path] ?? [] {
            guard let s = size(of: c) else { return nil }
            total += s.0
            capped = capped || s.capped
        }
        return (total, capped)
    }

    /// The total size of the picked paths, or nil while any of them is unknown.
    func pickedSize(_ picked: Set<String>) -> (Int64, capped: Bool)? {
        var total: Int64 = 0, capped = false
        for p in picked {
            guard let s = size(of: p) else { return nil }
            total += s.0
            capped = capped || s.capped
        }
        return (total, capped)
    }

    // MARK: Selection

    func checkState(_ path: String, _ picked: Set<String>) -> CheckState {
        if picked.contains(path) || CarryOver.ancestors(of: path).contains(where: picked.contains) { return .on }
        guard let n = nodes[path] else { return .off }
        switch n.kind {
        case .file:
            return .off
        case .folder:
            return picked.contains { $0.hasPrefix(path) } ? .mixed : .off
        case .group:
            let states = (children[path] ?? []).map { checkState($0, picked) }
            if states.allSatisfy({ $0 == .on }) { return .on }
            if states.allSatisfy({ $0 == .off }) { return .off }
            return .mixed
        }
    }

    /// `picked` after clicking the checkbox of `path`. Ticking a folder replaces the picks inside it. Unticking an entry
    /// inside a ticked folder replaces that folder with the entry's siblings at each level down to it.
    func toggle(_ path: String, _ picked: Set<String>) -> Set<String> {
        guard let n = nodes[path] else { return picked }
        var s = picked
        let on = checkState(path, s) == .on
        if n.kind == .group {
            if on { return s.filter { !$0.hasPrefix(path) } }
            for c in children[path] ?? [] where checkState(c, s) != .on { s = toggle(c, s) }
            return s
        }
        if !on {
            if n.isDir { s = s.filter { !$0.hasPrefix(path) } }
            s.insert(path)
            return s
        }
        if s.remove(path) != nil { return s }
        guard let covering = CarryOver.ancestors(of: path).first(where: s.contains) else { return s }
        s.remove(covering)
        var cur = covering
        while cur != path, let kids = children[cur],
              let next = kids.first(where: { $0 == path || ($0.hasSuffix("/") && path.hasPrefix($0)) }) {
            for k in kids where k != next { s.insert(k) }
            cur = next
        }
        return s
    }

    // MARK: Rows

    /// The flattened rows to draw: children of `open` folders, and with a `filter`, only entries whose path contains it
    /// (or that lead to one), with the folders on the way opened. The filter only sees what is already loaded.
    func visibleRows(open: Set<String>, filter: String = "") -> [Row] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var memo: [String: Bool] = [:]
        func hits(_ p: String) -> Bool {
            if let m = memo[p] { return m }
            let r = p.lowercased().contains(q) || (children[p] ?? []).contains(where: hits)
            memo[p] = r
            return r
        }
        var rows: [Row] = []
        func walk(_ key: String, depth: Int, showAll: Bool) {
            for c in children[key] ?? [] {
                guard let n = nodes[c] else { continue }
                let selfHit = q.isEmpty || c.lowercased().contains(q)
                if !showAll && !hits(c) { continue }
                let below = !showAll && !selfHit   // shown only because something inside matches
                let isOpen = n.isDir && (open.contains(c) || below)
                rows.append(Row(id: c, depth: depth, name: String(c.dropFirst(key.count)), parent: key, node: n, isOpen: isOpen))
                guard isOpen else { continue }
                if unreadable.contains(c) {
                    rows.append(Row(id: "\u{0}" + c, depth: depth + 1, name: "", parent: c, note: .unreadable))
                } else if let kids = children[c] {
                    if kids.isEmpty { rows.append(Row(id: "\u{0}" + c, depth: depth + 1, name: "", parent: c, note: .empty)) }
                    else { walk(c, depth: depth + 1, showAll: showAll || selfHit) }
                } else {
                    rows.append(Row(id: "\u{0}" + c, depth: depth + 1, name: "", parent: c, note: .loading))
                }
            }
        }
        walk("", depth: 0, showAll: q.isEmpty)
        return rows
    }
}
