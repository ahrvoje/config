# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Personal WezTerm terminal emulator configuration in Lua. The main config is `.wezterm.lua` (placed at `~/.wezterm.lua`), with per-machine local overrides in `.config/wezterm/wezterm_local_*.lua` (symlinked as `~/.config/wezterm/wezterm_local.lua` on each machine).

## Architecture

**Two-layer config system:**
- `.wezterm.lua` — shared config: keybindings, shell detection, status bar, tab titles, actions. This is the main file and where most logic lives.
- `.config/wezterm/wezterm_local_<machine>.lua` — per-machine overrides (font, font_size, window_pos, launch_menu, default_prog, extra keys). Loaded via `prequire 'wezterm_local'` which silently returns `{}` if the file is missing.

Local config values override defaults; local keybindings are appended to the shared key list.

**Shell detection heuristics** (`get_shell`, `get_pane_shell`): Since WezTerm has no native idle-shell detection, the config identifies the active shell (cmd, bash, pwsh, zsh, python, etc.) by inspecting `process_name`, `fullname`, and `argv` from `get_foreground_process_info`. Many keybinding actions branch on this (Esc line-clear, Ctrl-D exit, Ctrl-L clear screen).

**Key table stack system**: `config.key_tables` defines named key layers (`term`, `nvim`) activated via Ctrl+Alt+8/9 and deactivated via Ctrl+Alt+-/0. The `term` table remaps Ctrl+C/V/X/S and scroll keys for terminal-oriented use. Icons track active layers in the status bar.

**Context-aware key actions**: Most keys use `wezterm.action_callback` to inspect pane state (alt screen active, shell type, selection, line content) before deciding behavior. For example:
- `Ctrl-C` copies if selection exists, else sends interrupt
- `Esc` clears line content in shells, sends escape in apps, cancels leader
- `Home/Up/Down` scroll in shell mode, send keys in app mode
- `Ctrl-D` sends appropriate exit command per shell type

**Status bar** (`update-status` event): Left status shows leader-active indicator. Right status shows: active key table icons, CWD, workspace/domain, clink/zsh/nvim user-var indicators (color-coded on/off), process running time (blue=idle, red=active), battery, and pane start time (cached in `wezterm.GLOBAL`).

## Platform Handling

- Windows process time conversion from FILETIME to Unix epoch in `to_unix_time`
- Windows process kill uses `taskkill /T` (tree kill); Unix uses `kill`/`kill -9`
- macOS gets extra keybindings for Cmd+arrows and Ctrl+1-9 passthrough
- Path normalization strips `file:///` URI scheme and percent-decoding for Windows paths

## Testing

No automated tests. To validate changes, reload WezTerm config (it auto-reloads on save) and use `F1` (ShowDebugOverlay) or `LEADER+l` to log debug info.
