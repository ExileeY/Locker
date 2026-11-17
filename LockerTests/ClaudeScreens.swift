import Foundation

/// Real Claude Code screens captured from a session that launched two parallel subagents (bottom of the screen only).
/// While the main agent waits for subagents the "esc to interrupt" hint is missing, which used to read as "waiting".
enum ClaudeScreens {
    static let idleStart = #"""
 ▐▛███▛█   Claude Code v2.1.326
▝▜██████▀  Haiku 5.5 · Claude Pro
 ▝▝   ▝▝   /…/work
                                                                                                              ◐ medium · /effort
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ Try "how do I log an error?"
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker · restart with CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=…
  ⏵⏵ auto mode on (shift+tab to cycle)
"""#.components(separatedBy: "\n")

    static let busyWithHint = #"""
   └ Run sleep and echo done
⏺ Both subagents are running in parallel, each doing sleep 25; echo done. I'll say "finished" once both have reported back.
✻ Waiting for 2 background agents to finish
⏺ Agent "Run sleep and echo done" is waiting on its own background work · 6s
✳ Leavening…
  ⎿  Tip: Name sessions with /rename to find them in /resume
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker · restart with CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=…
  ⏵⏵ auto mode on · 2 shells, 1 monitor · esc to interrupt · ↓ to manage
  ⏺ main
  ◯ general-purpose  waiting on 1 shell · Run sleep and echo done · since 8:02 AM
  ◯ general-purpose  Run sleep and echo done                                                                 9s · ↓ 35.6k tokens
"""#.components(separatedBy: "\n")

    static let subagentsPanelNoHint = #"""
  then reply with the single word done. Wait for both, then say finished.
⏺ 2 background agents launched (↓ to manage)
   ├ Run sleep and echo done
   └ Run sleep and echo done
⏺ Both subagents are running in parallel, each doing sleep 25; echo done. I'll say "finished" once both have reported back.
✻ Waiting for 2 background agents to finish
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker · restart with CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=…
  ⏵⏵ auto mode on · 2 shells · ↓ to manage
  ⏺ main
  ◯ general-purpose  Run sleep and echo done                                                                 5s · ↓ 32.0k tokens
  ◯ general-purpose  Run sleep and echo done                                                                 5s · ↓ 32.0k tokens
"""#.components(separatedBy: "\n")

    static let subagentsDoneTurnPanelNoHint = #"""
✻ Waiting for 1 background agent to finish
⏺ Agent "Run sleep and echo done" is waiting on its own background work · 9s
⏺ Both subagents have now reported, but neither has delivered a final result. Each says it is still waiting on background work of
  its own and will report through SubagentHandback when that finishes. So I'm still waiting and have not reached "finished." I'll
  give the final word once both reports arrive.
✻ Brewed for 15s · done 8:02 AM · 2 shells, 1 monitor still running
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ check on the subagents
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker · restart with CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=…
  ⏵⏵ auto mode on · 2 shells, 1 monitor · ↓ to manage
  ⏺ main
  ◯ general-purpose  waiting on 1 shell · Run sleep and echo done · since 8:02 AM
  ◯ general-purpose  waiting on 1 shell, 1 monitor · Run sleep and echo done · since 8:02 AM
"""#.components(separatedBy: "\n")

    static let monitorOnlyPanel = #"""
✻ Waiting for 1 background agent to finish
⏺ Agent "Run sleep and echo done" is waiting on its own background work · 9s
⏺ Both subagents have now reported, but neither has delivered a final result. Each says it is still waiting on background work of
  its own and will report through SubagentHandback when that finishes. So I'm still waiting and have not reached "finished." I'll
  give the final word once both reports arrive.
✻ Brewed for 15s · done 8:02 AM · 1 monitor still running
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ check on the subagents
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker · restart with CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=…
  ⏵⏵ auto mode on · 1 monitor · ↓ to manage
  ⏺ main
  ◯ general-purpose  Run sleep and echo done                                                                 9s · ↓ 32.6k tokens
  ◯ general-purpose  Run sleep and echo done                                                                 9s · ↓ 35.9k tokens
"""#.components(separatedBy: "\n")

    static let idleAfterSubagents = #"""
  waiting on it and won't say "finished" until it does.
✻ Waiting for 2 background agents to finish
⏺ Agent "Run sleep and echo done" finished · 31s
⏺ Agent "Run sleep and echo done" finished · 33s
› Message from @general-purpose (ctrl+o to expand)
⏺ Finished. Both subagents completed sleep 25; echo done with exit code 0. Neither replied with only the word "done": the harness
  blocked the foreground sleep, so each re-ran it in the background and reported that instead. Neither subagent changed any files
  or made commits.
✻ Worked for 3s · done 8:02 AM
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ check on the subagents
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker · restart with CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=…
  ⏵⏵ auto mode on (shift+tab to cycle)
"""#.components(separatedBy: "\n")
}
