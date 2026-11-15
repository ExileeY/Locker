import SwiftUI
import AppKit

struct NewWorkspaceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var branch = ""
    @State private var chosen: Set<UUID> = []
    @State private var bases: [UUID: String] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var progress = ""
    @State private var branchStates: [UUID: BranchState] = [:]
    @State private var projectID: UUID?
    @State private var showAllRepos = false

    var project: Project? { projectID.flatMap { id in model.state.projects.first { $0.id == id } } }

    /// With a project selected, only its member repos are listed (unless "Show all repos" is on).
    var visibleRepos: [Repo] {
        guard let project, !showAllRepos else { return model.state.repos }
        return project.members(in: model.state.repos)
    }

    var unavailableCount: Int { visibleRepos.filter { model.repoMissing($0) }.count }

    func selectProject(_ id: UUID?) {
        showAllRepos = false
        guard let p = model.state.projects.first(where: { $0.id == id }) else { return }   // "None" keeps current ticks
        chosen = p.selectableRepoIDs(in: model.state.repos) { !model.repoMissing($0) }
        error = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New workspace").font(.system(size: 16, weight: .bold))
            field("Name", text: $name, prompt: "Apple Pay")
                .onChange(of: name) { _, _ in error = nil }
            field("Branch (optional, same in every repo)", text: $branch, prompt: "Leave empty to start detached at the default branch", mono: true)
                .onChange(of: branch) { _, _ in error = nil }
                .task(id: BranchKey(branch: branch, repos: model.state.repos.map(\.id))) { await refreshBranchStates() }
            if !model.state.projects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project (optional)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    Picker("Project", selection: $projectID) {
                        Text("None, select repositories manually").tag(UUID?.none)
                        ForEach(model.state.projects) { p in Text("\(p.name) (\(p.members(in: model.state.repos).count))").tag(UUID?.some(p.id)) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .onChange(of: projectID) { _, new in selectProject(new) }
                }
            }
            HStack {
                Text(project == nil || showAllRepos ? "Repositories" : "Repositories in \(project?.name ?? "")")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                if project != nil, unavailableCount > 0, !showAllRepos {
                    Text("· \(unavailableCount) unavailable").font(.system(size: 11)).foregroundStyle(Theme.amber)
                }
                Spacer()
                if project != nil {
                    Button(showAllRepos ? "Show project repos only" : "Show all repos (\(model.state.repos.count))") { showAllRepos.toggle() }
                        .buttonStyle(.plain).foregroundStyle(Theme.chipFG).font(.system(size: 12))
                }
                Button("Add repository…") { pickRepo() }.buttonStyle(.plain).foregroundStyle(Theme.chipFG).font(.system(size: 12))
            }
            if model.state.repos.isEmpty {
                Text("Add at least one git repository.").foregroundStyle(Theme.muted)
            } else if visibleRepos.isEmpty {
                Text("This project has no repositories yet. Edit it in Projects, or choose “Show all repos”.").foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(visibleRepos) { r in
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
                            } else if branch.isEmpty {
                                Text("detached at").font(.system(size: 11)).foregroundStyle(Theme.muted)
                                TextField(r.defaultBranch, text: Binding(get: { bases[r.id] ?? r.defaultBranch }, set: { bases[r.id] = $0; error = nil }))
                                    .font(Theme.mono(11.5)).frame(width: 110).textFieldStyle(.roundedBorder)
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
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(Theme.redBG).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.red.opacity(0.5)))
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
        if chosen.isEmpty { return "Select at least one repository." }
        for r in model.state.repos where chosen.contains(r.id) {
            if branch.isEmpty || branchStates[r.id] == .new, (bases[r.id] ?? r.defaultBranch).trimmingCharacters(in: .whitespaces).isEmpty {
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
            case .added(let r), .existing(let r):
                chosen.insert(r.id); error = nil
                if let project, !project.repoIDs.contains(r.id) { showAllRepos = true }   // keep the new repo visible
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

/// Lists projects and edits them. Create and edit share one editor: name + a checklist of every registered repo.
struct ProjectSettings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    struct Draft: Equatable { var id: UUID?; var name = ""; var repoIDs: Set<UUID> = [] }
    @State private var draft: Draft?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft == nil ? "Projects" : (draft?.id == nil ? "New project" : "Edit project")).font(.system(size: 16, weight: .bold))
            if draft == nil { list } else { editor }
        }
        .padding(20).frame(width: 520)
    }

    var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A project groups repositories. Pick one when creating a workspace to select all of its repositories at once.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            if model.state.projects.isEmpty {
                Text("No projects yet.").foregroundStyle(Theme.muted).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List {
                    ForEach(model.state.projects) { p in
                        HStack {
                            Text(p.name).fontWeight(.medium)
                            Spacer()
                            Text("\(p.members(in: model.state.repos).count) repos").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                            Button("Edit") { error = nil; draft = Draft(id: p.id, name: p.name, repoIDs: Set(p.repoIDs)) }
                                .buttonStyle(.plain).foregroundStyle(Theme.chipFG).font(.system(size: 12))
                            Button("Remove") { model.removeProject(p) }.buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 12))
                        }
                    }
                }.frame(height: 200)
            }
            HStack {
                Button("New project") { error = nil; draft = Draft() }.buttonStyle(OutlineButton())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            }
        }
    }

    var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                TextField("Storefront", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0; error = nil }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Repositories in this project").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Add repository…") { pickRepo() }.buttonStyle(.plain).foregroundStyle(Theme.chipFG).font(.system(size: 12))
            }
            if model.state.repos.isEmpty {
                Text("No repositories registered yet. Use “Add repository…” to register one.").foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.state.repos) { r in
                        HStack {
                            Toggle(isOn: Binding(get: { draft?.repoIDs.contains(r.id) ?? false },
                                                 set: { if $0 { draft?.repoIDs.insert(r.id) } else { draft?.repoIDs.remove(r.id) } })) {
                                VStack(alignment: .leading) {
                                    Text(r.name).fontWeight(.medium)
                                    Text(r.path).font(.system(size: 10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                            }
                            Spacer()
                            if model.repoMissing(r) { Text("missing").font(.system(size: 11)).foregroundStyle(Theme.amber) }
                        }
                    }
                }
            }.frame(height: 180)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(Theme.redBG).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.red.opacity(0.5)))
            }
            HStack {
                Spacer()
                Button("Cancel") { error = nil; draft = nil }.buttonStyle(OutlineButton()).keyboardShortcut(.cancelAction)
                Button("Save project") { save() }.buttonStyle(PrimaryButton())
                    .disabled((draft?.name.trimmingCharacters(in: .whitespaces).isEmpty ?? true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    func pickRepo() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Add"
        if p.runModal() == .OK, let u = p.url {
            switch model.registerRepo(url: u) {
            case .added(let r), .existing(let r): draft?.repoIDs.insert(r.id); error = nil
            case .failed(let m): error = m
            }
        }
    }

    func save() {
        guard let d = draft else { return }
        // Keep the registered-repo order so the project's list is stable.
        let ids = model.state.repos.map(\.id).filter(d.repoIDs.contains)
        if let failure = model.saveProject(id: d.id, name: d.name, repoIDs: ids) { error = failure } else { error = nil; draft = nil }
    }
}
