import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var state: AppState
    @Published var selectedID: UUID?
    @Published var statuses: [UUID: GitStatus] = [:]   // keyed by WorkspaceRepo.id
    @Published var missing: Set<UUID> = []             // WorkspaceRepo ids with no worktree
    @Published var errorMessage: String?
    @Published var showNewWorkspace = false
    @Published var showRepos = false
    @Published var showProjects = false
    @Published var gitMissing = false
    @Published var sessionsVersion = 0

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
    var distinctBranches: Int { Set(state.workspaces.map(\.branch)).count }

    func save() { store.save(state) }

    func update(_ id: UUID, _ f: (inout Workspace) -> Void) {
        guard let i = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        f(&state.workspaces[i])
        save()
    }

    // MARK: Selection and sessions

    func select(_ id: UUID?) {
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

    func addRepo(url: URL) {
        let path = url.path
        let git = service.git
        guard git.isRepo(path) else { errorMessage = "“\(url.lastPathComponent)” is not a git repository."; return }
        let top = (try? git.run(["rev-parse", "--show-toplevel"], in: path))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? path
        guard !state.repos.contains(where: { $0.path == top }) else { return }
        let name = URL(fileURLWithPath: top).lastPathComponent
        guard !state.repos.contains(where: { $0.name == name }) else {
            errorMessage = "A repository named “\(name)” is already registered."; return
        }
        state.repos.append(Repo(name: name, path: top, defaultBranch: git.detectDefaultBranch(top)))
        save()
    }

    func removeRepo(_ r: Repo) {
        if state.workspaces.contains(where: { $0.repos.contains { $0.repoID == r.id } }) {
            errorMessage = "“\(r.name)” is used by a workspace. Delete that workspace first."; return
        }
        state.repos.removeAll { $0.id == r.id }
        state.removeRepoFromProjects(r.id)
        save()
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
        state.projects.removeAll { $0.id == p.id }
        save()
    }

    // MARK: Workspaces

    func createWorkspace(name: String, branch: String, selections: [RepoSelection]) async -> Bool {
        let svc = service, names = state.workspaces.map(\.name)
        let result: Result<Workspace, Error> = await Task.detached {
            Result { try svc.create(name: name, branch: branch, selections: selections, existingNames: names) }
        }.value
        switch result {
        case .success(let ws):
            state.workspaces.append(ws)
            save()
            select(ws.id)
            return true
        case .failure(let e):
            errorMessage = e.localizedDescription
            return false
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

    func createBranch(_ name: String) async -> Bool {
        guard let ws = selected else { return false }
        let svc = service
        let err: Error? = await Task.detached {
            do { try svc.createBranch(name, in: ws); return nil } catch { return error }
        }.value
        if let err { errorMessage = err.localizedDescription; return false }
        update(ws.id) { $0.branch = name }
        refresh()
        return true
    }

    func repair(_ ws: Workspace) {
        for r in service.missingWorktrees(ws, repos: state.repos) {
            guard let repo = state.repos.first(where: { $0.id == r.repoID }) else { continue }
            do { try service.git.worktreeAttach(repo: repo.path, path: r.worktreePath, branch: ws.branch) }
            catch { errorMessage = error.localizedDescription }
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
                for (k, v) in out where self.statuses[k] != v { self.statuses[k] = v }
                if self.missing != miss { self.missing = miss }
            }
        }
    }
}
