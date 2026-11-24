# Locker

Per-task workspaces for multi-repo work on macOS. A workspace is a task: one git worktree per repo under `~/Locker/<workspace>/<repo>`, and its own terminals.

    brew install xcodegen
    xcodegen generate
    xcodebuild -scheme Locker -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation test
    open Locker.xcodeproj   # then Run (first build: trust the SwiftTerm build plugin)

State lives in `~/Library/Application Support/Locker/state.json`.

Repositories are never copied or cloned: a workspace adds a `git worktree` that shares the original repo's history and branches. Moving or deleting an original repo breaks its worktrees. 
**Start from** (under Advanced) picks where repos start. **Origin** (the default) fetches each repo first and starts from `origin/<base>`. Fetching only updates remote-tracking refs, never your local branches. If a fetch fails, Locker uses the last fetched `origin/<base>` and warns, and it only refuses when that ref was never fetched. Repos without an `origin`, and bases that only exist locally, use the local branch. **Local** starts from the local branch as it is. Each base field shows how the local branch compares with the last fetch. New branches never track the base they were created from. The last choice is remembered.

By default a workspace starts **detached at each repo's default branch** (no branch is claimed, so any number of workspaces can start from `main`). Switch or create a branch per repo from its chip in the workspace header; only that workspace changes. Switching away from a detached HEAD with unbranched commits asks first. Optionally give a branch name when creating: if it already exists in a repo it is checked out as is (and never deleted by Locker); otherwise it is created from the chosen base. Branches Locker created are deleted with the workspace only if they carry no commits beyond the base.

**Projects** group repositories (a repo can be in several projects). Create them from the sidebar's "Projects…" link or ⇧⌘P: name the project, tick its repos, or register a new repo from the editor. When creating a workspace, choosing a project lists and selects only that project's repos; "Show all repos" widens the list and "None" goes back to picking by hand. A project is only a selection shortcut: workspaces do not remember it, and removing a project or a repo never touches workspaces. State written by schema 3 builds is not read back by older builds, which would drop projects on their next save.

**Local files to copy** (under Advanced) lists what git ignores in each chosen repo's original folder, such as `.claude/settings.local.json`, `.mcp.json` or `.env.local`. A worktree only has tracked files, so ticked items are copied in when the workspace is created (APFS clones, so even large folders cost almost nothing; symlinks stay links). Nothing that already exists in the worktree is overwritten, and a failed copy never undoes the workspace: it is listed in a warning instead. Build output and dependency folders (`node_modules/`, `build/`, `DerivedData/`…) are hidden behind "Show more" and never preselected. A repo can preselect entries for everyone by committing a `.worktreeinclude` file (gitignore syntax, the same convention Claude Code uses). "Remember these choices" saves each repo's ticks for next time; Settings shows them and can forget them. State written by this version (schema 4) is not read back by older builds, which would drop the remembered choices on their next save.

**Sidebar highlight.** A workspace row turns yellow while Claude Code works (including while it waits for subagents) and blue when it needs you. Locker reads the terminal screen for this, and waits a few seconds before showing "needs your input" for an empty prompt so a redraw can't flash it. **Exact highlighting** (Settings, per project) is optional: it adds Claude Code hooks to that project's workspaces, in each workspace folder's and worktree's `.claude/settings.local.json`, so Locker is told exactly when Claude finishes or asks something. Other settings in the file are kept, and switching it off removes only Locker's entries. Hooks apply to Claude sessions started after switching it on, and do nothing outside Locker terminals.

**Notifications.** When a workspace goes from working to "needs your input", Locker posts a macOS notification; clicking it opens that workspace. It stays quiet if you are already looking at that workspace, and for sessions that start at an idle prompt. Turn it off with the "Notify when Claude needs input" switch at the bottom of Settings.
