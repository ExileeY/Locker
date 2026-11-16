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
    @State private var adding = false
    @State private var error: String?
    @State private var progress = ""
    @State private var branchStates: [UUID: BranchState] = [:]
    @State private var selectedProject: UUID?
    @State private var baseSource: BaseSource = .origin
    @State private var originHints: [UUID: WorkspaceService.OriginHint] = [:]
    /// Ignored files each repo's original checkout has, as a lazily loaded tree (from `AppModel`'s cache when it has one).
    @State private var carryTrees: [UUID: CarryTree] = [:]
    /// Ticked carry-over paths per repo; set to the preselected entries when a repo's list first loads.
    @State private var carryPicked: [UUID: Set<String>] = [:]
    /// Expanded folders and groups per repo.
    @State private var carryOpen: [UUID: Set<String>] = [:]
    /// Repos whose list is shown rather than only its summary line.
    @State private var carryRepoOpen: Set<UUID> = []
    @State private var carryFilter: [UUID: String] = [:]
    /// Folder listings in flight, as "<repo id>/<path>".
    @State private var carryLoading: Set<String> = []
    /// The running folder-size pass per repo; `id` tells a pass that was replaced from the current one.
    @State private var carrySizers: [UUID: CarrySizer] = [:]
    @State private var rememberCarry = true
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
        .onAppear { nameFocused = true; baseSource = model.state.preferences.baseSource }
        .onDisappear { carrySizers.values.forEach { $0.task.cancel() }; carrySizers = [:] }
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
                // Selection filters: plain links, grouped together.
                HStack(spacing: 10) {
                    Button("All") { chosen = ComposerOps.setAll(chosen, shown: shown, on: true, isUsable: usable) }
                        .help(query.isEmpty ? "Select every repository" : "Select the repositories shown")
                    Text("/").foregroundStyle(Theme.muted)
                    Button("None") { chosen = ComposerOps.setAll(chosen, shown: shown, on: false) }
                        .help(query.isEmpty ? "Clear the selection" : "Clear the repositories shown")
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.chipFG)
                Rectangle().fill(Theme.line).frame(width: 1, height: 16).accessibilityHidden(true)
                // An action, not a filter: a bordered button so it doesn't read as a third toggle.
                Button { pickRepo() } label: {
                    Label { Text("Add repository…") } icon: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(OutlineButton(height: 24))
                .disabled(adding)
                .overlay(alignment: .leading) { if adding { ProgressView().controlSize(.small).offset(x: -22) } }
                .help("Links a folder on your Mac. Nothing is copied.")
            }

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
                VStack(alignment: .leading, spacing: 4) {
                    label("Start from")
                    Picker("Start from", selection: $baseSource) {
                        Text("Origin (fetch first)").tag(BaseSource.origin)
                        Text("Local branch").tag(BaseSource.local)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityIdentifier("base-source")
                    Text(baseSource == .origin
                         ? "Fetches each repo, then starts from origin/<base>. Repos without an origin use the local branch."
                         : "Starts from each repo's local branch as it is now, without fetching.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                if case .missingBase? = shownIssue, let shownIssue { issueText(shownIssue) }
                if !chosenRepos.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        label(branch.isEmpty ? "Start each repo detached at" : "Base for repos where the branch is new")
                        ForEach(chosenRepos) { r in baseRow(r) }
                    }
                    .task(id: HintKey(repos: chosenRepos.map(\.id), bases: chosenRepos.map(base(for:)))) { await refreshOriginHints() }
                }
                if chosenRepos.contains(where: { !(carryTrees[$0.id]?.isEmpty ?? true) }) { carryOverSection }
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
        // On the group, not the list, so the summary's file count is ready while Advanced is collapsed.
        .task(id: chosenRepos.map(\.id)) { await refreshCarryCandidates() }
    }

    // MARK: Local files to copy

    private var carryOverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                label("Local files to copy")
                Text("Ignored by git, so a new worktree doesn't have them. Ticked items are copied from each repo's original folder.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            ForEach(chosenRepos.filter { !(carryTrees[$0.id]?.isEmpty ?? true) }) { r in carryList(r) }
            Toggle("Remember these choices for each repo", isOn: $rememberCarry)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .accessibilityIdentifier("remember-carry-over")
        }
    }

    static let carryRowHeight: CGFloat = 26
    static let carryListMaxHeight: CGFloat = 240
    /// More top-level entries than this get a filter field.
    static let carryFilterThreshold = 15

    private func carryList(_ r: Repo) -> some View {
        let tree = carryTrees[r.id] ?? CarryTree()
        let picked = carryPicked[r.id] ?? []
        let open = carryRepoOpen.contains(r.id)
        let rows = open ? tree.visibleRows(open: carryOpen[r.id] ?? [], filter: carryFilter[r.id] ?? "") : []
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { carryRepoOpen.remove(r.id) } else { carryRepoOpen.insert(r.id) }
            } label: {
                HStack(spacing: 6) {
                    chevron(open)
                    Text(r.name).font(.system(size: 12.5, weight: .medium))
                    Text(carrySummary(tree, picked)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Local files in \(r.name)")
            .accessibilityValue(carrySummary(tree, picked))
            .accessibilityHint(open ? "Hides the list" : "Shows the list")
            if open {
                if tree.topLevelCount > Self.carryFilterThreshold {
                    Divider()
                    TextField("Filter paths", text: Binding(get: { carryFilter[r.id] ?? "" }, set: { carryFilter[r.id] = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .accessibilityLabel("Filter local files in \(r.name)")
                }
                Divider()
                if rows.isEmpty {
                    Text("No matches").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                } else {
                    // Lazy and height-capped: only the rows in view are built, however long the list.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in carryRow(r, tree, row, picked, first: row.id == rows.first?.id) }
                        }
                    }
                    .frame(height: min(CGFloat(rows.count) * Self.carryRowHeight, Self.carryListMaxHeight))
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }

    private func chevron(_ open: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            .rotationEffect(.degrees(open ? 90 : 0))
            .frame(width: 12)
    }

    private func carryRow(_ r: Repo, _ tree: CarryTree, _ row: CarryTree.Row, _ picked: Set<String>, first: Bool) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            if let n = row.node {
                if n.isDir {
                    Button { toggleCarryFolder(r, n.path) } label: { chevron(row.isOpen).frame(width: 16, height: 20).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityLabel((row.isOpen ? "Collapse " : "Expand ") + n.path)
                } else {
                    Color.clear.frame(width: 16, height: 1)
                }
                let state = tree.checkState(n.path, picked)
                Button {
                    carryPicked[r.id] = tree.toggle(n.path, picked)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                            .foregroundStyle(state == .off ? Theme.muted : Theme.accent).font(.system(size: 13))
                        Text(row.name).font(Theme.mono(11.5)).lineLimit(1).truncationMode(.middle)
                        if let tag = carryTag(n, parent: row.parent) {
                            Text(tag).font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(n.heavy && n.source == .detected ? Theme.amber : Theme.muted)
                        }
                        Spacer(minLength: 8)
                        if let size = tree.size(of: n.path) {
                            Text(Self.sizeText(size.0, capped: size.capped)).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(n.path) in \(r.name)")
                .accessibilityValue(state == .on ? "selected" : state == .mixed ? "partly selected" : "not selected")
                .accessibilityAddTraits(state == .on ? .isSelected : [])
            } else if let note = row.note {
                Color.clear.frame(width: 16, height: 1)
                switch note {
                case .loading: ProgressView().controlSize(.mini)
                case .unreadable: Text("Can't read this folder").font(.system(size: 11)).foregroundStyle(Theme.muted)
                case .empty: Text("Empty folder").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.carryRowHeight)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Theme.border).frame(height: 1) } }
    }

    /// Why a row is offered. "build output" only on the outermost build folder, not on everything inside it.
    private func carryTag(_ n: CarryTree.Node, parent: String) -> String? {
        switch n.source {
        case .remembered: return "remembered"
        case .worktreeinclude: return CarryOver.includeFile
        case .detected: return n.heavy && n.kind != .group && !CarryOver.isHeavy(parent) ? "build output" : nil
        }
    }

    private func carrySummary(_ tree: CarryTree, _ picked: Set<String>) -> String {
        guard !picked.isEmpty else { return "none selected" }
        let size = tree.pickedSize(picked).map { " · " + Self.sizeText($0.0, capped: $0.capped) } ?? ""
        return "\(picked.count) selected" + size
    }

    static func sizeText(_ size: Int64, capped: Bool) -> String {
        let s = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return capped ? s + "+" : s
    }

    /// Ticked carry-over paths across the chosen repos.
    private var carryCount: Int { chosenRepos.reduce(0) { $0 + (carryPicked[$1.id]?.count ?? 0) } }

    private var advancedSummary: String {
        let from = baseSource == .origin ? "from origin" : "from local"
        let files = carryCount == 0 ? "" : " · \(carryCount) local \(carryCount == 1 ? "file" : "files")"
        return (branch.isEmpty ? "no branch, detached at each repo's default" : "branch \(branch)") + " · " + from + files
    }

    private func base(for r: Repo) -> String {
        (bases[r.id] ?? r.defaultBranch).trimmingCharacters(in: .whitespaces)
    }

    /// The hint next to a base field: how the local branch compares with origin, from refs on disk.
    @ViewBuilder private func originHintText(_ r: Repo) -> some View {
        switch originHints[r.id] {
        case .noOrigin?:
            hint("no origin, uses local", Theme.muted)
        case .notOnOrigin?:
            hint(baseSource == .origin ? "not on origin, uses local" : "not on origin", Theme.muted)
        case .onlyOnOrigin?:
            hint("only on origin", Theme.muted)
        case .upToDate?:
            hint("up to date with origin", Theme.green)
        case .diverged(let ahead, let behind)?:
            let parts = [behind > 0 ? "\(behind) behind" : nil, ahead > 0 ? "\(ahead) ahead of" : nil].compactMap { $0 }
            // Amber when the chosen source leaves something out: stale local, or local commits origin lacks.
            let lossy = (baseSource == .local && behind > 0) || (baseSource == .origin && ahead > 0)
            hint("local is " + parts.joined(separator: ", ") + " origin", lossy ? Theme.amber : Theme.muted)
                .help(ahead > 0 && baseSource == .origin
                      ? "Local commits not on origin won't be in this workspace. Choose Local branch to include them."
                      : "Based on the last fetch.")
        case nil:
            EmptyView()
        }
    }

    private func hint(_ s: String, _ color: Color) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).lineLimit(1)
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
                originHintText(r)
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
    struct HintKey: Equatable { var repos: [UUID]; var bases: [String] }

    func refreshOriginHints() async {
        try? await Task.sleep(nanoseconds: 250_000_000)   // debounce typing
        if Task.isCancelled { return }
        let svc = model.service
        let list = chosenRepos.filter(usable).map { ($0, base(for: $0)) }
        let result: [UUID: WorkspaceService.OriginHint] = await Task.detached {
            var out: [UUID: WorkspaceService.OriginHint] = [:]
            for (r, b) in list where !b.isEmpty { out[r.id] = svc.originHint(base: b, in: r) }
            return out
        }.value
        if !Task.isCancelled { originHints = result }
    }

    struct CarrySizer { let id: UUID; let task: Task<Void, Never> }

    /// Shows the carry-over tree of each chosen repo: the cached one at once when `AppModel` has it, reloaded in the
    /// background when stale. Then loads open folders and starts sizing folders. Scans for deselected repos stop.
    @MainActor func refreshCarryCandidates() async {
        try? await Task.sleep(nanoseconds: 250_000_000)   // debounce clicking through repos
        if Task.isCancelled { return }
        let ids = Set(chosenRepos.map(\.id))
        for (id, sizer) in carrySizers where !ids.contains(id) { sizer.task.cancel(); carrySizers[id] = nil }
        for r in chosenRepos.filter(usable) {
            if Task.isCancelled { return }
            if carryTrees[r.id] == nil, let cached = model.cachedCarryTree(r) {
                setCarryTree(r, cached.tree)
                if cached.fresh { startCarryWork(r); continue }
            } else if carryTrees[r.id] != nil {
                startCarryWork(r); continue
            }
            let tree = await model.loadCarryTree(r, keepingSizesFrom: carryTrees[r.id])
            if Task.isCancelled { return }
            setCarryTree(r, tree)
            startCarryWork(r)
        }
    }

    @MainActor private func setCarryTree(_ r: Repo, _ tree: CarryTree) {
        let first = carryPicked[r.id] == nil
        carryTrees[r.id] = tree
        guard first else { return }
        carryPicked[r.id] = tree.preselected
        carryOpen[r.id] = tree.initialOpen
        if !tree.preselected.isEmpty { carryRepoOpen.insert(r.id) }
    }

    @MainActor private func updateCarryTree(_ r: Repo, _ change: (inout CarryTree) -> Void) {
        guard var tree = carryTrees[r.id] else { return }
        change(&tree)
        carryTrees[r.id] = tree
        model.updateCarryCache(r.id, tree)
    }

    @MainActor private func startCarryWork(_ r: Repo) {
        loadOpenCarryFolders(r)
        startCarrySizer(r)
    }

    @MainActor private func toggleCarryFolder(_ r: Repo, _ path: String) {
        var open = carryOpen[r.id] ?? []
        if open.remove(path) == nil { open.insert(path) }
        carryOpen[r.id] = open
        loadOpenCarryFolders(r)
    }

    /// Lists each open folder not loaded yet, one level at a time; opening a folder inside one loads it next.
    @MainActor private func loadOpenCarryFolders(_ r: Repo) {
        guard let tree = carryTrees[r.id] else { return }
        for path in tree.unloaded(in: carryOpen[r.id] ?? []) {
            let key = r.id.uuidString + "/" + path
            guard !carryLoading.contains(key) else { continue }
            carryLoading.insert(key)
            Task { @MainActor in
                let entries = await model.carryChildren(r, path)
                carryLoading.remove(key)
                updateCarryTree(r) { $0.setChildren(of: path, entries) }
                startCarryWork(r)
            }
        }
    }

    /// Sizes the repo's unsized folders, four at a time, picking up folders loaded meanwhile. Build output goes last
    /// with a lower file cap. Each result is shown as it arrives; cancelling stops the walks in progress.
    @MainActor private func startCarrySizer(_ r: Repo) {
        guard carrySizers[r.id] == nil, carryTrees[r.id]?.nextUnsized(excluding: []) != nil else { return }
        let id = UUID(), root = r.path
        let task = Task { @MainActor in
            await withTaskGroup(of: (String, (Int64, capped: Bool)?).self) { g in
                var busy: Set<String> = []
                while true {
                    while busy.count < 4, !Task.isCancelled, let job = carryTrees[r.id]?.nextUnsized(excluding: busy) {
                        busy.insert(job.path)
                        let cap = job.heavy ? CarryOver.heavyFileCap : CarryOver.fileCap
                        g.addTask { (job.path, try? CarryOver.size(of: root + "/" + job.path, fileCap: cap)) }
                    }
                    guard let (path, size) = await g.next() else { break }
                    busy.remove(path)
                    if let size, !Task.isCancelled { updateCarryTree(r) { $0.setSize(path, size.0, capped: size.capped) } }
                }
            }
            if carrySizers[r.id]?.id == id { carrySizers[r.id] = nil }
        }
        carrySizers[r.id] = CarrySizer(id: id, task: task)
    }

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
        guard !adding, let u = RepositoryPicker.pick() else { return }
        adding = true
        Task {
            defer { adding = false }
            switch await model.registerRepo(url: u) {
            case .added(let r), .existing(let r):
                if let selectedProject { model.link(r, to: selectedProject) }   // keep the new repo inside the project's grid
                chosen.insert(r.id); error = nil
                if ComposerOps.filter([r], query: query).isEmpty { query = "" }   // keep the new repo visible
            case .failed(let m): error = m
            }
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
        // A repo whose list hasn't loaded yet copies what it remembered.
        let sel = chosenRepos.map {
            RepoSelection(repo: $0, base: (bases[$0.id] ?? $0.defaultBranch).trimmingCharacters(in: .whitespaces),
                          carryOver: carryPicked[$0.id].map { $0.sorted() } ?? $0.carryOver)
        }
        busy = true; error = nil; progress = "Starting…"
        Task {
            let failure = await model.createWorkspace(name: name.trimmingCharacters(in: .whitespaces), branch: branch, selections: sel,
                                                      baseSource: baseSource, rememberCarryOver: rememberCarry, progress: { msg in Task { @MainActor in progress = msg } })
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
