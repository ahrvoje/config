# AGENTS.md

## What This Is

Personal cross-platform WezTerm configuration. `.wezterm.lua` is shared by
Windows, macOS/Darwin, MSYS2, and WSL. Per-machine files live under
`.config/wezterm/wezterm_local_*.lua` and are symlinked as
`~/.config/wezterm/wezterm_local.lua`.

## Configuration Layers

`defaults` holds the shared settings; every key of the `wezterm_local` table
overrides them, except two. `keys` are appended last so their duplicate keys
win, and `window_pos` (`x`, `y`) places the first window. A missing local
module is normal; a local module that fails to load or does not return a
table is a configuration error, shown by WezTerm.

On Windows, merge `WEZTERM_PANE/u` into `WSLENV` without discarding configured
environment variables or duplicating an existing case-insensitive entry.
Do not globally force CRLF paste canonicalization: WezTerm's adaptive default
must distinguish ConPTY programs from WSL.

## Pane-State Protocol

The GUI must not discover processes. Shell/application integrations publish
OSC 1337 user variables instead:

- `shell_integration`: `on` only when the producer owns authoritative state.
- `shell_name`: stable shell identity (`cmd`, `zsh`, ...).
- `shell_prompt`: `on` only while the line editor owns the prompt.
- `process_name`: best-effort, display-only command/application label.
- `command_token`: opaque identity for the current command; never a timestamp.
- `cwd_ready`: changing serial emitted after OSC 7 updates terminal CWD state.
- `state_serial`: emitted last to commit a coherent repaint.
- `venv`: `on` while a Python virtual environment is active.
- `clink`, `zsh`, `nvim`, `fzf`, `clink_popup`: integration/UI ownership flags.

Current producers are `../zsh/.zshrc`, `../clink/user_var.lua`,
`../nvim/init.lua`, and `../clink/rex/rex.lua`. Their prompt hooks use only
in-process encoding and batched terminal writes; never add `base64`, `pwd`,
`ps`, shell-command substitutions, or other child processes to these hooks.
When running through tmux, double the inner ESC byte in every DCS passthrough.

`process_name` is presentation metadata, not an authorization or process-ID
contract. Never use a user variable for destructive targeting. Unknown,
remote, or non-integrated panes must receive raw keys rather than guessed
shell behavior.

## Hot-Path Invariants

- Status, tab-title and ordinary per-keystroke paths use only user variables,
  PaneInformation, Lua memory and cheap GUI or mux accessors. The explicit
  `LEADER+k`, Esc and Ctrl-D keystrokes are the only exceptions; the latter
  two call `console_repl`, because a console REPL has no producer and one
  started from the cmd prompt inherits Clink's stale user vars. `console_repl`
  queries the process on Windows only; elsewhere the REPLs handle both keys.
- Never call `get_foreground_process_info`, `wezterm.procinfo`, battery APIs,
  filesystem probes, `mux.all_windows` or other mux-wide enumeration, child
  processes, or CLI commands from paint/status/key paths.
- `pane:get_current_working_dir()` is allowed only once `cwd_ready` has been
  published; OSC 7 must precede that marker so WezTerm cannot fall back to
  operating-system process inspection.
- Status and tab titles show only committed state. `cwd_ready` reads the CWD
  into `next_cwd`. The final `state_serial` commit captures the user vars,
  promotes `next_cwd` and starts the command timer, for background panes too.
  A pane whose producer published before this config loaded commits its live
  vars on its first paint and reads the CWD then; a pane without a producer
  shows its live vars.
- `user-var-changed` fires for every pane in the window, not only the active
  one. A commit repaints the window's active pane and requests a tab bar
  redraw; it never paints the committing pane into the status.
- `paint_status` always sets both statuses. WezTerm schedules the next
  `update-status` tick only when a status is set, so an early return or an
  error stops the ticks.
- The logical UI clock rejects backward wall-clock changes. Do not base
  elapsed time or tab-title timing on producer epoch timestamps.
- Command elapsed time starts when a commit carries a new opaque
  `command_token`. `status_update_interval` stays at 1000 ms, but WezTerm
  starts each tick one interval after the previous one ends, so the ticks
  drift. While a timer shows, one loop per window (`run_timer`) requests a
  status just after each whole second and sleeps in between. Never schedule
  a `call_after` per second: WezTerm keeps every such callback until the
  config reloads (270 bytes each, measured).
- Timers never paint. They call `request_status`, which asks WezTerm to emit
  `update-status`; WezTerm runs the event in the current Lua state and merges
  it with the status ticks.
- A config reload clears Lua state, cancels pending `call_after` callbacks
  and clears the key table stack; running timers restart. A timer loop from
  before the reload ends by itself: its requests run in the new Lua state
  and count no ticks in the old one. Do not move state to `wezterm.GLOBAL`:
  setting a key to nil leaves a null entry behind.
- Do not register `format-tab-title`. WezTerm calls it twice per tab on every
  tab bar update and converts the whole config to Lua for each call (0.4 ms);
  one shell prompt causes about fifteen updates. `format-window-title` runs
  once per update with the same snapshot. It sets the tab titles with
  `tab:set_title()` and returns nothing, so WezTerm keeps its own window
  title. `show_tab_index_in_tab_bar` is off because the titles are complete.
- `format-window-title` is a synchronous callback. It reads only the snapshot
  and Lua memory and may not call asynchronous window methods. An automatic
  title ends with ` : <pane id>`; any other non-empty title is explicit and
  stays.
- Tab titles require a process label to remain stable for one second before
  changing. WezTerm runs the tab bar handler only when it updates the tab
  bar, which Lua causes by changing a status string. A pending title and
  every commit set the window's `redraw_due`; when it is due, `paint_status`
  toggles an invisible trailing SGR reset.
- WezTerm has no event for a change of the active pane. The tab bar handler
  requests a status when the active pane id of a window changes.
- The right status shows the icon of `window:active_key_table()`. There is
  no shadow copy of the key table stack to keep in sync.
- Every five minutes `prune_closed` drops the state of panes and windows that
  `mux.get_pane`/`mux.get_window` no longer resolve. Never prune by
  inactivity: an unfocused split can run a command for hours.

## Actions and Safety

- Ctrl-C copies a selection or sends interrupt.
- Esc clears a line at an authoritative integrated prompt or a console REPL. It
  sends a real Escape to unknown/remote panes and alternate-screen apps, Ctrl-G
  to shell-owned fzf overlays, and Win32 input records to Clink popups.
- Ctrl-D uses native terminal EOF only where the shell honours it. At an
  integrated prompt with `venv=on` it clears the line and submits
  `deactivate`. cmd clears the buffer and submits `exit`. PowerShell clears
  the buffer and submits `deactivate` if that function exists, else `exit`.
  `python` and `ptpython` submit `exit()`. Keep `repl_exits` as the single
  table of the REPL special cases.
- Ctrl-L always sends the Ctrl-L key; never append a textual `clear` command to
  a possibly non-empty shell buffer.
- On Windows `LEADER+k` queries the foreground process only when pressed, runs
  asynchronous `taskkill /PID ... /T`, and escalates to `/F` after 0.5 seconds
  only if PID and start time still match. A returned LocalProcessInfo
  PID always goes to Windows `taskkill`; never reinterpret it as a WSL guest
  PID. An idle integrated shell and panes without local process information
  receive Ctrl-C. On non-Windows systems it sends Ctrl-C.
- LEADER+x uses WezTerm's confirmed `CloseCurrentPane`; never launch a second
  `wezterm cli` process as a fallback.
- Alt-pane paste/zoom proceeds only when the current pane is alt-screen or
  exactly one candidate exists. Refuse ambiguity, and use `send_paste` so
  bracketed-paste protection is retained.
- Deferred callbacks hold only ids, never pane or window objects, and resolve
  them with `pcall(wezterm.mux.get_pane, id)` or `get_window`: both raise for
  a closed id.

## Platform Handling

- Preserve leading `/` on Unix paths, `/C:` handling on Windows, and UNC
  markers. OSC 7 producers percent-encode paths; WezTerm's `Url.file_path`
  returns them decoded, without the host, as `/C:/...` on Windows.
- macOS Cmd+Left/Right send logical Home/End keys so the active keyboard
  protocol chooses bytes; do not hard-code SS3 sequences.
- The startup position is clamped into the screen that contains it, else
  into the active screen, so a window can start on a secondary monitor and a
  stale value stays visible. `window_pos` has no origin field; coordinates
  are absolute.
- Startup status refreshes at 0.10 and 0.40 seconds deliberately allow the GUI
  and shell to settle; they are not polling loops.

## Validation

Run all of these after changes:

```powershell
$luac = "$env:USERPROFILE\AppData\Local\Programs\lua-5.2\luac52.exe"
& $luac -p wezterm/.wezterm.lua
& $luac -p clink/user_var.lua
& $luac -p nvim/init.lua
& C:\msys64\usr\bin\zsh.exe -n zsh/.zshrc
wezterm --config-file wezterm/.wezterm.lua show-keys --lua
nvim --headless -u nvim/init.lua +qa
git diff --check
```

Use F1 for WezTerm's debug overlay or LEADER+l for pane snapshot, user-var,
metadata, alt-screen, and local-config diagnostics.
