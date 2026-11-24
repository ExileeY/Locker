import SwiftUI
import AppKit

/// The one folder picker used everywhere a repository is added. The panel is created once (see `prewarm()`)
/// and reused, so a click doesn't pay NSOpenPanel's start-up cost each time.
@MainActor
enum RepositoryPicker {
    private static let panel: NSOpenPanel = {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Add"
        p.message = "Choose a git repository. Locker links the folder; nothing is copied."
        return p
    }()

    /// Creates the panel ahead of time. Call once after launch, while the app is idle.
    static func prewarm() { _ = panel }

    static func pick() -> URL? {
        let signpost = Perf.signposter.beginInterval("Open folder picker")
        // End the interval when the panel is on screen and key, not when runModal returns.
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { _ in
            Perf.signposter.endInterval("Open folder picker", signpost)
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        defer { if let token { NotificationCenter.default.removeObserver(token) } }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Full-page settings: projects on the left, the selected project's repositories on the right.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ProjectList()
                .frame(width: 210)
                .background(Theme.sidebar.opacity(0.6))
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
            Group {
                switch model.settingsSelection {
                case .project(let id):
                    if let p = model.state.projects.first(where: { $0.id == id }) { ProjectPage(project: p).id(p.id) } else { SettingsEmpty() }
                case .unassigned:
                    UnassignedPage()
                case .none:
                    SettingsEmpty()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.surface)
        // The selection is resolved in openSettings() before the first draw; here only keep it valid afterwards.
        .onAppear { DispatchQueue.main.async { model.settingsDidAppear() } }
        .onChange(of: model.state.projects) { _, _ in ensureSelection() }
    }

    private func ensureSelection() {
        let resolved = model.resolvedSettingsSelection()
        if resolved != model.settingsSelection { model.settingsSelection = resolved }
    }
}

private struct ProjectList: View {
    @EnvironmentObject var model: AppModel
    @State private var hovered: SettingsItem?
    @State private var pendingDelete: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("PROJECTS").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
                Spacer()
                Button {
                    model.settingsSelection = .project(model.addProject())
                } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .help("New project").accessibilityLabel("New project")
            }
            .padding(.horizontal, 8).padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.state.projects) { p in
                        projectRow(p)
                    }
                    if !model.unassignedRepos.isEmpty {
                        row(title: "Not in a project", subtitle: "\(model.unassignedRepos.count) repos", item: .unassigned)
                    }
                }
            }
            Spacer(minLength: 0)
            Toggle(isOn: Binding(get: { model.state.preferences.notifyOnNeedsInput }, set: { model.setNotifyOnNeedsInput($0) })) {
                Text("Notify when Claude needs input").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch).controlSize(.small)
            .padding(.horizontal, 8).padding(.bottom, 12)
            .help("Show a notification when a workspace's Claude session starts waiting for you")
        }
        .padding(.horizontal, 10).padding(.top, 14)
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { p in
            Button("Delete project", role: .destructive) { model.removeProject(p) }
        } message: { _ in Text("Its repositories stay registered and no workspace is touched. You can undo this.") }
    }

    /// A project card: the select button plus a trash button (a sibling, not nested) shown on hover or selection.
    private func projectRow(_ p: Project) -> some View {
        let item = SettingsItem.project(p.id)
        let showTrash = hovered == item || model.settingsSelection == item
        return ZStack(alignment: .trailing) {
            row(title: p.name, subtitle: "\(model.repos(in: p).count) repos", item: item, trailingInset: 28)
            Button { pendingDelete = p } label: {
                Image(systemName: "trash").font(.system(size: 11.5)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.red)
            .padding(.trailing, 6)
            .opacity(showTrash ? 1 : 0).allowsHitTesting(showTrash)
            .help("Delete project").accessibilityLabel("Delete project \(p.name)")
        }
        .onHover { inside in
            if inside { hovered = item } else if hovered == item { hovered = nil }
        }
        .contextMenu {
            Button("Delete project…", role: .destructive) { pendingDelete = p }
        }
    }

    private func row(title: String, subtitle: String, item: SettingsItem, trailingInset: CGFloat = 0) -> some View {
        let selected = model.settingsSelection == item
        return Button { model.settingsSelection = item } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .padding(10).padding(.trailing, trailingInset).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.surface : (hovered == item ? Theme.border.opacity(0.5) : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.selectedBorder : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SettingsEmpty: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Text("No projects yet").font(.system(size: 16, weight: .semibold))
            Text("A project groups the repositories you work on together. Create one, add its repositories, and start workspaces from it in one click.")
                .foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("New project") { model.settingsSelection = .project(model.addProject()) }.buttonStyle(PrimaryButton())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProjectPage: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var name: String
    @State private var error: String?
    @State private var adding = false
    @FocusState private var nameFocused: Bool

    init(project: Project) {
        self.project = project
        _name = State(initialValue: project.name)
    }

    var body: some View {
        let repos = model.repos(in: project)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project name").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    TextField("Storefront", text: $name)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        .focused($nameFocused)
                        .onSubmit { nameFocused = false; commitName() }
                        .onExitCommand { name = project.name; error = nil; nameFocused = false }
                        .onChange(of: name) { _, _ in error = nil }
                        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                }
                if let error { Banner(kind: .error, message: error) }

                HStack {
                    Text("Repositories · \(repos.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    Spacer()
                    if adding { ProgressView().controlSize(.small) }
                    Button { addRepository() } label: { Label("Add repository…", systemImage: "plus") }
                        .buttonStyle(OutlineButton()).disabled(adding)
                }
                Text("Links a folder on your Mac. Nothing is copied.").font(.system(size: 11.5)).foregroundStyle(Theme.muted)

                exactHighlightCard

                if repos.isEmpty {
                    emptyRepos
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(repos.enumerated()), id: \.element.id) { i, r in
                            if i > 0 { Divider() }
                            RepoRow(repo: r, removeTitle: "Remove from project") { model.unlink(r, from: project.id) }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { resignNameFocus() }   // clicking empty space ends editing (and saves)
        }
        .onDisappear { if name != project.name { commitName() } }
    }

    private var exactHighlightCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { project.exactHighlight }, set: { model.setExactHighlight($0, for: project.id) })) {
                Text("Exact highlighting").font(.system(size: 13, weight: .semibold))
            }
            Text("Adds Claude Code hooks to this project's workspaces (in .claude/settings.local.json) so the sidebar knows exactly when Claude needs you. Other settings in that file are kept. Applies to Claude sessions started after switching it on.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }

    private var emptyRepos: some View {
        VStack(spacing: 8) {
            Text("No repositories in this project").font(.system(size: 13, weight: .semibold))
            Text("Add a repository to get started.").foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
    }

    /// SwiftUI on macOS doesn't drop text focus on a background click, so do it explicitly.
    private func resignNameFocus() {
        guard nameFocused else { return }
        nameFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed != project.name else { return }
        if let failure = model.renameProject(project.id, to: name) { error = failure; name = project.name }
        else { error = nil }
    }

    private func addRepository() {
        guard !adding, let url = RepositoryPicker.pick() else { return }
        adding = true
        Task {
            error = await model.addRepo(url: url, to: project.id)
            adding = false
        }
    }
}

private struct UnassignedPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Not in a project").font(.system(size: 16, weight: .bold))
                Text("These repositories are registered but belong to no project. Add them to one, or remove them.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                VStack(spacing: 0) {
                    ForEach(Array(model.unassignedRepos.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider() }
                        RepoRow(repo: r, removeTitle: "Remove", projects: model.state.projects) { model.removeRepo(r) }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .padding(24)
        }
    }
}

/// One repository: name, path, an editable default branch, remembered local files, and a remove action.
private struct RepoRow: View {
    @EnvironmentObject var model: AppModel
    let repo: Repo
    let removeTitle: String
    var projects: [Project] = []
    let remove: () -> Void

    var body: some View {
        let missing = model.repoMissing(repo)
        VStack(alignment: .leading, spacing: 6) {
            mainRow(missing: missing)
            if !repo.carryOver.isEmpty { carryOverRow }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    /// The remembered git-ignored paths the composer preselects for this repo, with a way to forget them.
    private var carryOverRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Local files preselected for new workspaces:").font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text(repo.carryOver.joined(separator: ", "))
                .font(Theme.mono(11)).lineLimit(2).truncationMode(.tail)
                .help(repo.carryOver.joined(separator: "\n"))
            Spacer(minLength: 8)
            Button("Forget") { model.clearCarryOver(repo) }
                .buttonStyle(.plain).foregroundStyle(Theme.chipFG).font(.system(size: 11.5))
                .help("New workspaces stop preselecting these files. You can pick them again when creating a workspace.")
                .accessibilityLabel("Forget local files to copy for \(repo.name)")
        }
    }

    private func mainRow(missing: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).fontWeight(.medium)
                Text(repo.path).font(.system(size: 10.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if missing {
                Label("missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.amber)
                    .help("This folder no longer exists. Remove it, or restore the folder.")
            } else {
                defaultBranchMenu
            }
            if !projects.isEmpty {
                Menu("Add to project") {
                    ForEach(projects) { p in Button(p.name) { model.link(repo, to: p.id) } }
                }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
            }
            Button(removeTitle, role: .destructive, action: remove)
                .buttonStyle(.plain).foregroundStyle(Theme.red).font(.system(size: 12))
        }
    }

    private var defaultBranchMenu: some View {
        Menu {
            ForEach(model.branches(of: repo), id: \.self) { b in
                Button {
                    model.setDefaultBranch(repo, to: b)
                } label: {
                    if b == repo.defaultBranch { Label(b, systemImage: "checkmark") } else { Text(b) }
                }
            }
        } label: {
            Text("default: \(repo.defaultBranch)").font(Theme.mono(11.5))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Branch new workspaces start from. Change it any time; you can still override it per workspace.")
        .accessibilityLabel("Default branch for \(repo.name): \(repo.defaultBranch)")
    }
}
