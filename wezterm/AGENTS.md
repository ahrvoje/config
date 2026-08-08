# AGENTS.md

## What This Is

Personal cross-platform WezTerm configuration. `.wezterm.lua` is shared by
Windows, macOS/Darwin, MSYS2, and WSL. Per-machine files live under
`.config/wezterm/wezterm_local_*.lua` and are symlinked as
`~/.config/wezterm/wezterm_local.lua`.

## Configuration Layers

`configured_value(key)` reads a whitelisted local override and otherwise uses
`default_config`. Local keybindings are appended last so their duplicate keys
win. Keep the whitelist explicit; currently it includes display, launch,
timing, environment, and startup-size fields.

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

- `format_right_status`, `format-tab-title`, and ordinary per-keystroke
  callbacks may read only PaneInformation snapshots, user variables, and Lua
  memory. The explicit `LEADER+k`, Esc and Ctrl-D keystrokes are the only
  exceptions; the latter two call `console_repl`, because a console REPL has no
  producer and one started from the cmd prompt inherits Clink's stale user vars.
- Never call `get_foreground_process_info`, `wezterm.procinfo`, battery APIs,
  filesystem probes, mux-wide enumeration, child processes, or CLI commands
  from paint/status/key paths.
- `pane:get_current_working_dir()` is allowed only immediately after
  `cwd_ready`; OSC 7 must precede that marker so WezTerm cannot fall back to
  operating-system process inspection.
- `user-var-changed` refreshes CWD on `cwd_ready` without an explicit repaint.
  Status reads a copied snapshot committed by final `state_serial`, so
  automatic per-variable status events cannot display intermediate state.
- `update-status` compares live core fields with the committed snapshot and
  skips formatting during a producer batch. Keep `cwd_ready` changing on each
  CWD publication; a permanent `on` value cannot distinguish prompt commits.
- The logical UI clock rejects backward wall-clock changes and caps large
  forward discontinuities. Do not base elapsed time or TTLs on producer epoch
  timestamps.
- Command elapsed time starts when a new opaque `command_token` is observed.
  Status updates stay at one-second resolution; subsecond timer repaints add
  distraction without useful information.
- Tab titles require a process label to remain stable for one second before
  changing. Preserve explicit tab titles and honor `max_width` on every return,
  including cache/error fallbacks.
- Cache pruning is inactivity-based. Do not reintroduce periodic
  `mux.get_pane`/`all_windows` sweeps.

## Actions and Safety

- Ctrl-C copies a selection or sends interrupt.
- Esc clears a line at an authoritative integrated prompt or a console REPL. It
  sends a real Escape to unknown/remote panes and alternate-screen apps, Ctrl-G
  to shell-owned fzf overlays, and Win32 input records to Clink popups.
- Ctrl-D uses native terminal EOF only where the shell honours it. cmd and
  PowerShell clear the buffer and submit `exit`; `python` and `ptpython` submit
  `exit()`. Keep `repl_exits` as the single table of these special cases.
- Ctrl-L always sends the Ctrl-L key; never append a textual `clear` command to
  a possibly non-empty shell buffer.
- On Windows `LEADER+k` queries the foreground process only when pressed, runs
  asynchronous `taskkill /PID ... /T`, and escalates to `/F` after 0.5 seconds
  only if PID/start-time/executable/name still match. A returned LocalProcessInfo
  PID always goes to Windows `taskkill`; never reinterpret it as a WSL guest
  PID. Panes without local process information receive Ctrl-C. On non-Windows
  systems it sends Ctrl-C.
- LEADER+x uses WezTerm's confirmed `CloseCurrentPane`; never launch a second
  `wezterm cli` process as a fallback.
- Alt-pane paste/zoom proceeds only when the current pane is alt-screen or
  exactly one candidate exists. Refuse ambiguity, and use `send_paste` so
  bracketed-paste protection is retained.
- Deferred callbacks must wrap their bodies in `pcall` and tolerate panes or
  windows disappearing before execution.

## Platform Handling

- Preserve leading `/` on Unix paths, `/C:` handling on Windows, and UNC
  markers. OSC 7 producers percent-encode paths.
- macOS Cmd+Left/Right send logical Home/End keys so the active keyboard
  protocol chooses bytes; do not hard-code SS3 sequences.
- Startup positions without an origin use absolute active-screen bounds.
  Positions with `MainScreen`, `ActiveScreen`, or `Named` origin use coordinates
  relative to that screen. Clamp stale values before spawning.
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
