# Locker

Per-task workspaces for multi-repo work on macOS. A workspace is a task: one branch name, one git worktree per repo under `~/Locker/<workspace>/<repo>`, and its own terminals.

    brew install xcodegen
    xcodegen generate
    xcodebuild -scheme Locker -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation test
    open Locker.xcodeproj   # then Run (first build: trust the SwiftTerm build plugin)

State lives in `~/Library/Application Support/Locker/state.json`.
