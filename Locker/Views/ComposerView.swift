import SwiftUI
import AppKit

/// Inline new-workspace composer shown in the detail pane: name, a single-select project picker that narrows
/// the searchable repo grid to that project, and a collapsed Advanced section for the branch name and per-repo bases.
struct ComposerView: View {
    @EnvironmentObject var model: AppModel

    @State private var name = ""
    @State private var branch = ""
    @State private var chosen: Set<UUID> = []
    @State private var bases: [UUID: String] = [:]
    @State private var query = ""
    @State private var showAdvanced = false
    @State private var busy = false
    @State private var error: String?
    @State private var progress = ""
    @State private var branchStates: [UUID: BranchState] = [:]
    @State private var selectedProject: UUID?
    /// Set by a Create click that failed validation; from then on issues are shown in red next to their fields.
    @State private var showIssues = false
    @FocusState private var nameFocused: Bool

    private var repos: [Repo] { model.state.repos }
    private var visible: [Repo] { ComposerOps.visibleRepos(project: selectedProject, projects: model.state.projects, repos: repos) }
    private var shown: [Repo] { ComposerOps.filter(visible, query: query) }
    private var chosenRepos: [Repo] { visible.filter { chosen.contains($0.id) } }
    private var issue: ComposerIssue? {
        ComposerOps.validate(name: name, chosen: chosenRepos, branch: branch, branchStates: branchStates, bases: bases)
    }
    /// The issue to show inline, only after the user tried to create.
    private var shownIssue: ComposerIssue? { showIssues ? issue : nil }
    private func usable(_ r: Repo) -> Bool { !model.repoMissing(r) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("New workspace").font(.system(size: 18, weight: .bold))
                    nameField
                    if !model.state.projects.isEmpty { projectChips }
                    repoSection
                    advanced
                    if let error { Banner(kind: .error, message: error).accessibilityIdentifier("create-error") }
                }
                .padding(24).frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .background(Theme.surface)
        .onAppear { nameFocused = true }
        .onChange(of: chosen) { _, _ in error = nil }
    }

    // MARK: Sections

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            label("Name")
            TextField("Apple Pay", text: $name)
                .textFieldStyle(.roundedBorder).font(.system(size: 13)).frame(maxWidth: 360)
                .focused($nameFocused)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(shownIssue == .missingName ? Theme.red : .clear, lineWidth: 1.5))
                .onChange(of: name) { _, _ in error = nil }
                .accessibilityIdentifier("workspace-name")
            if shownIssue == .missingName { issueText(.missingName) }
        }
    }

    private var projectChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Project")
            FlowLayout(spacing: 6) {
                ForEach(model.state.projects) { p in
                    let on = selectedProject == p.id
                    let count = p.members(in: repos).count
                    Button { selectProject(on ? nil : p.id) } label: {
                        HStack(spacing: 5) {
                            if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                            Text(p.name).fontWeight(.medium)
                            Text("\(count)").foregroundStyle(on ? Theme.chipFG.opacity(0.8) : Theme.muted)
                        }
                        .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(on ? Theme.chipBG : Theme.surface))
                        .overlay(Capsule().stroke(on ? Theme.chipFG.opacity(0.5) : Theme.line))
                        .foregroundStyle(on ? Theme.chipFG : Theme.text)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(count == 0)
                    .help(on ? "Show every repository" : "Show only \(p.name)'s repositories")
                    .accessibilityLabel("\(p.name), \(count) repositories")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    /// Narrows the grid to one project (or every repo for nil) and ticks that project's usable repos.
    private func selectProject(_ id: UUID?) {
        selectedProject = id
        chosen = ComposerOps.selection(for: id, projects: model.state.projects, repos: repos, isUsable: usable)
        query = ""
        error = nil
    }

    private var repoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                label("Repositories · \(chosenRepos.count) of \(visible.count) selected")
                Spacer()
                Button("All") { chosen = ComposerOps.setAll(chosen, shown: shown, on: true, isUsable: usable) }
                    .help(query.isEmpty ? "Select every repository" : "Select the repositories shown")
                Text("/").foregroundStyle(Theme.muted)
                Button("None") { chosen = ComposerOps.setAll(chosen, shown: shown, on: false) }
                    .help(query.isEmpty ? "Clear the selection" : "Clear the repositories shown")
                Button { pickRepo() } label: { Label("Add repository…", systemImage: "plus") }
                    .help("Links a folder on your Mac. Nothing is copied.")
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.chipFG)

            if shownIssue == .noRepos { issueText(.noRepos) }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Filter by name or path", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel("Clear filter")
                }
            }
            .font(.system(size: 12.5)).padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.chrome))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))

            if visible.isEmpty {
                Text(selectedProject == nil ? "No repositories yet. Add one to get started." : "This project has no repositories. Add one to get started.").foregroundStyle(Theme.muted).font(.system(size: 12.5))
            } else if shown.isEmpty {
                Text("No repositories match “\(query)”.").foregroundStyle(Theme.muted).font(.system(size: 12.5))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], spacing: 8) {
                    ForEach(shown) { r in repoCard(r) }
                }
            }
        }
    }

    private func repoCard(_ r: Repo) -> some View {
        let missing = model.repoMissing(r)
        let on = chosen.contains(r.id)
        return Button {
            if on { chosen.remove(r.id) } else { chosen.insert(r.id) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Theme.accent : Theme.muted).font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(r.path).font(.system(size: 10.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    if missing {
                        Label("missing", systemImage: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.chipBG : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.chipFG.opacity(0.45) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(missing).opacity(missing ? 0.6 : 1)
        .help(missing ? "This folder no longer exists. Fix it in Settings." : r.path)
        .accessibilityLabel(r.name + (missing ? ", missing" : ""))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    label("Branch (optional, same in every repo)")
                    TextField("Leave empty to start detached at each repo's base", text: $branch)
                        .textFieldStyle(.roundedBorder).font(Theme.mono(12)).frame(maxWidth: 420)
                        .onChange(of: branch) { _, _ in error = nil }
                        .task(id: BranchKey(branch: branch, repos: visible.map(\.id))) { await refreshBranchStates() }
                }
                if case .missingBase? = shownIssue, let shownIssue { issueText(shownIssue) }
                if !chosenRepos.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        label(branch.isEmpty ? "Start each repo detached at" : "Base for repos where the branch is new")
                        ForEach(chosenRepos) { r in baseRow(r) }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text("Advanced").font(.system(size: 12.5, weight: .semibold))
                Text(advancedSummary).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showAdvanced.toggle() } }
        }
    }

    private var advancedSummary: String {
        branch.isEmpty ? "no branch, detached at each repo's default" : "branch \(branch)"
    }

    private func baseRow(_ r: Repo) -> some View {
        HStack(spacing: 8) {
            Text(r.name).font(.system(size: 12.5, weight: .medium)).frame(width: 140, alignment: .leading).lineLimit(1)
            if !branch.isEmpty, branchStates[r.id] == .existing || branchStates[r.id] == .remote {
                Text(branchStates[r.id] == .existing ? "uses existing branch" : "from origin")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.green)
            } else {
                if !branch.isEmpty, branchStates[r.id] == .new {
                    Text("new, from").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.chipFG)
                }
                TextField(r.defaultBranch, text: Binding(get: { bases[r.id] ?? r.defaultBranch }, set: { bases[r.id] = $0; error = nil }))
                    .font(Theme.mono(11.5)).frame(width: 160).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Base branch for \(r.name)")
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small)
                Text(progress).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            } else if let issue {
                if showIssues {
                    Label(issue.message, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.red)
                        .accessibilityIdentifier("create-issue")
                } else {
                    Text(issue.message).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Button("Cancel") { model.closePage() }.buttonStyle(OutlineButton()).keyboardShortcut(.cancelAction).disabled(busy)
            Button(createTitle) { create() }.buttonStyle(PrimaryButton())
                .disabled(busy)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var createTitle: String {
        if busy { return "Creating…" }
        let n = chosenRepos.count
        return n == 0 ? "Create workspace" : "Create workspace (\(n) \(n == 1 ? "repo" : "repos"))"
    }

    private func issueText(_ issue: ComposerIssue) -> some View {
        Label(issue.message, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 11.5)).foregroundStyle(Theme.red)
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
    }

    // MARK: Logic (unchanged from the old sheet)

    struct BranchKey: Equatable { var branch: String; var repos: [UUID] }

    func refreshBranchStates() async {
        try? await Task.sleep(nanoseconds: 250_000_000)   // debounce typing
        if Task.isCancelled { return }
        let svc = model.service, b = branch, list = visible.filter(usable)
        if b.isEmpty { branchStates = [:]; return }
        let result: [UUID: BranchState] = await Task.detached {
            var out: [UUID: BranchState] = [:]
            for r in list { out[r.id] = svc.branchState(b, in: r) }
            return out
        }.value
        if !Task.isCancelled { branchStates = result }
    }

    func pickRepo() {
        guard let u = pickRepositoryFolder() else { return }
        switch model.registerRepo(url: u) {
        case .added(let r), .existing(let r):
            if let selectedProject { model.link(r, to: selectedProject) }   // keep the new repo inside the project's grid
            chosen.insert(r.id); error = nil
            if ComposerOps.filter([r], query: query).isEmpty { query = "" }   // keep the new repo visible
        case .failed(let m): error = m
        }
    }

    func create() {
        if let issue {
            showIssues = true
            switch issue {
            case .missingName: nameFocused = true
            case .noRepos: break
            case .missingBase: withAnimation(.easeOut(duration: 0.15)) { showAdvanced = true }
            }
            return
        }
        let sel = chosenRepos.map {
            RepoSelection(repo: $0, base: (bases[$0.id] ?? $0.defaultBranch).trimmingCharacters(in: .whitespaces))
        }
        busy = true; error = nil; progress = "Starting…"
        Task {
            let failure = await model.createWorkspace(name: name.trimmingCharacters(in: .whitespaces), branch: branch, selections: sel,
                                                      progress: { msg in Task { @MainActor in progress = msg } })
            busy = false
            if let failure { error = failure } else { showIssues = false }   // success: createWorkspace selects the new workspace and leaves this page
        }
    }
}

/// Wraps children onto new lines when they run out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let w = rows.map(\.width).max() ?? 0
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? s.width : s.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append(i)
            rows[rows.count - 1].width += s.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, s.height)
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
