import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView().navigationSplitViewColumnWidth(min: 230, ideal: 264, max: 340)
            } detail: {
                if let ws = model.selected {
                    WorkspaceDetail(ws: ws).id(ws.id)
                } else {
                    EmptyDetail()
                }
            }
            Footer()
        }
        .sheet(isPresented: $model.showNewWorkspace) { NewWorkspaceSheet() }
        .sheet(isPresented: $model.showRepos) { RepoSettings() }
        .sheet(isPresented: $model.showProjects) { ProjectSettings() }
        .alert("Locker", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Git is not installed", isPresented: $model.gitMissing) {
            Button("OK") {}
        } message: { Text("Locker needs /usr/bin/git. Install the Xcode command line tools (xcode-select --install) and relaunch.") }
    }
}

struct EmptyDetail: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Text("No workspace selected").font(.system(size: 16, weight: .semibold))
            Text("A workspace is one task: a branch and its own worktree in every repo you choose.")
                .foregroundStyle(Theme.muted)
            Button("New workspace") { model.showNewWorkspace = true }.buttonStyle(PrimaryButton())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Footer: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let n = model.state.workspaces.count, b = model.distinctBranches
        HStack {
            Text("\(n) \(n == 1 ? "workspace" : "workspaces") · \(b) \(b == 1 ? "branch" : "branches") checked out at once")
            Spacer()
            Text("\(model.totalTerminals) terminals open across workspaces")
        }
        .font(.system(size: 11.5)).foregroundStyle(Color(hex: 0x55554F))
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingDelete: Workspace?
    @State private var warnings: [DeleteWarning] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { model.showNewWorkspace = true } label: {
                Label("New workspace", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButton(height: 36)).padding(.bottom, 12)

            Text("WORKSPACES · \(model.state.workspaces.count)")
                .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.muted).padding(.horizontal, 8).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.state.workspaces) { w in
                        SidebarRow(ws: w, selected: w.id == model.selectedID)
                            .onTapGesture { model.select(w.id) }
                            .contextMenu {
                                Button("Delete workspace…", role: .destructive) {
                                    warnings = model.deleteWarnings(w)
                                    pendingDelete = w
                                }
                            }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button("Repositories…") { model.showRepos = true }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(Theme.chipFG).padding(8)
                Button("Projects…") { model.showProjects = true }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(Theme.chipFG).padding(8)
            }
        }
        .padding(.horizontal, 10).padding(.top, 14)
        .background(Theme.sidebar)
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete workspace", role: .destructive) {
                if let w = pendingDelete { model.deleteWorkspace(w) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text(deleteMessage) }
    }

    var deleteTitle: String { "Delete “\(pendingDelete?.name ?? "")”?" }
    var deleteMessage: String {
        if warnings.isEmpty { return "Its worktrees and branch are removed. Your source repositories are untouched." }
        let lines = warnings.map { w -> String in
            var p: [String] = []
            if w.dirty { p.append("uncommitted changes") }
            if w.ahead > 0 { p.append("\(w.ahead) commit\(w.ahead == 1 ? "" : "s") not on the base branch") }
            return "\(w.repoName): " + p.joined(separator: ", ")
        }
        return "Unsaved work will be lost:\n" + lines.joined(separator: "\n")
    }
}

struct SidebarRow: View {
    let ws: Workspace
    let selected: Bool
    var body: some View {
        let n = ws.terminals.count
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(n > 0 ? Theme.green : Color(hex: 0x9A9A94)).frame(width: 8, height: 8)
                Text(ws.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(n) \(n == 1 ? "terminal" : "terminals")").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text("\(ws.branch) · \(ws.repos.count) \(ws.repos.count == 1 ? "repo" : "repos")")
                    .font(Theme.mono(11)).lineLimit(1)
            }
            .foregroundStyle(Color(hex: 0x55554F)).padding(.leading, 16)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.white : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color(hex: 0xD6D6D1) : .clear))
        .shadow(color: .black.opacity(selected ? 0.07 : 0), radius: 2, y: 1)
        .contentShape(Rectangle())
    }
}
