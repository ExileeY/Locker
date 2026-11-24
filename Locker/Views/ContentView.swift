import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView().navigationSplitViewColumnWidth(min: 230, ideal: 264, max: 340)
            } detail: {
                switch model.page {
                case .settings:
                    SettingsView()
                case .composer:
                    ComposerView()
                case .workspace:
                    if let ws = model.selected {
                        WorkspaceDetail(ws: ws).id(ws.id)
                    } else {
                        EmptyDetail()
                    }
                }
            }
            Footer()
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast) { model.toast = nil }
                    .padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete workspace", role: .destructive) {
                if let w = model.pendingDelete { model.deleteWorkspace(w) }
                model.pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: { Text(deleteMessage) }
        .alert("Locker", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .task {
            // Build the folder picker while idle, so the first "Add repository…" click doesn't pay for it.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            RepositoryPicker.prewarm()
        }
        .alert("Git is not installed", isPresented: $model.gitMissing) {
            Button("OK") {}
        } message: { Text("Locker needs /usr/bin/git. Install the Xcode command line tools (xcode-select --install) and relaunch.") }
    }
}

extension ContentView {
    var deleteTitle: String { "Delete “\(model.pendingDelete?.name ?? "")”?" }
    var deleteMessage: String {
        let warnings = model.pendingDeleteWarnings
        if warnings.isEmpty { return "Its worktrees and any branches Locker created are removed. Your source repositories are untouched." }
        let lines = warnings.map { w -> String in
            var p: [String] = []
            if w.dirty { p.append("uncommitted changes") }
            if w.ahead > 0 { p.append("\(w.ahead) commit\(w.ahead == 1 ? "" : "s") not on the base branch") }
            return "\(w.repoName): " + p.joined(separator: ", ")
        }
        return "Unsaved work will be lost:\n" + lines.joined(separator: "\n")
    }
}

struct EmptyDetail: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Text("No workspace selected").font(.system(size: 16, weight: .semibold))
            Text("A workspace is one task: a branch and its own worktree in every repo you choose.")
                .foregroundStyle(Theme.muted)
            Button("New workspace") { model.openComposer() }.buttonStyle(PrimaryButton())
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
        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var rowTargeted: UUID?
    @State private var endTargeted = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let all = model.state.workspaces
        let shown = all.filter { $0.matches(query) }
        VStack(alignment: .leading, spacing: 4) {
            Button { model.openComposer() } label: {
                Label("New workspace", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButton(height: 36)).padding(.bottom, 10).help("New workspace (⌘N)")

            if !all.isEmpty { searchField.padding(.bottom, 10) }

            Text(query.isEmpty ? "WORKSPACES · \(all.count)" : "WORKSPACES · \(shown.count) OF \(all.count)")
                .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.muted).padding(.horizontal, 8).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(shown) { w in row(w, canReorder: query.isEmpty, isFirst: w.id == all.first?.id, isLast: w.id == all.last?.id) }
                    if query.isEmpty, all.count > 1 { endDropZone }
                    if shown.isEmpty, !query.isEmpty {
                        Text("No workspaces match “\(query)”.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { model.openSettings() } label: {
                Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).font(.system(size: 12.5, weight: model.showSettings ? .semibold : .regular))
            .foregroundStyle(model.showSettings ? Theme.accent : Theme.chipFG)
            .padding(8).help("Projects and repositories (⌘,)")
        }
        .padding(.horizontal, 10).padding(.top, 14)
        .background(Theme.sidebar)
        .background {
            // ⌘F focuses the search field.
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("Search workspaces", text: $query).textFieldStyle(.plain).focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 12.5)).padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(searchFocused ? Theme.accent.opacity(0.6) : Theme.line))
        .help("Search by name, branch or repository (⌘F)")
    }

    /// A strip under the last row so a workspace can be dropped at the very end.
    private var endDropZone: some View {
        Color.clear.frame(height: 28)
            .overlay(alignment: .top) { if endTargeted { insertionLine } }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                model.moveWorkspace(id, before: nil)
                return true
            } isTargeted: { endTargeted = $0 }
    }

    private var insertionLine: some View {
        Capsule().fill(Theme.accent).frame(height: 3).padding(.horizontal, 4)
    }

    @ViewBuilder
    private func row(_ w: Workspace, canReorder: Bool, isFirst: Bool, isLast: Bool) -> some View {
        let selected = w.id == model.selectedID && model.page == .workspace
        let a = model.activity(of: w)
        let button = Button { model.select(w.id) } label: {
            SidebarRow(ws: w, selected: selected, activity: a)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { if rowTargeted == w.id { insertionLine.offset(y: -3) } }
        .accessibilityLabel("\(w.name), \(a.label), \(w.repos.count) \(w.repos.count == 1 ? "repo" : "repos")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Move up") { model.shiftWorkspace(w.id, by: -1) }
        .accessibilityAction(named: "Move down") { model.shiftWorkspace(w.id, by: 1) }

        Group {
            if canReorder {
                button
                    .draggable(w.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                        model.moveWorkspace(id, before: w.id)
                        return true
                    } isTargeted: { targeted in
                        if targeted { rowTargeted = w.id } else if rowTargeted == w.id { rowTargeted = nil }
                    }
            } else {
                button.help("Clear search to reorder")
            }
        }
        .contextMenu {
            if canReorder, !(isFirst && isLast) {
                Button("Move to top") { model.moveWorkspace(w.id, before: model.state.workspaces.first?.id) }
                    .disabled(isFirst)
                Button("Move up") { model.shiftWorkspace(w.id, by: -1) }.disabled(isFirst)
                Button("Move down") { model.shiftWorkspace(w.id, by: 1) }.disabled(isLast)
                Divider()
            }
            Button("Rename…") { model.select(w.id); model.renameRequest = w.id }
            Divider()
            Button("Delete workspace…", role: .destructive) { model.requestDelete(w) }
        }
    }
}

extension ClaudeActivity {
    var tint: Color {
        switch self {
        case .waiting: Theme.accent
        case .running: Theme.activityRunning
        case .none: Theme.green
        }
    }
    var rowBackground: Color {
        switch self {
        case .waiting: Theme.activityWaitingBG
        case .running: Theme.activityRunningBG
        case .none: Theme.activityIdleBG
        }
    }
    var symbol: String {
        switch self {
        case .waiting: "bell.fill"
        case .running: "circle.dotted.circle"
        case .none: "circle.fill"
        }
    }
}

/// One workspace in the sidebar. The whole row is tinted by Claude Code activity, always with a text label.
struct SidebarRow: View {
    let ws: Workspace
    let selected: Bool
    let activity: ClaudeActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(ws.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
            }
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text("\(ws.branchSummary) · \(ws.repos.count) \(ws.repos.count == 1 ? "repo" : "repos")")
                    .font(Theme.mono(11)).lineLimit(1)
            }
            .foregroundStyle(Theme.secondary)
            HStack(spacing: 5) {
                Image(systemName: activity.symbol).font(.system(size: activity == .none ? 6 : 10, weight: .semibold))
                    .foregroundStyle(activity.tint).frame(width: 10)
                Text(activity.label).font(.system(size: 11, weight: activity == .none ? .regular : .semibold))
                    .foregroundStyle(activity == .none ? Theme.muted : Theme.text)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(activity.rowBackground))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.accent : activity.tint.opacity(0.25), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 2, y: 1)
        .contentShape(Rectangle())
    }
}
