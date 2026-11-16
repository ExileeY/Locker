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

**Projects** group repositories (a repo can be in several projects). Create them from the sidebar's "Projects…" link or ⇧⌘P: name the project, tick its repos, or register a new repo from the editor. When creating a workspace, choosing a project lists and selects only that project's repos; "Show all repos" widens the list and "None" goes back to picking by hand. A project is only a selection shortcut: workspaces do not remember it, and removing a project or a repo never touches workspaces. State written by this version (schema 3) is not read back by older builds, which would drop projects on their next save.
