import SwiftUI
import AppKit

struct WorkspaceDetail: View {
    @EnvironmentObject var model: AppModel
    let ws: Workspace
    @State private var formOpen = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if formOpen {
                (Text("Branches from ") + Text(ws.branch).font(Theme.mono(12)) +
                 Text(" in this workspace only. Your other workspaces stay on their branches."))
                    .font(.system(size: 12)).foregroundStyle(Color(hex: 0x2A3A80))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(Color(hex: 0xF4F6FE))
            }
            if !model.missing.isEmpty {
                HStack {
                    Text("Some worktrees were deleted outside Locker: " + ws.repos.filter { model.missing.contains($0.id) }.map(\.repoName).joined(separator: ", "))
                    Spacer()
                    Button("Repair") { model.repair(ws) }.buttonStyle(OutlineButton())
                }
                .font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 8)
                .background(Color(hex: 0xFFF4E5))
            }
            TerminalArea(ws: ws)
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            Text(ws.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
            ForEach(ws.repos) { r in BranchChip(repo: r, status: model.statuses[r.id], missing: model.missing.contains(r.id)) }
            Spacer()
            if formOpen {
                Text("New branch").font(.system(size: 13, weight: .medium))
                TextField("feature/my-change", text: $draft)
                    .textFieldStyle(.plain).font(Theme.mono(12))
                    .padding(.horizontal, 10).frame(width: 240, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: 0xB9B9B3)))
                    .onSubmit(create)
                Button("Cancel") { formOpen = false; draft = "" }.buttonStyle(OutlineButton())
                Button("Create", action: create).buttonStyle(PrimaryButton())
            } else {
                Button { formOpen = true } label: { Label("New branch", systemImage: "arrow.triangle.branch") }
                    .buttonStyle(OutlineButton())
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 60)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xECECE8)).frame(height: 1) }
    }

    func create() {
        let name = draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty else { return }
        Task { if await model.createBranch(name) { formOpen = false; draft = "" } }
    }
}

struct BranchChip: View {
    let repo: WorkspaceRepo
    let status: GitStatus?
    let missing: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
            Text(repo.repoName).fontWeight(.semibold)
            Text(missing ? "missing" : (status?.branch ?? "…"))
            if status?.dirty == true { Circle().fill(Theme.amber).frame(width: 6, height: 6).help("Uncommitted changes") }
        }
        .font(Theme.mono(11.5)).padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(missing ? Color(hex: 0xFFF4E5) : Theme.chipBG))
        .foregroundStyle(missing ? Theme.amber : Theme.chipFG)
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
                        .foregroundStyle(Color(hex: 0xC8C8C2)).frame(width: 32, height: 32)
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
                    Text("This terminal's folder no longer exists.").foregroundStyle(Color(hex: 0xC8C8C2))
                } else {
                    VStack(spacing: 12) {
                        Text("No terminals open in this workspace.")
                        Button("Open a terminal") { model.addTerminal() }
                            .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0x2A2A2F)))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: 0x45454A)))
                    }.foregroundStyle(Color(hex: 0xC8C8C2))
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
                .foregroundStyle(on ? Color.white : Color(hex: 0xA6A6A0))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { model.closeTerminal(spec.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(hex: 0xA6A6A0)).frame(width: 22, height: 22)
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
