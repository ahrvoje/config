# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Personal WezTerm terminal emulator configuration in Lua. The main config is `.wezterm.lua` (placed at `~/.wezterm.lua`), with per-machine local overrides in `.config/wezterm/wezterm_local_*.lua` (symlinked as `~/.config/wezterm/wezterm_local.lua` on each machine).

## Architecture

**Two-layer config system:**
- `.wezterm.lua` — shared config: keybindings, shell detection, status bar, tab titles, actions. This is the main file and where most logic lives.
- `.config/wezterm/wezterm_local_<machine>.lua` — per-machine overrides (font, font_size, front_end, window_frame, launch_menu, default_prog, window_pos, extra keys). Loaded via `prequire 'wezterm_local'`, which silently returns `{}` if the file is missing and warns on any other load error.

`configured_value(key)` resolves each whitelisted key from local config, falling back to `default_config`. Local keybindings (`local_config.keys`) are appended to the shared key list last, so machine-specific binds win.

**Shell detection heuristics** (`get_shell`, `get_pane_shell`): Since WezTerm has no native idle-shell detection, the config identifies the active shell (cmd, bash, gitbash, msys, pwsh, zsh, python, ptpython, julia, etc.) by inspecting `process_name`, `fullname`, and `argv` from `get_foreground_process_info`. Many keybinding actions branch on this (Esc line-clear, Ctrl-D exit, Ctrl-L clear screen).

**Key table stack system**: `config.key_tables` defines named key layers (`term`, `nvim`). `term` is activated via Ctrl+Alt+9 and `nvim` via Ctrl+Alt+8; Ctrl+Alt+- pops one layer and Ctrl+Alt+0 clears the whole stack. The `term` table remaps terminal-oriented keys (Ctrl+C/V/X/S, Ctrl+W close-tab, Ctrl+=/-/0 font size, Home/Up/Down). The `nvim` table is empty — activating it only pushes an indicator icon. A per-window icon stack (`key_icons_by_window`) tracks the active layers and renders them in the right status bar.

**Context-aware key actions**: Most keys use `wezterm.action_callback` to inspect pane state (alt screen active, shell type, selection, line content) before deciding behavior. For example:
- `Ctrl-C` copies if a selection exists, else sends interrupt
- `Esc` clears the line in shells, sends a real terminal Escape (or Ctrl-G for fzf) in apps, and sends a plain Escape when leader is active or no process is running
- `Home/Up/Down` (term layer) **send the key in shell mode and scroll in full-screen-app mode**; `Ctrl-Home/End` and `PageUp/Down` do the opposite — send to alt-screen apps, scroll in the shell
- `Ctrl-D` sends the appropriate exit command per shell type
- `Ctrl-L` clears the screen (`clear` for PowerShell, Ctrl-L otherwise)

**Status bar** (`update-status` event): Left status shows a leader-active lightning indicator. Right status shows, in order: active key-table icons, CWD, `workspace : domain`, clink/zsh/nvim user-var indicators (color-coded on/off/unknown), process running time (blue = shell/idle/alt-screen, red = active foreground process), battery, and pane start time. The `update-status`, `user-var-changed`, and `window-focus-changed` events all route through `refresh_window_status`.

**Process-info cache** — `format_right_status` and `format-tab-title` read process state through `get_process_name_fullname_cwd_pid_time_argv`, backed by `process_info_cache[pane_id]` with a 1-second TTL:

1. **Cache hit** (< 1 s old) returns immediately — no foreground-process query.
2. **Cache miss** queries `get_foreground_process_info` synchronously, then caches the result.
3. **Query failure** returns the last-known value (any age) so status and tab title hold steady instead of blanking for a tick.

Running-time text (`format_elapsed_time`) is recomputed every render as `os.time() - cached process_time`, so the elapsed timer keeps ticking even while the rest of the process info is served from cache.

**Tab title** (`format-tab-title` → `get_tab_title_text`): prefers the cheap `pane.foreground_process_name` property, falling back to the process-info cache. A flicker guard (`settle_tab_title_name`, `tab_title_settle`) requires a new process name to persist `tab_title_settle_seconds` (1 s) before it replaces the shown title, so a short-lived command (git, ls, a sub-second build step) never flips the tab. It is timer-free and self-correcting on each redraw. Formatted text is memoized in `tab_title_cache[pane_id]`; on error or a transient empty name, the last good title is held.

**Interactive vs. display reads:** Interactive actions (`action_kill_process`, `action_exit_shell`, `action_Esc`, `action_clear_screen`) call `get_pane_process_context`, which queries fresh first and only then falls back to cache — they need current data, not a possibly-1-s-stale value. Display paths (status, tab title) use the cached `get_process_name_*` reader instead.

**Invariants — do not break:**
- Display paths must go through the 1-second-TTL cache (`get_process_name_fullname_cwd_pid_time_argv`). Don't add uncached `get_foreground_process_info` / `pane:get_current_working_dir()` calls that run on every paint.
- On a failed process query, return the last-known value rather than `nil`/blank — both status and tab title deliberately hold the last good value. Don't "fix" this to clear it.
- `user-var-changed` only repaints; it deliberately does **not** nil `process_info_cache`. Clink fires user-vars on every prompt begin and submit, so nilling would force a synchronous query twice per prompt — the 1 s TTL refreshes it instead.
- Every deferred `wezterm.time.call_after` callback (kill-process follow-up, kill-pane follow-up, overlay refresh, startup refresh) must wrap its body in `pcall`; an unguarded failure inside a callback is silent and easy to miss.
- Interactive actions must keep using the fresh `get_pane_process_context` path; don't switch them to the cached reader.

## Platform Handling

- Process start time is normalized to the Unix epoch in `normalize_process_start_time`, which accepts Windows FILETIME (100 ns ticks since 1601), Unix milliseconds, or Unix seconds, and rejects implausible values (before 2000-01-01 or in the future).
- Process kill (`background_kill_process`): WSL panes use `wsl.exe -d <distro> -- kill [-9] <pid>`; Windows uses `taskkill /PID <pid> /T [/F]` (tree kill); Unix uses `kill`/`kill -9`. `action_kill_process` sends a graceful signal, then escalates to force-kill after 0.5 s only if the same PID/start-time/name is still running.
- `action_kill_pane` closes the pane, then hard-kills via the resolved `wezterm cli kill-pane` if it survives 0.2 s. `get_wezterm_cli_executable` resolves the CLI binary across native installs, macOS app bundles, and Linux AppImages.
- Startup window position comes from local config `window_pos`, clamped to the active screen bounds (`clamp_window_position`, `get_active_screen_bounds`) so a stale saved position can't place the window off-screen.
- macOS gets extra keybindings for Cmd+arrows (line home/end, half-page scroll) and Ctrl+1-9 passthrough.
- Path normalization (`normalize_path`) strips the `file://` URI scheme, percent-decodes, and fixes a leading `/C:` on Windows paths.

## Testing

No automated tests. To validate changes, reload WezTerm config (it auto-reloads on save) and use `F1` (ShowDebugOverlay) or `LEADER+l` (`action_log_debug_info`, which dumps process / pane / user-var / local-config info into the debug overlay).

Lua 5.2 compiler for syntax-checking is available at
`%USERPROFILE%\AppData\Local\Programs\lua-5.2\luac52.exe`
