local wezterm = require 'wezterm'
local act = wezterm.action
local cb = wezterm.action_callback
local nf = wezterm.nerdfonts
local is_windows = wezterm.target_triple:find('windows') ~= nil
local is_darwin = wezterm.target_triple:find('darwin') ~= nil
local config = wezterm.config_builder()

--------------HELPERS--------------

local function send_key(key, mods)
  return act.SendKey { key = key, mods = mods }
end

-- Call a method on a mux object and return nil instead of raising. The GUI
-- can still hold a pane or window that already left the mux.
local function try(object, method, ...)
  if object == nil then
    return nil
  end
  local ok, result = pcall(object[method], object, ...)
  return ok and result or nil
end

-- Seconds from a clock that never runs backwards. WezTerm gives Lua only
-- wall-clock time; a wall-clock correction must not make an elapsed time
-- negative.
local last_clock = 0
local function clock()
  last_clock = math.max(last_clock, tonumber(wezterm.time.now():format_utc('%s%.3f')) or 0)
  return last_clock
end

-- A table that creates an empty entry on first access, for state keyed by id.
local function autotable()
  return setmetatable({}, { __index = function(t, id) t[id] = {}; return t[id] end })
end

--------------CONFIGURATION--------------
-- Shared defaults. `wezterm_local` (one file per machine, see
-- .config/wezterm/) returns a table that overrides any of them. Two keys are
-- special: `keys` are appended to the key bindings so they win, and
-- `window_pos` places the first window (see STARTUP).

local defaults = {
  leader                 = { key = 'q', mods = 'ALT', timeout_milliseconds = 9999 },
  initial_rows           = 35,
  initial_cols           = 125,
  animation_fps          = 1,
  cursor_blink_ease_in   = 'Constant',
  cursor_blink_ease_out  = 'Constant',
  max_fps                = 60,
  scrollback_lines       = 50000,
  -- The right status changes at one-second resolution. Prompt, process and
  -- CWD transitions repaint immediately via user-var-changed.
  status_update_interval = 1000,
  window_pos             = { x = 175, y = 30 },
  -- Set per machine: font, font_size, front_end, window_frame, launch_menu,
  -- default_prog, set_environment_variables.
}

local function load_local_config()
  local ok, module = pcall(require, 'wezterm_local')
  if ok then
    assert(type(module) == 'table', 'wezterm_local must return a table')
    return module
  end
  -- A missing local module is normal; any other load failure is a config error.
  assert(tostring(module):find("module 'wezterm_local' not found", 1, true), module)
  return {}
end
local local_config = load_local_config()

for _, source in ipairs { defaults, local_config } do
  for key, value in pairs(source) do
    if key ~= 'keys' and key ~= 'window_pos' then
      config[key] = value
    end
  end
end
local window_pos = local_config.window_pos or defaults.window_pos

config.adjust_window_size_when_changing_font_size = false
config.audible_bell = 'Disabled'
config.check_for_updates = false
config.disable_default_key_bindings = true
config.inactive_pane_hsb = { hue = 1.0, saturation = 0.3, brightness = 0.4 }
config.show_close_tab_button_in_tabs = false
config.window_decorations = 'RESIZE'

-- Selection of dark themes with acceptable contrast
config.color_scheme = 'Bright (base16)'
-- config.color_scheme = 'Brogrammer'
-- config.color_scheme = 'Brogrammer (Gogh)'
-- config.color_scheme = 'Frontend Delight (Gogh)'
-- config.color_scheme = 'Gigavolt (base16)'
-- config.color_scheme = 'Gruber (base16)'
-- config.color_scheme = 'synthwave-everything'
-- config.color_scheme = 'Vs Code Dark+ (Gogh)'
-- config.color_scheme = 'Windows NT (base16)'

-- Scrollbar
-- config.enable_scroll_bar     = true
-- config.min_scroll_bar_height = '2cell'
-- config.colors                = { scrollbar_thumb = '#556666' }
-- config.window_padding        = { left = 8, right = 16, top = 4, bottom = 4 }  -- right padding is scrollbar width

if is_windows then
  -- Do not override canonicalize_pasted_newlines: WezTerm's automatic default
  -- distinguishes Windows console programs from WSL. A global CRLF setting
  -- produces blank lines in non-bracketed WSL pastes.
  -- wsl.exe strips Windows env vars from the guest unless WSLENV forwards
  -- them; forward WEZTERM_PANE so programs inside WSL can detect WezTerm.
  local env = config.set_environment_variables or {}
  local wslenv = env.WSLENV or os.getenv('WSLENV') or ''
  if not (':' .. wslenv:upper() .. ':'):find(':WEZTERM_PANE[/:]') then
    env.WSLENV = wslenv == '' and 'WEZTERM_PANE/u' or wslenv .. ':WEZTERM_PANE/u'
  end
  config.set_environment_variables = env
end

--------------PANE STATE--------------
-- Shell and application integrations publish their state as OSC 1337 user
-- vars (see ../zsh/.zshrc, ../clink/user_var.lua, ../nvim/init.lua). The GUI
-- never discovers processes itself, except on the explicit keystrokes noted
-- below.

local function is_alt_screen(pane)
  return try(pane, 'is_alt_screen_active') == true
end

-- What the integration says about a pane. `at_prompt` is true only while an
-- integrated shell owns the line editor: a running command, a remote pane and
-- a program without integration all leave it false and receive raw keys.
local function shell_context(pane)
  local vars = try(pane, 'get_user_vars') or {}
  local integrated = vars.shell_integration == 'on'
  return {
    vars = vars,
    integrated = integrated,
    at_prompt = integrated and vars.shell_prompt == 'on',
    is_cmd = vars.shell_name == 'cmd',
  }
end

-- Windows console REPLs ignore Ctrl-D and publish no user vars, and one
-- started from the cmd prompt inherits Clink's stale ones, so resolve them
-- from the foreground process. Queried only on the explicit Esc and Ctrl-D
-- keystrokes, never from paint, status or navigation; remote panes have no
-- local process info and stay pass-through.
local function console_repl(pane)
  local info = try(pane, 'get_foreground_process_info')
  local name = info and tostring(info.name):lower():match('[^/\\]+$')
  if name == 'pwsh.exe' or name == 'powershell.exe' then
    return 'powershell'
  elseif name == 'python.exe' or name == 'python3.exe' then
    local argv = info.argv or {}
    if #argv == 1 then
      return 'python'
    elseif #argv == 2 and argv[2]:lower():find('ptpython', 1, true) then
      return 'ptpython'
    end
  end
  return nil
end

--------------CONTEXT-AWARE KEY ACTIONS--------------

-- Ctrl-C interrupts when nothing is selected, otherwise copies the selection.
local function action_ctrl_c(window, pane)
  local selected = window:get_selection_text_for_pane(pane) ~= ''
  window:perform_action(selected and act.CopyTo 'ClipboardAndPrimarySelection' or send_key('c', 'CTRL'), pane)
end

-- Line-clearing sequences. cmd.exe has no Ctrl-A/Ctrl-K, so it gets keys.
local clear_cmd_line = act.Multiple { send_key('End'), send_key('Home', 'SHIFT'), send_key('Delete') }
local clear_shell_line = act.SendString '\x01\x0b'  -- Ctrl-A Ctrl-K

-- Clear the line, then submit a command, so pending input never merges into it.
local function submit(clear_line, command)
  return act.Multiple { clear_line, act.SendString(command .. '\r') }
end

-- Ctrl-D keeps native EOF semantics where the shell honours it. At an
-- integrated prompt an active Python venv is deactivated first; cmd.exe,
-- PowerShell and the Python REPLs get an explicit exit command because they
-- ignore Ctrl-D. PowerShell publishes no user vars, so it decides itself: the
-- `deactivate` function exists only while an Activate.ps1 venv is active.
local exit_cmd = submit(clear_cmd_line, 'exit')
local deactivate_venv_cmd = submit(clear_cmd_line, 'deactivate')
local deactivate_venv_shell = submit(clear_shell_line, 'deactivate')
local repl_exits = {
  powershell = submit(clear_cmd_line, 'if (Test-Path Function:deactivate) { deactivate } else { exit }'),
  python     = act.SendString 'exit()\r',
  ptpython   = act.SendString 'exit()\n',
}

local function action_exit_shell(window, pane)
  local ctx = shell_context(pane)
  local action = send_key('d', 'CTRL')
  if ctx.at_prompt and ctx.vars.venv == 'on' then
    action = ctx.is_cmd and deactivate_venv_cmd or deactivate_venv_shell
  elseif ctx.at_prompt and ctx.is_cmd then
    action = exit_cmd
  elseif not ctx.at_prompt then
    local repl = console_repl(pane)
    action = repl and repl_exits[repl] or action
  end
  window:perform_action(action, pane)
end

-- Esc clears the line at an integrated prompt or in a console REPL, and is a
-- real Escape for full-screen apps, overlays and unknown panes.
local plain_escape = send_key('Escape')
local fzf_escape = send_key('g', 'CTRL')  -- fzf's abort key, works across WSL/MSYS boundaries
-- ConPTY holds a bare \x1b as a possible escape-sequence prefix, so a
-- synthesized plain Escape never reaches console apps as VK_ESCAPE. Encode
-- the press as explicit win32-input-mode key events (CSI Vk;Sc;Uc;Kd;Cs;Rc _),
-- which ConPTY translates deterministically into VK_ESCAPE INPUT_RECORDs;
-- that is what Clink's popups listen for.
local win32_escape = act.SendString '\x1b[27;1;27;1;0;1_\x1b[27;1;27;0;0;1_'

local function action_escape(window, pane)
  local ctx = shell_context(pane)
  local action
  if window:leader_is_active() then
    action = plain_escape
  elseif ctx.vars.fzf == 'on' then
    -- The shell's fzf wrapper flags fzf ownership; inline fzf never enters
    -- the alt screen.
    action = fzf_escape
  elseif ctx.vars.clink_popup == 'on' then
    -- A Clink popup (e.g. the Rex selector) owns the pane; it must get an
    -- Escape key event, not the cmd line-clear sequence.
    action = win32_escape
  elseif is_alt_screen(pane) then
    action = plain_escape
  elseif ctx.at_prompt then
    action = ctx.is_cmd and clear_cmd_line or clear_shell_line
  else
    -- A console REPL owns its line editor but publishes nothing. Everything
    -- else, remote panes included, is pass-through; never scrape the visible
    -- line to decide what Escape means.
    local repl = console_repl(pane)
    action = repl == 'powershell' and clear_cmd_line or repl and clear_shell_line or plain_escape
  end
  window:perform_action(action, pane)
end

-- LEADER+l logs the pane's snapshot, user vars and the local config into the
-- debug overlay (F1).
local function action_log_debug_info(window, pane)
  local pane_id, pane_info = pane:pane_id(), nil
  for _, entry in ipairs(try(window:active_tab(), 'panes_with_info') or {}) do
    if entry.pane:pane_id() == pane_id then
      pane_info = entry
    end
  end
  wezterm.log_info {
    { context = 'Pane info', data = pane_info },
    { context = 'Pane user vars', data = try(pane, 'get_user_vars') },
    { context = 'Pane metadata', data = try(pane, 'get_metadata') },
    { context = 'Alt screen', data = tostring(try(pane, 'is_alt_screen_active')) },
    { context = 'Local configuration', data = local_config },
  }
end

-- Navigation keys choose per keystroke between the pane's own key and
-- scrollback navigation.
local function choose(predicate, true_action, false_action)
  return cb(function(window, pane)
    window:perform_action(predicate(pane) and true_action or false_action, pane)
  end)
end

-- Alt-screen apps, fzf, Clink popups and anything that is not an integrated
-- prompt get the real key; only an authoritative local prompt scrolls.
local function wants_raw_nav_keys(pane)
  local ctx = shell_context(pane)
  return is_alt_screen(pane) or ctx.vars.fzf == 'on' or ctx.vars.clink_popup == 'on' or not ctx.at_prompt
end

-- Home/Up/Down are line-editor keys at a prompt and in unknown/remote panes;
-- they scroll only while an integrated shell runs a command.
local function has_shell_prompt(pane)
  local ctx = shell_context(pane)
  return not ctx.integrated or ctx.at_prompt
end

--------------PROCESS TERMINATION--------------
-- LEADER+k is a Windows-only escape hatch for a wedged foreground process:
-- taskkill /T, then taskkill /F after 0.5 s if the same process is still
-- there. The synchronous process query runs only on this keystroke.
-- Everywhere else, and at an idle integrated prompt, it sends Ctrl-C.

local function taskkill(pid, force)
  local args = { 'taskkill.exe', '/PID', tostring(pid), '/T' }
  if force then
    args[#args + 1] = '/F'
  end
  wezterm.background_child_process(args)
end

local function action_kill_process(window, pane)
  local target = is_windows and not shell_context(pane).at_prompt and try(pane, 'get_foreground_process_info')
  if not target then
    window:perform_action(send_key('c', 'CTRL'), pane)
    return
  end
  taskkill(target.pid, false)
  -- Hold only the pane id across the delay: get_pane raises for a closed
  -- pane. The same PID with another start time is a reused PID.
  local pane_id = pane:pane_id()
  wezterm.time.call_after(0.5, function()
    local ok, live_pane = pcall(wezterm.mux.get_pane, pane_id)
    local info = ok and try(live_pane, 'get_foreground_process_info')
    if info and info.pid == target.pid and info.start_time == target.start_time then
      taskkill(target.pid, true)
    end
  end)
end

--------------ALT-SCREEN PANE ACTIONS--------------

-- The PaneInformation entry an alt-screen action targets: the active pane
-- when it runs an alt-screen app, otherwise the tab's only alt-screen pane.
-- Several candidates are refused; never paste into or zoom an arbitrary one.
local function alt_screen_target(tab)
  local candidates = {}
  for _, entry in ipairs(try(tab, 'panes_with_info') or {}) do
    if is_alt_screen(entry.pane) then
      if entry.is_active then
        return entry
      end
      candidates[#candidates + 1] = entry
    end
  end
  if #candidates > 1 then
    wezterm.log_warn('Refusing alt-pane action: several alt-screen panes are eligible')
  end
  return #candidates == 1 and candidates[1] or nil
end

-- Ctrl+Alt+; toggles the zoom state of the alt-screen pane.
local function action_alt_pane_toggle_zoom(window)
  local tab = window:active_tab()
  local target = alt_screen_target(tab)
  if target then
    target.pane:activate()
    tab:set_zoomed(not target.is_zoomed)
  end
end

-- Copy-mode Ctrl+Enter sends the selection to the alt-screen pane, e.g. into
-- Neovim or another full-screen TUI. send_paste keeps bracketed-paste
-- protection.
local function action_send_to_alt_pane(window, pane)
  local text = window:get_selection_text_for_pane(pane)
  local target = text ~= '' and alt_screen_target(window:active_tab())
  if target then
    target.pane:send_paste(text)
    target.pane:activate()
  end
end

--------------KEY BINDINGS--------------
-- Ctrl+Alt+9/8 push the `term`/`nvim` key tables, Ctrl+Alt+- pops one and
-- Ctrl+Alt+0 clears the stack. The right status shows the active table.

local key_table_icons = {
  term        = nf.cod_terminal,
  nvim        = nf.custom_neovim,
  copy_mode   = nf.md_content_copy,
  search_mode = nf.md_magnify,
}

config.keys = {
  { key = 'F1', action = act.ShowDebugOverlay },
  { key = 'F2', action = act.ShowLauncher },
  { key = 'F3', action = act.ShowTabNavigator },
  { key = 'F4', action = act.ActivateCommandPalette },
  { key = 'F5', action = act.CharSelect { group = 'SmileysAndEmotion' } },
  { key = 'F6', action = act.CharSelect { group = 'Objects' } },
  { key = 'F7', action = act.CharSelect { group = 'Symbols' } },
  { key = 'F8', action = act.CharSelect { group = 'UnicodeNames' } },
  { key = 'Escape',   action = cb(action_escape) },
  { key = 'PageUp',   action = choose(wants_raw_nav_keys, send_key('PageUp'), act.ScrollByPage(-0.5)) },
  { key = 'PageDown', action = choose(wants_raw_nav_keys, send_key('PageDown'), act.ScrollByPage(0.5)) },
  { key = 'Home', mods = 'CTRL', action = choose(wants_raw_nav_keys, send_key('Home', 'CTRL'), act.ScrollToTop) },
  { key = 'End',  mods = 'CTRL', action = choose(wants_raw_nav_keys, send_key('End', 'CTRL'), act.ScrollToBottom) },
  { key = 'd', mods = 'CTRL', action = cb(action_exit_shell) },
  -- Always the Ctrl-L key; never a textual `clear` into a possibly non-empty line.
  { key = 'l', mods = 'CTRL', action = send_key('l', 'CTRL') },
  { key = 'Tab', mods = 'CTRL',       action = act.ActivateTabRelative(1) },
  { key = 'Tab', mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },
  { key = 't',  mods = 'CTRL|ALT', action = act.SpawnTab 'DefaultDomain' },
  { key = 'y',  mods = 'CTRL|ALT', action = act.SpawnTab 'CurrentPaneDomain' },
  { key = '\'', mods = 'CTRL|ALT', action = act.TogglePaneZoomState },
  { key = ';',  mods = 'CTRL|ALT', action = cb(action_alt_pane_toggle_zoom) },
  { key = '9',  mods = 'CTRL|ALT', action = act.ActivateKeyTable { name = 'term', one_shot = false } },
  { key = '8',  mods = 'CTRL|ALT', action = act.ActivateKeyTable { name = 'nvim', one_shot = false } },
  { key = '-',  mods = 'CTRL|ALT', action = act.PopKeyTable },
  { key = '0',  mods = 'CTRL|ALT', action = act.ClearKeyTableStack },
  { key = 'k', mods = 'LEADER', action = cb(action_kill_process) },
  { key = 'l', mods = 'LEADER', action = cb(action_log_debug_info) },
  -- Pane destruction is explicit and confirmed; never a second CLI process.
  { key = 'x', mods = 'LEADER', action = act.CloseCurrentPane { confirm = true } },
}

-- Send clean F keys to the shell, e.g. for Midnight Commander.
for f = 1, 12 do
  table.insert(config.keys, { key = 'F' .. f, mods = 'CTRL|ALT', action = send_key('F' .. f) })
end

-- Ctrl+arrow moves between panes, Alt+arrow resizes, Ctrl+Alt+arrow splits.
for _, direction in ipairs { 'Left', 'Down', 'Up', 'Right' } do
  local key = direction .. 'Arrow'
  table.insert(config.keys, { key = key, mods = 'CTRL',     action = act.ActivatePaneDirection(direction) })
  table.insert(config.keys, { key = key, mods = 'ALT',      action = act.AdjustPaneSize { direction, 1 } })
  table.insert(config.keys, { key = key, mods = 'CTRL|ALT', action = act.SplitPane { direction = direction } })
end

if is_darwin then
  -- Ctrl+1..9 must reach the shell as character keys.
  for k = 1, 9 do
    table.insert(config.keys, { key = tostring(k), mods = 'CTRL', action = send_key(tostring(k), 'CTRL') })
  end
  -- Cmd+arrows: cursor Home/End and half-page scrolling. Logical keys let
  -- WezTerm use the active keyboard protocol instead of hard-coded SS3 bytes.
  table.insert(config.keys, { key = 'LeftArrow',  mods = 'SUPER', action = send_key('Home') })
  table.insert(config.keys, { key = 'RightArrow', mods = 'SUPER', action = send_key('End') })
  table.insert(config.keys, { key = 'UpArrow',    mods = 'SUPER', action = act.ScrollByPage(-0.5) })
  table.insert(config.keys, { key = 'DownArrow',  mods = 'SUPER', action = act.ScrollByPage(0.5) })
end

-- Local key binds go last so machine-specific overrides win.
for _, binding in ipairs(local_config.keys or {}) do
  table.insert(config.keys, binding)
end

config.key_tables = {
  term = {
    { key = 'w', mods = 'CTRL', action = act.CloseCurrentTab { confirm = true } },
    { key = 'c', mods = 'CTRL', action = cb(action_ctrl_c) },
    { key = '=', mods = 'CTRL', action = act.IncreaseFontSize },
    { key = '-', mods = 'CTRL', action = act.DecreaseFontSize },
    { key = '0', mods = 'CTRL', action = act.ResetFontSize },
    { key = 'v', mods = 'CTRL', action = act.PasteFrom 'Clipboard' },
    { key = 'x', mods = 'CTRL', action = act.ActivateCopyMode },
    { key = 's', mods = 'CTRL', action = act.Search 'CurrentSelectionOrEmptyString' },
    { key = 'Home',      action = choose(has_shell_prompt, send_key('Home'), act.ScrollToTop) },
    { key = 'UpArrow',   action = choose(has_shell_prompt, send_key('UpArrow'), act.ScrollByLine(-1)) },
    { key = 'DownArrow', action = choose(has_shell_prompt, send_key('DownArrow'), act.ScrollByLine(1)) },
  },
  nvim = {},  -- every key reaches Neovim; the base bindings still apply
}

if wezterm.gui then
  local copy_mode = wezterm.gui.default_key_tables().copy_mode
  table.insert(copy_mode, { key = 'Enter', mods = 'CTRL', action = cb(action_send_to_alt_pane) })
  config.key_tables.copy_mode = copy_mode
end

-- Ctrl+wheel scrolls line-by-line for precise viewport movement.
config.mouse_bindings = {
  { event = { Down = { streak = 1, button = { WheelUp = 1 } } },   mods = 'CTRL', action = act.ScrollByLine(-1) },
  { event = { Down = { streak = 1, button = { WheelDown = 1 } } }, mods = 'CTRL', action = act.ScrollByLine(1) },
}

--------------STATUS BAR--------------
-- Per pane, keyed by pane id:
--   vars      user vars as of the last state_serial commit
--   cwd       display path as of the last commit
--   next_cwd  display path read at the last cwd_ready, shown from the next commit
--   command   { token, started } of the running command, for the elapsed timer
--   shown, pending, since   anti-flicker state of the tab title
-- Per window, keyed by window id:
--   tick_due    when the pending timer repaint fires
--   redraw_due  when a requested tab bar redraw is due
--   toggle      invisible status suffix that forces that redraw

local pane_states = autotable()
local window_states = autotable()
local last_prune = clock()

-- Forget the panes and windows that the mux no longer has, every five
-- minutes. Inactivity is no sign of a closed pane: an unfocused split can run
-- a command for hours.
local function prune_closed()
  local now = clock()
  if now - last_prune < 300 then
    return
  end
  last_prune = now
  for id in pairs(pane_states) do
    if not pcall(wezterm.mux.get_pane, id) then
      pane_states[id] = nil
    end
  end
  for id in pairs(window_states) do
    if not pcall(wezterm.mux.get_window, id) then
      window_states[id] = nil
    end
  end
end

-- The pane's CWD from its OSC 7 state as a display path; nil if the pane is
-- gone. Called only once a producer has signalled cwd_ready: without an OSC 7
-- URL WezTerm would fall back to inspecting operating-system processes.
local function read_cwd(pane)
  local ok, url = pcall(pane.get_current_working_dir, pane)
  if not ok then
    return nil
  end
  local path = url and url.file_path or ''  -- percent-decoded, host dropped
  if is_windows then
    path = path:gsub('^/(%a:)', '%1')  -- /C:/Users -> C:/Users
    if path:sub(1, 2) == '//' then
      path = path:gsub('/', '\\')  -- //server/share -> \\server\share
    end
  end
  return path
end

-- Producers write several user vars per transition and emit state_serial
-- last. A commit captures the vars then, so the status bar and tab titles
-- never show a half-applied transition.
local function commit(pane, state, vars)
  state.vars = vars
  state.cwd = state.next_cwd or state.cwd
  if state.cwd == nil and vars.cwd_ready then
    state.cwd = read_cwd(pane) or ''  -- published before this config loaded
  end
  -- The elapsed timer starts when a commit carries a new opaque
  -- command_token, in a background pane too.
  local token = vars.command_token or ''
  if token == '' or vars.shell_prompt == 'on' then
    state.command = nil
  elseif not state.command or state.command.token ~= token then
    state.command = { token = token, started = clock() }
  end
end

local function format_elapsed(seconds)
  seconds = math.floor(seconds)
  local days = math.floor(seconds / 86400)
  return (days > 0 and days .. 'd' or '')
    .. string.format('%02d:%02d:%02d', math.floor(seconds / 3600) % 24, math.floor(seconds / 60) % 60, seconds % 60)
end

local function toggle_color(status)
  return status == 'on' and '#AF8461' or status == 'off' and '#6A946A' or '#666666'
end

local function format_right_status(window, pane, state, vars, elapsed)
  local items = {}
  local function add(color, text)
    if text ~= '' then
      items[#items + 1] = { Foreground = { Color = color } }
      items[#items + 1] = { Text = text }
    end
  end
  local icon = key_table_icons[window:active_key_table()]
  local cwd = state.cwd or ''
  add('Yellow', icon or '')
  add('#4488FF', icon and ' ' .. nf.md_arrow_expand_left .. '    ' or '')
  add('#BBBBBB', cwd ~= '' and wezterm.truncate_left(cwd, 60) .. '      ' or '')
  add('#847EAE', window:active_workspace() .. ' : ' .. (try(pane, 'get_domain_name') or '') .. '    ')
  add(toggle_color(vars.clink), nf.md_alpha_c .. ' ')
  add(toggle_color(vars.zsh), nf.md_alpha_z .. ' ')
  add(toggle_color(vars.nvim), nf.custom_neovim .. '    ')
  add('#AB696F', elapsed and format_elapsed(elapsed) .. '    ' or '')
  return wezterm.format(items)
end

local paint_status  -- defined below; timers repaint through it

-- Repaint a window's status after `delay` seconds. The timer holds only the
-- window id because the window can close first; a config reload cancels it.
local function repaint_after(delay, window_id)
  wezterm.time.call_after(delay, function()
    local ok, mux_window = pcall(wezterm.mux.get_window, window_id)
    local window = ok and try(mux_window, 'gui_window')
    local pane = window and try(window, 'active_pane')
    if pane then
      paint_status(window, pane)
    end
  end)
end

-- WezTerm starts each status tick one interval after the previous one ends,
-- so the ticks drift across the timer's seconds and would skip one now and
-- then. While a timer shows, also repaint just after its next whole second.
local function schedule_timer_tick(ws, window_id, elapsed)
  local now = clock()
  if (ws.tick_due or 0) > now then
    return  -- one pending repaint per window
  end
  local delay = 1.02 - elapsed % 1
  ws.tick_due = now + delay
  repaint_after(delay, window_id)
end

-- Paint the window's active pane from its last commit. A pane that has not
-- committed since this config loaded adopts its live vars when a producer
-- published them earlier, and shows them live otherwise. Always sets both
-- statuses: WezTerm schedules the next status tick only when a status is set.
function paint_status(window, pane)
  local state = pane_states[pane:pane_id()]
  local vars = state.vars
  if not vars then
    vars = try(pane, 'get_user_vars') or {}
    if vars.state_serial then
      commit(pane, state, vars)
    end
  end
  local window_id = window:window_id()
  local ws = window_states[window_id]
  local elapsed = state.command and clock() - state.command.started
  if elapsed then
    schedule_timer_tick(ws, window_id, elapsed)
  end
  -- WezTerm redraws the tab bar only when a status string changes. A due
  -- redraw flips an invisible suffix to force one.
  if ws.redraw_due and clock() >= ws.redraw_due then
    ws.redraw_due = nil
    ws.toggle = not ws.toggle
  end
  local right = format_right_status(window, pane, state, vars, elapsed)
  window:set_left_status(wezterm.format {
    { Foreground = { Color = window:leader_is_active() and '#FF6060' or '#000000' } },
    { Text = nf.md_lightning_bolt },
  })
  window:set_right_status(ws.toggle and right .. '\x1b[0m' or right)
end

wezterm.on('user-var-changed', function(window, pane, name)
  local state = pane_states[pane:pane_id()]
  if name == 'cwd_ready' then
    state.next_cwd = read_cwd(pane) or state.next_cwd
  elseif name == 'state_serial' then
    local vars = try(pane, 'get_user_vars')
    if vars then
      commit(pane, state, vars)
    end
    -- The event fires for any pane in the window, but only the active one
    -- owns the status. A commit in any pane can change its tab title.
    window_states[window:window_id()].redraw_due = 0
    local active = try(window, 'active_pane')
    if active then
      paint_status(window, active)
    end
  end
end)

wezterm.on('update-status', function(window, pane)
  paint_status(window, pane)
  prune_closed()
end)

--------------TAB TITLES--------------
-- Tab titles use the PaneInformation snapshot and Lua memory only; they never
-- resolve a mux pane or query the operating system.

local process_icons = {
  nvim       = { nf.custom_neovim,    'Neovim' },
  bash       = { nf.md_bash,          'bash' },
  gitbash    = { nf.dev_git,          'git bash' },
  powershell = { nf.seti_powershell,  'PS5' },
  pwsh       = { nf.seti_powershell,  'PS7' },
  python     = { nf.seti_python,      'Python' },
  python3    = { nf.seti_python,      'Python' },
  ptpython   = { nf.seti_python,      'PtPy' },
  cmd        = { nf.cod_terminal,     'Cmd' },
  julia      = { nf.seti_julia,       'Julia' },
  wslhost    = { nf.linux_tux,        'WSL' },
  nu         = { nf.md_chevron_right, 'Nu' },
  zsh        = { nf.md_percent,       'zsh' },
}

-- 'C:\Tools\Python.EXE' -> 'python'; nil when empty.
local function process_label(label)
  label = (label or ''):match('([^/\\]*)[/\\]*$'):lower():gsub('%.exe$', '')
  return label ~= '' and label or nil
end

local function display_process_name(vars, pane_title)
  if vars.nvim == 'on' then
    return 'nvim'
  end
  return process_label(vars.process_name) or process_label(vars.shell_name) or process_label(pane_title) or 'terminal'
end

-- Flicker guard: a new name must persist for a second before it replaces the
-- shown one, so a short-lived command (git, ls, a build step) never flips the
-- title. A pending name requests the tab bar redraw that will show it.
local function settled_name(state, name, ws)
  if state.shown == nil or name == state.shown then
    state.shown, state.pending = name, nil
  elseif name ~= state.pending then
    state.pending, state.since = name, clock()
  elseif clock() >= state.since + 1 then
    state.shown, state.pending = name, nil
  end
  if state.pending then
    ws.redraw_due = math.min(ws.redraw_due or math.huge, state.since + 1)
  end
  return state.shown
end

wezterm.on('format-tab-title', function(tab, _, _, _, _, max_width)
  if tab.tab_title ~= '' then
    return wezterm.truncate_right(tab.tab_title, max_width)
  end
  local info = tab.active_pane
  if not info then
    return nil
  end
  local state = pane_states[info.pane_id]
  local name = display_process_name(state.vars or info.user_vars, info.title)
  name = settled_name(state, name, window_states[tab.window_id])
  local icon = process_icons[name] or { '>', name }
  local prefix = info.title:find('^Copy mode:') and 'Copy mode: ' or ''
  return wezterm.truncate_right(prefix .. icon[1] .. ' ' .. icon[2] .. ' : ' .. info.pane_id, max_width)
end)

--------------STARTUP--------------
-- Position the first window from the configuration unless WezTerm already
-- got explicit startup args.

-- Keep a configured position visible: clamp it into the screen that contains
-- it, so a window can start on a secondary monitor, or into the active screen
-- when a stale value points off the desktop.
local function visible_position(pos)
  local ok, screens = pcall(wezterm.gui.screens)
  if not ok then
    return pos
  end
  local screen = screens.active or screens.main
  for _, candidate in pairs(screens.by_name) do
    if pos.x >= candidate.x and pos.x < candidate.x + candidate.width
        and pos.y >= candidate.y and pos.y < candidate.y + candidate.height then
      screen = candidate
    end
  end
  local margin = 80  -- at least this much of the window stays on screen
  return {
    x = math.min(math.max(pos.x, screen.x), screen.x + screen.width - margin),
    y = math.min(math.max(pos.y, screen.y), screen.y + screen.height - margin),
  }
end

wezterm.on('gui-startup', function(cmd)
  cmd = cmd or {}
  cmd.position = cmd.position or visible_position(window_pos)
  local _, _, mux_window = wezterm.mux.spawn_window(cmd)
  -- Two early repaints let the GUI and the shell integration settle.
  repaint_after(0.10, mux_window:window_id())
  repaint_after(0.40, mux_window:window_id())
end)

return config

----------------------------------------------------------------------------
-- debugging goodies
--
-- get gui window, active pane, active pane title:
--
--     > wezterm['mux']['all_windows']()[1]:gui_window():active_pane():get_title()
