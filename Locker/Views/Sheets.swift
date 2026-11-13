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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New workspace").font(.system(size: 16, weight: .bold))
            field("Name", text: $name, prompt: "Apple Pay")
                .onChange(of: name) { _, v in if !branchEdited { branch = WorkspaceService.slug(v).lowercased() } }
            field("Branch (same in every repo)", text: Binding(get: { branch }, set: { branch = $0; branchEdited = true }), prompt: "feature/apple-pay", mono: true)
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
                            Text("from").font(.system(size: 11)).foregroundStyle(Theme.muted)
                            TextField(r.defaultBranch, text: Binding(get: { bases[r.id] ?? r.defaultBranch }, set: { bases[r.id] = $0 }))
                                .font(Theme.mono(11.5)).frame(width: 110).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }.frame(height: 150)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButton()).keyboardShortcut(.cancelAction)
                Button(busy ? "Creating…" : "Create") { create() }.buttonStyle(PrimaryButton())
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || branch.isEmpty || chosen.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
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
            model.addRepo(url: u)
            if let r = model.state.repos.last { chosen.insert(r.id) }
        }
    }

    func create() {
        let sel = model.state.repos.filter { chosen.contains($0.id) }.map {
            RepoSelection(repo: $0, base: (bases[$0.id] ?? $0.defaultBranch).trimmingCharacters(in: .whitespaces))
        }
        busy = true
        Task {
            let ok = await model.createWorkspace(name: name.trimmingCharacters(in: .whitespaces), branch: branch, selections: sel)
            busy = false
            if ok { dismiss() }
        }
    }
}

struct RepoSettings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repositories").font(.system(size: 16, weight: .bold))
            Text("Registered repositories are never modified. Workspaces check out worktrees from them.")
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
