import SwiftUI
import AppKit

struct WorkspaceDetail: View {
    @EnvironmentObject var model: AppModel
    let ws: Workspace
    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.missing.isEmpty {
                HStack {
                    Text("Some worktrees were deleted outside Locker: " + ws.repos.filter { model.missing.contains($0.id) }.map(\.repoName).joined(separator: ", "))
                    Spacer()
                    Button("Repair") { model.repair(ws) }.buttonStyle(OutlineButton())
                }
                .font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 8)
                .background(Theme.amberBG)
            }
            TerminalArea(ws: ws)
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            Text(ws.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
            ForEach(ws.repos) { r in BranchChip(ws: ws, repo: r, status: model.statuses[r.id], missing: model.missing.contains(r.id)) }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 60)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.headerLine).frame(height: 1) }
    }
}

/// Per-repo branch chip. Clicking opens a picker to switch this repo's worktree only.
struct BranchChip: View {
    @EnvironmentObject var model: AppModel
    let ws: Workspace
    let repo: WorkspaceRepo
    let status: GitStatus?
    let missing: Bool
    @State private var open = false

    private var detached: Bool { status?.detached == true }

    var body: some View {
        Button { if !missing { open = true } } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text(repo.repoName).fontWeight(.semibold)
                Text(missing ? "missing" : label)
                if status?.dirty == true { Circle().fill(Theme.amber).frame(width: 6, height: 6).help("Uncommitted changes") }
                if !missing { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .font(Theme.mono(11.5)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(missing || detached ? Theme.amberBG : Theme.chipBG))
            .foregroundStyle(missing || detached ? Theme.amber : Theme.chipFG)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(detached ? "Detached HEAD: commits here belong to no branch until you create one." : "Switch branch in this workspace")
        .popover(isPresented: $open, arrowEdge: .bottom) { BranchPicker(ws: ws, repo: repo, detached: detached) { open = false } }
    }

    private var label: String {
        guard let s = status else { return "…" }
        return s.detached ? "detached @ \(repo.baseBranch)" : s.branch
    }
}

struct BranchPicker: View {
    @EnvironmentObject var model: AppModel
    let ws: Workspace
    let repo: WorkspaceRepo
    let detached: Bool
    let close: () -> Void
    @State private var choices: [WorkspaceService.BranchChoice] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var newName = ""
    @State private var busy = false
    /// An action waiting for the user to accept losing unbranched commits.
    @State private var pending: (title: String, run: () async -> Bool)?
    @State private var lost = 0

    private var filtered: [WorkspaceService.BranchChoice] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? choices : choices.filter { $0.name.lowercased().contains(q) }
    }

    func owner(of path: String) -> String {
        if let w = model.state.workspaces.first(where: { path.hasPrefix($0.root + "/") }) { return "workspace “\(w.name)”" }
        return "the source repo"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Switch \(repo.repoName) to…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            Text("Only this workspace changes. Your other workspaces stay as they are.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            if let p = pending {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(lost) commit\(lost == 1 ? "" : "s") on this detached HEAD belong to no branch and will be left behind (recoverable only via git reflog).")
                        .font(.system(size: 12)).foregroundStyle(Theme.amber)
                    HStack {
                        Button("Cancel") { pending = nil }.buttonStyle(OutlineButton())
                        Button(p.title) { run(p.run, confirmed: true) }.buttonStyle(PrimaryButton())
                    }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Theme.amberBG))
            }
            if !detached {
                row("Detach at \(repo.baseBranch)", note: "no branch") { await model.detach(ws, repo) }
            }
            TextField("Search branches", text: $query).textFieldStyle(.roundedBorder).font(Theme.mono(12))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !loaded { ProgressView().controlSize(.small) }
                    ForEach(filtered) { c in
                        row(c.name, note: c.occupiedAt.map { "in use by \(owner(of: $0))" } ?? (c.remoteOnly ? "from origin" : nil),
                            disabled: c.occupiedAt != nil || c.name == status) { await model.switchBranch(ws, repo, to: c) }
                    }
                }
            }.frame(height: 160)
            Divider()
            Text("New branch from here").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            HStack {
                TextField("feature/my-change", text: $newName).textFieldStyle(.roundedBorder).font(Theme.mono(12)).onSubmit(create)
                Button("Create", action: create).buttonStyle(PrimaryButton()).disabled(cleanName.isEmpty || busy)
            }
        }
        .padding(14).frame(width: 340)
        .task { choices = await model.branchChoices(repo); loaded = true }
    }

    private var status: String { model.statuses[repo.id]?.branch ?? "" }
    private var cleanName: String { newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-") }

    private func create() {
        let n = cleanName
        guard !n.isEmpty else { return }
        run({ await model.createBranch(n, in: ws, repo) }, confirmed: true)
    }

    private func row(_ title: String, note: String?, disabled: Bool = false, action: @escaping () async -> Bool) -> some View {
        Button { run(action, confirmed: false, title: "Switch anyway") } label: {
            HStack {
                Text(title).font(Theme.mono(12)).lineLimit(1)
                Spacer()
                if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.muted) }
            }
            .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled || busy).opacity(disabled ? 0.5 : 1)
    }

    /// Switching away from a detached HEAD with unbranched commits asks first; creating a branch never loses them.
    private func run(_ action: @escaping () async -> Bool, confirmed: Bool, title: String = "Switch anyway") {
        Task {
            if !confirmed && detached {
                let n = await model.unbranchedCommits(repo)
                if n > 0 { lost = n; pending = (title, action); return }
            }
            busy = true
            let ok = await action()
            busy = false
            if ok { close() }
        }
    }
}

struct TerminalArea: View {
    @EnvironmentObject var model: AppModel
    let ws: Workspace

    var current: Workspace { model.state.workspaces.first { $0.id == ws.id } ?? ws }

    var body: some View {
        let w = current
        let active = w.terminals.first { $0.id == w.activeTerminal } ?? w.terminals.first
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(w.terminals) { t in TabButton(spec: t, on: t.id == active?.id) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Button { model.addTerminal() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.termText).frame(width: 32, height: 32)
                }
                .buttonStyle(.plain).help("New terminal tab (⌘T)").padding(.bottom, 3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.top, 8).background(Theme.tabStrip)

            ZStack {
                Theme.termBG
                if let active, let host = model.sessions.host(for: active) {
                    TerminalContainer(view: host.view).id(active.id).padding(.leading, 8).padding(.top, 4)
                } else if active != nil {
                    Text("This terminal's folder no longer exists.").foregroundStyle(Theme.termText)
                } else {
                    VStack(spacing: 12) {
                        Text("No terminals open in this workspace.")
                        Button("Open a terminal") { model.addTerminal() }
                            .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.termButtonBG))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.termButtonBorder))
                    }.foregroundStyle(Theme.termText)
                }
            }
        }
    }
}

struct TabButton: View {
    @EnvironmentObject var model: AppModel
    let spec: TerminalSpec
    let on: Bool
    var body: some View {
        HStack(spacing: 0) {
            Button { model.activate(spec.id) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "terminal").font(.system(size: 11))
                    Text(spec.title).font(.system(size: 12.5, weight: .medium))
                    if let l = spec.repoLabel, l != spec.title {
                        Text(l).font(Theme.mono(10.5)).opacity(0.7)
                    }
                }
                .padding(.leading, 12).padding(.trailing, 6).frame(height: 34)
                .foregroundStyle(on ? Color.white : Theme.termMuted)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { model.closeTerminal(spec.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.termMuted).frame(width: 22, height: 22)
            }.buttonStyle(.plain).padding(.trailing, 6).help("Close \(spec.title)")
        }
        .background(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).fill(on ? Theme.termBG : .clear))
    }
}

/// Hosts a long-lived AppKit terminal view; the view is owned by SessionRegistry, not by SwiftUI.
struct TerminalContainer: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView {
        let c = NSView()
        attach(view, to: c)
        return c
    }
    func updateNSView(_ c: NSView, context: Context) {
        if view.superview !== c { c.subviews.forEach { $0.removeFromSuperview() }; attach(view, to: c) }
    }
    private func attach(_ v: NSView, to c: NSView) {
        v.removeFromSuperview()
        v.frame = c.bounds
        v.autoresizingMask = [.width, .height]
        c.addSubview(v)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
    }
}
