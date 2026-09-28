# M0 spike results

herdr 0.9.0 (protocol 22) on macOS 26.6.2. Answers come from a throwaway script against an isolated
session (`herdr --session herdrbar-e2e server`), which was stopped and deleted afterwards.

## Answered

| # | Question | Answer |
|---|---|---|
| S5 | Does a snapshot right after `pane.agent_status_changed` show the new status? | Yes, for every event (6 of 6). No delay needed. |
| S7 | Which event fires when an agent leaves but its pane stays (`pane.release_agent`)? | `pane_agent_detected` (agent null) and `pane.agent_status_changed` with `unknown`. The agent drops out of `snapshot.agents`. |
| S8 | Can a headless named session drive E2E tests? | Yes. It needs `HERDR_*` removed from the environment, `workspace.create {focus:false}`, `pane.report_agent` for states, and `session stop` then `session delete` for cleanup. The default session is untouched. |
| S13 (part) | Is `state_change_seq` one counter for the whole server? | Yes: 1, 2, 3, … across panes. Marking an agent seen (done → idle through `agent.focus`) does not change it. |

## Other findings

- **A finish in the server's focused workspace reports `idle`, not `done`**, even with no client
  attached. A finish in a background workspace reports `done`. This supports the S6 rule
  (working → idle while the host terminal is not frontmost counts as finished). S6 still needs a check
  with a real client and a background terminal.
- **`agent.focus` on a `done` agent** moves the server focus (`focused_workspace_id`) to it and turns it
  `idle`. This works on 0.9.0 with no client attached.
- **A stale pane id fails the whole `events.subscribe`** with `{"code":"pane_not_found"}`.
- **`client.window_title.set` with no client attached** returns `changed:false`, `reason:"no_foreground_client"`.
- **A terminal id as an agent target** fails with `agent_not_found`.
- **The first report into an empty pane** sends `pane_agent_detected` and `pane.agent_status_changed` in
  the same millisecond. The wake stream coalesces them.

## Answered with your Ghostty (herdr 0.9.0)

| # | Question | Answer |
|---|---|---|
| S1 (part) | Can the app raise the exact Ghostty window? | Yes, from a launch-time jump: ScriptingBridge on the host pid found the nonce-titled terminal, and `focus` plus `activate` returned true. The click, minimized-window, and other-Space cases are still to confirm. |
| S2 | Nonce latency | 129 ms from `window_title.set` to a focused terminal. |

| S6 | Does a finish in the visible tab report done while the terminal is in the background? | Yes, from herdr's source (`src/app/actions.rs`, `apply_pane_state_change`): a completion marks the pane seen only when `is_active_tab && outer_terminal_focus != Some(false)`, and Ghostty reports focus changes. My earlier `idle` result came from a session with no client attached, where focus is unknown. Herdrbar needs no extra rule. |

## Findings that changed the build

- **The Automation check must target Ghostty's bundle id.** `AEDeterminePermissionToAutomateTarget` with a pid target did not return "allowed" after you granted access, so the first build skipped the exact-window step. macOS stores the grant per app; with a bundle-id target the check passes.
- **`agent.focus` does not move the attached client's view on herdr 0.9.0** (herdr#3760, fixed in 0.9.1). The server logs `workspace focused`, but the screen stays put. `pane.focus {pane_id}` moves the view to the exact pane on 0.9.0 and later, and it marks a done agent as seen (checked in an isolated session). Herdrbar now uses `pane.focus`, so local jumps work on 0.9.0 and the minimum is 0.9.0. Remote machines still need 0.9.1 for `--machine`.

## Still open (need a GUI, other terminals, or your machine setup)

S1 (click, minimized, other Space), S3, S4, S9, S10, S11, S12, and S13 (notification click and `performClick`).
