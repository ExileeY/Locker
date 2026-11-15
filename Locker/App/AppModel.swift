import SwiftUI

enum SettingsItem: Hashable { case none, project(UUID), unassigned }

@MainActor
final class AppModel: ObservableObject {
    @Published var state: AppState
    @Published var selectedID: UUID?
    @Published var statuses: [UUID: GitStatus] = [:]   // keyed by WorkspaceRepo.id
    @Published var missing: Set<UUID> = []             // WorkspaceRepo ids with no worktree
    @Published var errorMessage: String?
    @Published var showNewWorkspace = false
    @Published var showSettings = false
    @Published var settingsSelection: SettingsItem = .none
    var pendingProjectID: UUID?   // project to preselect when the New Workspace sheet opens
    @Published var gitMissing = false
    @Published var sessionsVersion = 0
    @Published var toast: ToastMessage?
    private var toastTask: Task<Void, Never>?

    let store: Store
    let service: WorkspaceService
    let sessions = SessionRegistry()
    private var timer: Timer?

    init(store: Store = Store(), service: WorkspaceService = WorkspaceService()) {
        self.store = store
        self.service = service
        self.state = store.load()
        self.selectedID = state.workspaces.first?.id
        gitMissing = !service.git.isInstalled
        sessions.onExit = { [weak self] id in self?.closeTerminal(id) }
        select(selectedID)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var selected: Workspace? { state.workspaces.first { $0.id == selectedID } }
    var totalTerminals: Int { state.workspaces.reduce(0) { $0 + $1.terminals.count } }
    var distinctBranches: Int { Set(state.workspaces.flatMap { $0.repos.compactMap(\.lastBranch) }).count }

    func save() { store.save(state) }

    /// Shows a transient confirmation. Pass `undo` to offer an Undo button.
    func showToast(_ text: String, kind: FeedbackKind = .success, undoTitle: String? = nil, undo: (() -> Void)? = nil) {
        toastTask?.cancel()
        toast = ToastMessage(kind: kind, text: text, undoTitle: undoTitle, undo: undo)
        let shownID = toast?.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (undo == nil ? 3 : 6) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.toast?.id == shownID { self?.toast = nil }
        }
    }

    func update(_ id: UUID, _ f: (inout Workspace) -> Void) {
        guard let i = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        f(&state.workspaces[i])
        save()
    }

    // MARK: Selection and sessions

    func select(_ id: UUID?) {
        if id != nil { showSettings = false }
        selectedID = id
        guard let ws = selected else { return }
        for t in ws.terminals { _ = sessions.host(for: t) }   // spawn so background processes run
        sessionsVersion += 1
        refresh()
    }

    func selectIndex(_ i: Int) {
        if state.workspaces.indices.contains(i) { select(state.workspaces[i].id) }
    }

    func addTerminal() {
        guard let ws = selected else { return }
        let n = ws.terminals.filter { $0.repoLabel == nil }.count
        let spec = TerminalSpec(title: n == 0 ? "zsh" : "zsh \(n + 1)", cwd: ws.root, repoLabel: nil)
        update(ws.id) { $0.terminals.append(spec); $0.activeTerminal = spec.id }
        _ = sessions.host(for: spec)
        sessionsVersion += 1
    }

    func activate(_ tid: UUID) {
        guard let ws = selected else { return }
        update(ws.id) { $0.activeTerminal = tid }
    }

    func closeTerminal(_ tid: UUID) {
        guard let ws = state.workspaces.first(where: { $0.terminals.contains { $0.id == tid } }) else { return }
        sessions.close(tid)
        update(ws.id) { w in
            w.terminals.removeAll { $0.id == tid }
            if w.activeTerminal == tid { w.activeTerminal = w.terminals.first?.id }
        }
        sessionsVersion += 1
    }

    // MARK: Repos

    enum AddRepoResult { case added(Repo), existing(Repo), failed(String) }

    /// Registers a repo. Failures are returned (so a sheet can show them inline) and not shown as the global alert.
    func registerRepo(url: URL) -> AddRepoResult {
        let path = url.path
        let git = service.git
        guard git.isRepo(path) else { return .failed("“\(url.lastPathComponent)” is not a git repository.") }
        let top = (try? git.run(["rev-parse", "--show-toplevel"], in: path))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? path
        if let r = state.repos.first(where: { $0.path == top }) { return .existing(r) }
        let name = URL(fileURLWithPath: top).lastPathComponent
        guard !state.repos.contains(where: { $0.name == name }) else {
            return .failed("A repository named “\(name)” is already registered.")
        }
        let repo = Repo(name: name, path: top, defaultBranch: git.detectDefaultBranch(top))
        state.repos.append(repo)
        save()
        return .added(repo)
    }

    func addRepo(url: URL) {
        if case .failed(let m) = registerRepo(url: url) { errorMessage = m }
    }

    func removeRepo(_ r: Repo) {
        if state.workspaces.contains(where: { $0.repos.contains { $0.repoID == r.id } }) {
            errorMessage = "“\(r.name)” is used by a workspace. Delete that workspace first."; return
        }
        guard let index = state.repos.firstIndex(where: { $0.id == r.id }) else { return }
        let memberships = state.projects.filter { $0.repoIDs.contains(r.id) }.map(\.id)
        state.repos.remove(at: index)
        state.removeRepoFromProjects(r.id)
        save()
        showToast("Removed “\(r.name)”", undoTitle: "Undo") { [weak self] in
            guard let self else { return }
            self.state.repos.insert(r, at: min(index, self.state.repos.count))
            for i in self.state.projects.indices where memberships.contains(self.state.projects[i].id) {
                self.state.projects[i].repoIDs.append(r.id)
            }
            self.save()
        }
    }

    func repos(in project: Project) -> [Repo] { project.members(in: state.repos) }

    var unassignedRepos: [Repo] { state.unassignedRepos }

    /// Registers the folder (if new) and links it to the project in one step. Returns an error message, or nil.
    func addRepo(url: URL, to projectID: UUID) -> String? {
        switch registerRepo(url: url) {
        case .failed(let m): return m
        case .added(let r), .existing(let r):
            guard let project = state.projects.first(where: { $0.id == projectID }) else { return nil }
            guard state.link(r.id, to: projectID) else { return "“\(r.name)” is already in this project." }
            save()
            showToast("Added “\(r.name)” to \(project.name)")
            return nil
        }
    }

    /// Links an already registered repo to a project.
    func link(_ r: Repo, to projectID: UUID) {
        if state.link(r.id, to: projectID) { save() }
    }

    /// Takes a repo out of one project. The repo stays registered.
    func unlink(_ r: Repo, from projectID: UUID) {
        guard let pos = state.unlink(r.id, from: projectID) else { return }
        save()
        let projectName = state.projects.first { $0.id == projectID }?.name ?? "project"
        showToast("Removed “\(r.name)” from \(projectName)", undoTitle: "Undo") { [weak self] in
            self?.state.relink(r.id, to: projectID, at: pos)
            self?.save()
        }
    }

    /// Branches a repo can use as its default: local first, then remote-only.
    func branches(of r: Repo) -> [String] {
        let list = service.git.listBranches(r.path)
        var all = list.local + list.remoteOnly
        if !all.contains(r.defaultBranch) { all.insert(r.defaultBranch, at: 0) }
        return all
    }

    func setDefaultBranch(_ r: Repo, to branch: String) {
        if state.setDefaultBranch(r.id, to: branch) { save() }
    }

    func repoMissing(_ r: Repo) -> Bool { !FileManager.default.fileExists(atPath: r.path) }

    // MARK: Projects

    /// Returns nil on success, or the error text to show in the editor. `id` nil creates a project, otherwise edits it.
    func saveProject(id: UUID?, name: String, repoIDs: [UUID]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Enter a project name." }
        if state.projects.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "A project named “\(trimmed)” already exists."
        }
        let valid = Set(state.repos.map(\.id))
        let ids = repoIDs.filter(valid.contains)
        if let id, let i = state.projects.firstIndex(where: { $0.id == id }) {
            state.projects[i].name = trimmed
            state.projects[i].repoIDs = ids
        } else {
            state.projects.append(Project(name: trimmed, repoIDs: ids))
        }
        save()
        return nil
    }

    /// Removing a project never touches its repos or any workspace.
    func removeProject(_ p: Project) {
        guard let index = state.projects.firstIndex(where: { $0.id == p.id }) else { return }
        state.projects.remove(at: index)
        save()
        if settingsSelection == .project(p.id) { settingsSelection = .none }
        showToast("Removed project “\(p.name)”", undoTitle: "Undo") { [weak self] in
            guard let self else { return }
            self.state.projects.insert(p, at: min(index, self.state.projects.count))
            self.save()
        }
    }

    /// Creates an empty project with a unique placeholder name and returns its id.
    @discardableResult
    func addProject() -> UUID {
        let name = state.newProjectName()
        let p = Project(name: name)
        state.projects.append(p)
        save()
        return p.id
    }

    func renameProject(_ id: UUID, to name: String) -> String? {
        guard let p = state.projects.first(where: { $0.id == id }) else { return nil }
        return saveProject(id: id, name: name, repoIDs: p.repoIDs)
    }

    // MARK: Workspaces

    /// Returns nil on success, or the error text to show in the sheet.
    func createWorkspace(name: String, branch: String, selections: [RepoSelection],
                         progress: @escaping @Sendable (String) -> Void = { _ in }) async -> String? {
        let svc = service, names = state.workspaces.map(\.name)
        let result: Result<Workspace, Error> = await Task.detached {
            Result { try svc.create(name: name, branch: branch, selections: selections, existingNames: names, progress: progress) }
        }.value
        switch result {
        case .success(let ws):
            state.workspaces.append(ws)
            save()
            select(ws.id)
            return nil
        case .failure(let e):
            return e.localizedDescription
        }
    }

    func deleteWarnings(_ ws: Workspace) -> [DeleteWarning] { service.deleteWarnings(ws) }

    func deleteWorkspace(_ ws: Workspace) {
        for t in ws.terminals { sessions.close(t.id) }
        service.delete(ws, repos: state.repos)
        state.workspaces.removeAll { $0.id == ws.id }
        save()
        if selectedID == ws.id { select(state.workspaces.first?.id) }
    }

    private func updateRepo(_ ws: UUID, _ repo: UUID, _ f: (inout WorkspaceRepo) -> Void) {
        update(ws) { w in
            if let i = w.repos.firstIndex(where: { $0.id == repo }) { f(&w.repos[i]) }
        }
    }

    func branchChoices(_ r: WorkspaceRepo) async -> [WorkspaceService.BranchChoice] {
        let svc = service
        return await Task.detached { svc.branchChoices(for: r) }.value
    }

    func unbranchedCommits(_ r: WorkspaceRepo) async -> Int {
        let svc = service
        return await Task.detached { svc.unbranchedCommits(r) }.value
    }

    /// Runs a per-repo git change off the main actor; reports the error and returns false on failure.
    private func perform(_ ws: Workspace, _ r: WorkspaceRepo, _ work: @escaping @Sendable (WorkspaceService) throws -> Void) async -> Bool {
        let svc = service
        let err: Error? = await Task.detached {
            do { try work(svc); return nil } catch { return error }
        }.value
        if let err { errorMessage = err.localizedDescription; return false }
        refresh()
        return true
    }

    func switchBranch(_ ws: Workspace, _ r: WorkspaceRepo, to choice: WorkspaceService.BranchChoice) async -> Bool {
        await perform(ws, r) { try $0.switchBranch(choice, in: r) }
    }

    func detach(_ ws: Workspace, _ r: WorkspaceRepo) async -> Bool {
        let base = r.baseBranch
        return await perform(ws, r) { try $0.detach(r, at: base) }
    }

    func createBranch(_ name: String, in ws: Workspace, _ r: WorkspaceRepo) async -> Bool {
        guard await perform(ws, r, { try $0.createBranch(name, in: r) }) else { return false }
        updateRepo(ws.id, r.id) { $0.ownedBranches.append(name); $0.lastBranch = name }
        return true
    }

    func repair(_ ws: Workspace) {
        for r in service.missingWorktrees(ws, repos: state.repos) {
            guard let repo = state.repos.first(where: { $0.id == r.repoID }) else { continue }
            do {
                let g = service.git
                if let b = r.lastBranch, g.branchExists(b, in: repo.path), g.checkedOutBranches(repo: repo.path)[b] == nil {
                    try g.worktreeAttach(repo: repo.path, path: r.worktreePath, branch: b)
                } else {
                    try g.worktreeAttachDetached(repo: repo.path, path: r.worktreePath, base: r.baseBranch)
                    updateRepo(ws.id, r.id) { $0.lastBranch = nil }
                }
            } catch { errorMessage = error.localizedDescription }
        }
        select(ws.id)
    }

    // MARK: Status

    func refresh() {
        guard let ws = selected else { return }
        let svc = service, repos = state.repos
        Task.detached {
            let miss = Set(svc.missingWorktrees(ws, repos: repos).map(\.id))
            var out: [UUID: GitStatus] = [:]
            for r in ws.repos where !miss.contains(r.id) {
                if let s = try? svc.git.status(r.worktreePath) { out[r.id] = s }
            }
            await MainActor.run {
                for r in ws.repos {
                    guard let st = out[r.id] else { continue }
                    let b: String? = st.detached ? nil : st.branch
                    if r.lastBranch != b { self.updateRepo(ws.id, r.id) { $0.lastBranch = b } }
                }
                for (k, v) in out where self.statuses[k] != v { self.statuses[k] = v }
                if self.missing != miss { self.missing = miss }
            }
        }
    }
}
