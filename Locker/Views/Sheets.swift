import SwiftUI
import AppKit

struct NewWorkspaceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var branch = ""
    @State private var branchEdited = false
    @State private var chosen: Set<UUID> = []
    @State private var bases: [UUID: String] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var progress = ""
    @State private var branchStates: [UUID: BranchState] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New workspace").font(.system(size: 16, weight: .bold))
            field("Name", text: $name, prompt: "Apple Pay")
                .onChange(of: name) { _, v in error = nil; if !branchEdited { branch = WorkspaceService.slug(v).lowercased() } }
            field("Branch (same in every repo)", text: Binding(get: { branch }, set: { branch = $0; branchEdited = true }), prompt: "feature/apple-pay", mono: true)
                .onChange(of: branch) { _, _ in error = nil }
                .task(id: BranchKey(branch: branch, repos: model.state.repos.map(\.id))) { await refreshBranchStates() }
            HStack {
                Text("Repositories").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Add repository…") { pickRepo() }.buttonStyle(.plain).foregroundStyle(Theme.chipFG).font(.system(size: 12))
            }
            if model.state.repos.isEmpty {
                Text("Add at least one git repository.").foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.state.repos) { r in
                        HStack {
                            Toggle(isOn: Binding(get: { chosen.contains(r.id) }, set: { if $0 { chosen.insert(r.id) } else { chosen.remove(r.id) } })) {
                                VStack(alignment: .leading) {
                                    Text(r.name).fontWeight(.medium)
                                    Text(r.path).font(.system(size: 10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                            }.disabled(model.repoMissing(r))
                            Spacer()
                            if model.repoMissing(r) {
                                Text("missing").font(.system(size: 11)).foregroundStyle(Theme.amber)
                            } else if branchStates[r.id] == .existing || branchStates[r.id] == .remote {
                                Text(branchStates[r.id] == .existing ? "existing branch" : "from origin")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.green)
                            } else {
                                if branchStates[r.id] == .new { Text("new").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.chipFG) }
                                Text("from").font(.system(size: 11)).foregroundStyle(Theme.muted)
                                TextField(r.defaultBranch, text: Binding(get: { bases[r.id] ?? r.defaultBranch }, set: { bases[r.id] = $0; error = nil }))
                                    .font(Theme.mono(11.5)).frame(width: 110).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
            }.frame(height: 150)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Color(hex: 0xB42318)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(Color(hex: 0xFEF3F2)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0xB42318).opacity(0.5)))
                    .accessibilityIdentifier("create-error")
            }
            HStack {
                if busy { ProgressView().controlSize(.small); Text(progress).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                else if let hint = disabledReason { Text(hint).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButton()).keyboardShortcut(.cancelAction)
                Button(busy ? "Creating…" : "Create") { create() }.buttonStyle(PrimaryButton())
                    .disabled(busy || disabledReason != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
    }

    struct BranchKey: Equatable { var branch: String; var repos: [UUID] }

    var disabledReason: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a workspace name." }
        if branch.isEmpty { return "Enter a branch name." }
        if chosen.isEmpty { return "Select at least one repository." }
        for r in model.state.repos where chosen.contains(r.id) {
            if branchStates[r.id] == .new, (bases[r.id] ?? r.defaultBranch).trimmingCharacters(in: .whitespaces).isEmpty {
                return "Enter a base branch for \(r.name)."
            }
        }
        return nil
    }

    func refreshBranchStates() async {
        try? await Task.sleep(nanoseconds: 250_000_000)   // debounce typing
        if Task.isCancelled { return }
        let svc = model.service, b = branch, repos = model.state.repos.filter { !model.repoMissing($0) }
        if b.isEmpty { branchStates = [:]; return }
        let result: [UUID: BranchState] = await Task.detached {
            var out: [UUID: BranchState] = [:]
            for r in repos { out[r.id] = svc.branchState(b, in: r) }
            return out
        }.value
        if !Task.isCancelled { branchStates = result }
    }

    func field(_ label: String, text: Binding<String>, prompt: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).font(mono ? Theme.mono(12) : .system(size: 13))
        }
    }

    func pickRepo() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.prompt = "Add"
        if p.runModal() == .OK, let u = p.url {
            switch model.registerRepo(url: u) {
            case .added(let r), .existing(let r): chosen.insert(r.id); error = nil
            case .failed(let m): error = m
            }
        }
    }

    func create() {
        let sel = model.state.repos.filter { chosen.contains($0.id) }.map {
            RepoSelection(repo: $0, base: (bases[$0.id] ?? $0.defaultBranch).trimmingCharacters(in: .whitespaces))
        }
        busy = true; error = nil; progress = "Starting…"
        Task {
            let failure = await model.createWorkspace(name: name.trimmingCharacters(in: .whitespaces), branch: branch, selections: sel,
                                                      progress: { msg in Task { @MainActor in progress = msg } })
            busy = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}

struct RepoSettings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repositories").font(.system(size: 16, weight: .bold))
            Text("Nothing is copied. Each workspace adds a git worktree that shares the repository’s history and branches, so adding or removing one updates the repository’s .git.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            List {
                ForEach(model.state.repos) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.name).fontWeight(.medium)
                            Text(r.path).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if model.repoMissing(r) { Text("missing").foregroundStyle(Theme.amber).font(.system(size: 11)) }
                        Text(r.defaultBranch).font(Theme.mono(11.5)).foregroundStyle(Theme.chipFG)
                        Button("Remove") { model.removeRepo(r) }.buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 12))
                    }
                }
            }.frame(height: 200)
            HStack {
                Button("Add repository…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Add"
                    if p.runModal() == .OK, let u = p.url { model.addRepo(url: u) }
                }.buttonStyle(OutlineButton())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
    }
}
