# AGENTS.md

## What This Is

Personal cross-platform WezTerm configuration. `.wezterm.lua` is shared by
Windows, macOS/Darwin, MSYS2, and WSL. Per-machine files live under
`.config/wezterm/wezterm_local_*.lua` and are symlinked as
`~/.config/wezterm/wezterm_local.lua`.

## Configuration Layers

`configured(key)` reads a whitelisted local override and otherwise uses
`default_config`. Local keybindings are appended last so their duplicate keys
win. Keep the whitelist explicit; currently it includes the leader, display,
launch, timing, environment, and startup-size fields. `window_pos` merges its
local fields over the default one by one.

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
  started from the cmd prompt inherits Clink's stale user vars.
- Never call `get_foreground_process_info`, `wezterm.procinfo`, battery APIs,
  filesystem probes, `mux.all_windows` or other mux-wide enumeration, child
  processes, or CLI commands from paint/status/key paths.
- `pane:get_current_working_dir()` is allowed only once `cwd_ready` has been
  published; OSC 7 must precede that marker so WezTerm cannot fall back to
  operating-system process inspection.
- Status and tab titles show only committed state. `cwd_ready` reads the CWD
  into `next_cwd`. The final `state_serial` commit captures the user vars,
  promotes `next_cwd` and starts the command timer, for background panes too.
  A pane that has never committed shows its live vars.
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
  drift. While a timer shows, a one-shot repaint just after each whole second
  keeps the timer from skipping one; `tick_due` keeps one pending per window.
- A config reload clears Lua state, cancels pending `call_after` callbacks
  and clears the key table stack; running timers restart. Do not move them to
  `wezterm.GLOBAL`: setting a key to nil leaves a null entry behind.
- Tab titles require a process label to remain stable for one second before
  changing. WezTerm formats tab titles only when it redraws the tab bar, which
  Lua causes by changing a status string. A pending title and every commit
  call `request_tab_redraw`; when the redraw is due and the right status is
  unchanged, `paint_status` toggles an invisible trailing SGR reset.
- `format-tab-title` is a synchronous callback. It reads only
  PaneInformation and Lua memory and records redraw requests; never schedule
  timers or call GUI methods from it. Preserve explicit tab titles and honor
  `max_width` on every string return.
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
  `deactivate`. cmd and PowerShell clear the buffer and submit `exit`;
  `python` and `ptpython` submit `exit()`. Keep `repl_exits` as the single
  table of the REPL special cases.
- Ctrl-L always sends the Ctrl-L key; never append a textual `clear` command to
  a possibly non-empty shell buffer.
- On Windows `LEADER+k` queries the foreground process only when pressed, runs
  asynchronous `taskkill /PID ... /T`, and escalates to `/F` after 0.5 seconds
  only if PID/start-time/executable/name still match. A returned LocalProcessInfo
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
  markers. OSC 7 producers percent-encode paths.
- macOS Cmd+Left/Right send logical Home/End keys so the active keyboard
  protocol chooses bytes; do not hard-code SS3 sequences.
- Startup positions without an origin are clamped to the screen that
  contains them, else to the active screen, so a window can start on a
  secondary monitor. Positions with `MainScreen`, `ActiveScreen`, or `Named`
  origin use coordinates relative to that screen; a missing named screen
  falls back to `ActiveScreen`. Clamp stale values before spawning.
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
