local wezterm = require 'wezterm'
local act = wezterm.action
local cb = wezterm.action_callback
local nf = wezterm.nerdfonts
local is_windows = wezterm.target_triple:match('windows') ~= nil
local config = wezterm.config_builder()

--------------HELPERS--------------

local function send_key(key, mods)
  return act.SendKey { key = key, mods = mods or 'NONE' }
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
-- wall-clock time; a wall-clock correction must not make an elapsed time or
-- a cache age negative.
local last_clock = 0
local function clock()
  local ok, now = pcall(function()
    return tonumber(wezterm.time.now():format_utc('%s%.3f'))
  end)
  if ok and now and now > last_clock then
    last_clock = now
  end
  return last_clock
end

-- For warnings raised from paint paths, which repeat every second.
local warned_at = {}
local function warn_rate_limited(key, message)
  local now = clock()
  if warned_at[key] and now - warned_at[key] < 60 then
    return
  end
  warned_at[key] = now
  wezterm.log_warn(message)
end

--------------DEFAULT AND LOCAL CONFIGURATION--------------
-- Shared defaults; `wezterm_local` overrides them per machine.

local default_config = {
  leader                  = { key = 'q', mods = 'ALT', timeout_milliseconds = 9999 },
  initial_rows            = 35,
  initial_cols            = 125,
  animation_fps           = 1,
  cursor_blink_ease_in    = 'Constant',
  cursor_blink_ease_out   = 'Constant',
  max_fps                 = 60,
  scrollback_lines        = 50000,
  -- The right status changes at one-second resolution. Prompt, process and
  -- CWD transitions repaint immediately via user-var-changed.
  status_update_interval  = 1000,
  -- font                 = nil,
  -- font_size            = nil,
  -- front_end            = nil,
  -- window_frame         = nil,
  -- launch_menu          = nil,
  -- default_prog         = nil,
  window_pos              = { x = 175, y = 30 },  -- initial window position
}

local function prequire(name)
  local ok, module = pcall(require, name)
  if not ok then
    -- A missing local module is normal; report every other load failure.
    if not tostring(module):find("module '" .. name .. "' not found", 1, true) then
      wezterm.log_warn('Failed to load "' .. name .. '": ' .. tostring(module))
    end
    return {}
  end
  if type(module) ~= 'table' then
    wezterm.log_warn('Module "' .. name .. '" must return a table; using defaults')
    return {}
  end
  return module
end
local local_config = prequire 'wezterm_local'

local function configured(key)
  if local_config[key] ~= nil then
    return local_config[key]
  end
  return default_config[key]
end

for _, key in ipairs {
  'leader',
  'initial_rows',
  'initial_cols',
  'font',
  'font_size',
  'front_end',
  'window_frame',
  'launch_menu',
  'default_prog',
  'animation_fps',
  'cursor_blink_ease_in',
  'cursor_blink_ease_out',
  'max_fps',
  'scrollback_lines',
  'status_update_interval',
  'set_environment_variables',
} do
  config[key] = configured(key)
end
-- local_config.keys is appended after config.keys, see below.

config.adjust_window_size_when_changing_font_size = false
config.audible_bell = 'Disabled'
if is_windows then
  -- Do not override canonicalize_pasted_newlines: WezTerm's automatic default
  -- distinguishes Windows console programs from WSL. A global CRLF setting
  -- produces blank lines in non-bracketed WSL pastes.
  -- wsl.exe strips Windows env vars from the guest unless WSLENV forwards
  -- them; forward WEZTERM_PANE so WSL shells can detect they run in wezterm
  -- (zsh keys its OSC 1337 user-var emission off it).
  local env = {}
  for k, v in pairs(configured('set_environment_variables') or {}) do
    env[k] = v
  end
  local wslenv = tostring(env.WSLENV or os.getenv('WSLENV') or '')
  local forwarded = false
  for entry in wslenv:gmatch('[^:]+') do
    if (entry:match('^[^/]+') or ''):upper() == 'WEZTERM_PANE' then
      forwarded = true
    end
  end
  if not forwarded then
    wslenv = wslenv == '' and 'WEZTERM_PANE/u' or wslenv .. ':WEZTERM_PANE/u'
  end
  env.WSLENV = wslenv
  config.set_environment_variables = env
end
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

--------------STARTUP WINDOW POSITION--------------

local function configured_window_position()
  local default_pos = default_config.window_pos
  local local_pos = local_config.window_pos or {}
  return {
    x = local_pos.x or default_pos.x,
    y = local_pos.y or default_pos.y,
    origin = local_pos.origin or default_pos.origin,
  }
end

-- The screen area a startup position is clamped into. A position with an
-- origin is relative to that screen. An absolute position keeps the screen
-- that contains it, so a window can start on a secondary monitor; a stale
-- off-desktop value falls back to the active screen.
local function screen_bounds(origin, x, y)
  local ok, screens = pcall(wezterm.gui.screens)
  if not ok then
    wezterm.log_warn('Failed to read screen bounds: ' .. tostring(screens))
    return nil
  end
  local screen
  if origin == 'MainScreen' then
    screen = screens.main
  elseif origin == 'ActiveScreen' then
    screen = screens.active or screens.main
  elseif type(origin) == 'table' then
    screen = screens.by_name[origin.Named]
  else
    for _, candidate in pairs(screens.by_name) do
      if x >= candidate.x and x < candidate.x + candidate.width
          and y >= candidate.y and y < candidate.y + candidate.height then
        screen = candidate
        break
      end
    end
    screen = screen or screens.active or screens.main
    return screen and { x = screen.x, y = screen.y, width = screen.width, height = screen.height }
  end
  return screen and { x = 0, y = 0, width = screen.width, height = screen.height }
end

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(math.max(min_value, max_value), value))
end

local function clamp_window_position(position)
  if type(position.x) ~= 'number' or type(position.y) ~= 'number' then
    return position
  end
  local origin = position.origin
  local named = type(origin) == 'table' and type(origin.Named) == 'string'
  if not (origin == nil or origin == 'ScreenCoordinateSystem'
      or origin == 'MainScreen' or origin == 'ActiveScreen' or named) then
    wezterm.log_warn('Ignoring invalid window_pos.origin: ' .. tostring(origin))
    origin, named = nil, false
  end
  local bounds = screen_bounds(origin, position.x, position.y)
  if not bounds and named then
    -- A monitor can disappear between machines and docks. Interpret its
    -- relative coordinates on the active screen instead.
    wezterm.log_warn('Named startup screen is unavailable: ' .. origin.Named)
    origin = 'ActiveScreen'
    bounds = screen_bounds(origin)
  end
  if not bounds then
    return { x = position.x, y = position.y, origin = origin }
  end
  local visible_margin = 80
  return {
    x = clamp(position.x, bounds.x, bounds.x + bounds.width - visible_margin),
    y = clamp(position.y, bounds.y, bounds.y + bounds.height - visible_margin),
    origin = origin,
  }
end

--------------PANE STATE--------------
-- Shell and application integrations publish their state as OSC 1337 user
-- vars (see ../zsh/.zshrc, ../clink/user_var.lua, ../nvim/init.lua). The GUI
-- never discovers processes itself, except on the explicit keystrokes noted
-- below.

-- Equivalent to POSIX basename(3)
-- '/foo/bar'         -> 'bar'
-- '/foo/bar/'        -> ''
-- 'c:\\foo\\bar'     -> 'bar'
-- 'C:\\foo\\bar.exe' -> 'bar.exe'
local function basename(s)
  s = s:gsub('[/\\]+$', '')
  return s:match('([^/\\]+)$')
end

-- Turn a file URI into a display path. Keeps the leading slash on Unix and
-- the UNC marker on Windows.
local function normalize_path(path)
  path = path:gsub('^file://', '')
  path = path:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
  if is_windows then
    path = path:gsub('^/([A-Za-z]:)', '%1')
    if path:sub(1, 2) == '//' then
      path = path:gsub('/', '\\')
    end
  end
  return path
end

local function is_alt_screen(pane)
  return try(pane, 'is_alt_screen_active') == true
end

-- What the integration says about a pane. `at_prompt` is true only while an
-- integrated shell owns the line editor: a running command, a remote pane and
-- a program without integration all leave it false and receive raw keys.
local function shell_context(pane)
  local vars = try(pane, 'get_user_vars') or {}
  local integrated = vars.shell_integration == 'on'
  local shell = vars.shell_name
  if shell == nil or shell == '' then
    shell = vars.clink == 'on' and 'cmd' or vars.zsh == 'on' and 'zsh' or nil
  end
  return {
    vars = vars,
    shell = shell,
    integrated = integrated,
    at_prompt = integrated and vars.shell_prompt == 'on',
  }
end

-- Windows console REPLs do not treat Ctrl-D as EOF and publish no user vars,
-- and one started from the cmd prompt inherits Clink's stale ones, so resolve
-- it from the foreground process. Queried only on the explicit Esc and Ctrl-D
-- keystrokes, never from paint, status or navigation; remote panes have no
-- local process info and stay pass-through.
local function console_repl(pane)
  local info = try(pane, 'get_foreground_process_info')
  if type(info) ~= 'table' then return nil end
  local name = tostring(info.name):lower():match('([^/\\]+)$')
  if name == 'pwsh.exe' or name == 'powershell.exe' then return 'powershell' end
  if name ~= 'python.exe' and name ~= 'python3.exe' then return nil end
  local argv = type(info.argv) == 'table' and info.argv or {}
  if #argv == 1 then return 'python' end
  return #argv == 2 and tostring(argv[2]):lower():match('ptpython') and 'ptpython' or nil
end

--------------CONTEXT-AWARE KEY ACTIONS--------------

-- 'Ctrl-c' interrupts when nothing is selected, otherwise copies the selection.
local function action_ctrl_c(window, pane)
  local selection = window:get_selection_text_for_pane(pane)
  if selection == '' then
    window:perform_action(send_key('c', 'CTRL'), pane)
  else
    window:perform_action(act.CopyTo 'ClipboardAndPrimarySelection', pane)
  end
end

-- Line-clearing sequences. cmd.exe has no Ctrl-A/Ctrl-K, so it gets keys.
local clear_cmd_line = act.Multiple {
  send_key('End'),
  send_key('Home', 'SHIFT'),
  send_key('Delete'),
}
local clear_shell_line = act.SendString '\x01\x0b'  -- Ctrl-A Ctrl-K

-- 'Ctrl-d' keeps native EOF semantics where the shell honours it. At an
-- integrated prompt an active Python venv is deactivated first; cmd.exe,
-- PowerShell and the Python REPLs get an explicit exit command because they
-- ignore Ctrl-D. The line is cleared first so pending input never merges into
-- the command.
local exit_cmd = act.Multiple { clear_cmd_line, act.SendString 'exit\r' }
local deactivate_venv_cmd = act.Multiple { clear_cmd_line, act.SendString 'deactivate\r' }
local deactivate_venv_shell = act.SendString '\x01\x0bdeactivate\r'
local repl_exits = {
  powershell = exit_cmd,  -- PSReadLine leaves Ctrl-D unbound in Windows mode
  python     = act.SendString 'exit()\r',
  ptpython   = act.SendString 'exit()\n',
}

local function action_exit_shell(window, pane)
  local ctx = shell_context(pane)
  local action
  if ctx.at_prompt and ctx.vars.venv == 'on' then
    action = ctx.shell == 'cmd' and deactivate_venv_cmd or deactivate_venv_shell
  elseif ctx.at_prompt and ctx.shell == 'cmd' then
    action = exit_cmd
  else
    local repl = not ctx.at_prompt and console_repl(pane)
    action = repl and repl_exits[repl] or send_key('d', 'CTRL')
  end
  window:perform_action(action, pane)
end

-- 'Esc' clears the line at an integrated prompt or in a console REPL, and is
-- a real Escape for full-screen apps, overlays and unknown panes.
local plain_escape = send_key('Escape')
local fzf_escape = send_key('g', 'CTRL')  -- fzf's abort key, works across WSL/MSYS boundaries
-- ConPTY holds a bare \x1b as a possible escape-sequence prefix, so a
-- synthesized plain Escape never reaches console apps as VK_ESCAPE. Encode
-- the press as explicit win32-input-mode key events (CSI Vk;Sc;Uc;Kd;Cs;Rc _),
-- which ConPTY translates deterministically into VK_ESCAPE INPUT_RECORDs;
-- that is what Clink's popups listen for.
local win32_escape = act.SendString '\x1b[27;1;27;1;0;1_\x1b[27;1;27;0;0;1_'

local function action_escape(window, pane)
  local action
  local ctx = shell_context(pane)
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
    action = ctx.shell == 'cmd' and clear_cmd_line or clear_shell_line
  else
    -- A console REPL owns its line editor but publishes nothing. Everything
    -- else, remote panes included, is pass-through; never scrape the visible
    -- line to decide what Escape means.
    local repl = console_repl(pane)
    action = repl == 'powershell' and clear_cmd_line or repl and clear_shell_line or plain_escape
  end
  window:perform_action(action, pane)
end

-- 'LEADER + l' logs pane snapshots, user vars and local config into the debug
-- overlay for quick diagnostics.
local function action_log_debug_info(window, pane)
  local pane_id = pane:pane_id()
  local pane_info
  local tab = try(pane, 'tab')
  for _, entry in ipairs(tab and try(tab, 'panes_with_info') or {}) do
    if entry.pane:pane_id() == pane_id then
      pane_info = entry
    end
  end
  wezterm.log_info {
    { context = 'Pane info', data = pane_info },
    { context = 'Pane user vars', data = try(pane, 'get_user_vars') },
    { context = 'Pane metadata', data = try(pane, 'get_metadata') },
    { context = 'Pane misc', data = { { field = 'alt screen', value = tostring(try(pane, 'is_alt_screen_active')) } } },
    { context = 'Local configuration', data = local_config },
  }
end

-- Navigation keys switch between full-screen apps and scrollback navigation.
local function choose_action(predicate, true_action, false_action)
  return function(window, pane)
    window:perform_action(predicate(pane) and true_action or false_action, pane)
  end
end

-- Alt-screen apps, fzf, Clink popups and anything that is not an integrated
-- prompt get the real key; only an authoritative local prompt scrolls.
local function wants_raw_nav_keys(pane)
  local ctx = shell_context(pane)
  return is_alt_screen(pane) or ctx.vars.fzf == 'on' or ctx.vars.clink_popup == 'on'
    or not ctx.at_prompt
end

-- Home/Up/Down are line-editor keys at a prompt and in unknown/remote panes;
-- they scroll only while an integrated shell runs a command.
local function has_shell_prompt(pane)
  local ctx = shell_context(pane)
  return not ctx.integrated or ctx.at_prompt
end

local action_ctrl_home = choose_action(wants_raw_nav_keys, send_key('Home', 'CTRL'), act.ScrollToTop)
local action_ctrl_end = choose_action(wants_raw_nav_keys, send_key('End', 'CTRL'), act.ScrollToBottom)
local action_pageup = choose_action(wants_raw_nav_keys, send_key('PageUp'), act.ScrollByPage(-0.5))
local action_pagedown = choose_action(wants_raw_nav_keys, send_key('PageDown'), act.ScrollByPage(0.5))
local action_home = choose_action(has_shell_prompt, send_key('Home'), act.ScrollToTop)
local action_up = choose_action(has_shell_prompt, send_key('UpArrow'), act.ScrollByLine(-1))
local action_down = choose_action(has_shell_prompt, send_key('DownArrow'), act.ScrollByLine(1))

--------------PROCESS TERMINATION--------------
-- 'LEADER + k' is a Windows-only escape hatch for a wedged foreground
-- process: taskkill /T, then taskkill /F after 0.5 s if the same process is
-- still there. The synchronous process query runs only on this keystroke.
-- Everywhere else, and for an idle integrated shell, it sends Ctrl-C.

local function kill_target(pane)
  local info = try(pane, 'get_foreground_process_info')
  if type(info) ~= 'table' or type(info.pid) ~= 'number' or info.pid < 1 then
    return nil
  end
  return {
    pid = info.pid,
    name = tostring(info.name or ''):lower(),
    executable = tostring(info.executable or ''):lower(),
    start_time = info.start_time,  -- opaque; equal across two queries means no PID reuse
  }
end

local function same_kill_target(a, b)
  if not a or not b or a.pid ~= b.pid then return false end
  if a.start_time ~= nil and b.start_time ~= nil and a.start_time ~= b.start_time then return false end
  if a.executable ~= '' and b.executable ~= '' and a.executable ~= b.executable then return false end
  return a.name == '' or b.name == '' or a.name == b.name
end

local function taskkill(target, force)
  local args = { 'taskkill.exe', '/PID', tostring(target.pid), '/T' }
  if force then
    args[#args + 1] = '/F'
  end
  local ok, err = pcall(wezterm.background_child_process, args)
  if not ok then
    wezterm.log_warn('Failed to launch taskkill: ' .. tostring(err))
  end
  return ok
end

local function action_kill_process(window, pane)
  local ctx = is_windows and shell_context(pane)
  local target = ctx and not (ctx.shell and ctx.at_prompt) and kill_target(pane)
  if not target or not taskkill(target, false) then
    window:perform_action(send_key('c', 'CTRL'), pane)
    return
  end
  -- Hold only the pane id across the delay: a pane object that dies before
  -- the timer fires aborts the timer's coroutine.
  local pane_id = pane:pane_id()
  wezterm.time.call_after(0.5, function()
    local ok, err = pcall(function()
      local live_pane = wezterm.mux.get_pane(pane_id)
      if live_pane and same_kill_target(target, kill_target(live_pane)) then
        taskkill(target, true)
      end
    end)
    if not ok then
      wezterm.log_warn('Failed to run taskkill follow-up: ' .. tostring(err))
    end
  end)
end

--------------ALT-SCREEN PANE ACTIONS--------------

-- The pane an alt-screen action targets: the current pane when it runs an
-- alt-screen app, otherwise the only alt-screen pane in the tab. Several
-- candidates are refused; never paste into or zoom an arbitrary one.
local function alt_screen_target(tab, current_pane)
  local current_id = current_pane:pane_id()
  local candidates = {}
  for _, entry in ipairs(try(tab, 'panes_with_info') or {}) do
    if is_alt_screen(entry.pane) then
      if entry.pane:pane_id() == current_id then
        return entry
      end
      candidates[#candidates + 1] = entry
    end
  end
  if #candidates == 1 then
    return candidates[1]
  end
  return nil, #candidates > 1 and 'ambiguous' or 'missing'
end

-- 'Ctrl + Alt + ;' toggles the zoom state of the alt-screen pane.
local function action_alt_pane_toggle_zoom(window, pane)
  local tab = window:active_tab()
  local target, reason = alt_screen_target(tab, pane)
  if not target then
    if reason == 'ambiguous' then
      wezterm.log_warn('Refusing to zoom: multiple alt-screen panes are eligible')
    end
    return
  end
  local ok, err = pcall(function()
    target.pane:activate()
    tab:set_zoomed(not target.is_zoomed)
  end)
  if not ok then
    wezterm.log_warn('Failed to toggle alt-pane zoom: ' .. tostring(err))
  end
end

-- Copy-mode 'Ctrl + Enter' sends the selection to the alt-screen pane, e.g.
-- into Neovim or another full-screen TUI. send_paste keeps bracketed-paste
-- protection.
local function action_send_to_alt_pane(window, pane)
  local text = window:get_selection_text_for_pane(pane)
  if text == '' then return end
  local target, reason = alt_screen_target(window:active_tab(), pane)
  if not target then
    if reason == 'ambiguous' then
      wezterm.log_warn('Refusing to paste: multiple alt-screen panes are eligible')
    end
    return
  end
  local ok, err = pcall(function()
    target.pane:send_paste(text)
    target.pane:activate()
  end)
  if not ok then
    wezterm.log_warn('Failed to send protected paste: ' .. tostring(err))
  end
end

--------------KEY TABLE ICONS--------------
-- The right status shows one icon per active key table, per window.

local window_states = {}  -- window_id -> { icons = {...}, seen = clock() }

local function window_state(window)
  local id = window:window_id()
  local state = window_states[id]
  if not state then
    state = { icons = {} }
    window_states[id] = state
  end
  state.seen = clock()
  return state
end

local function push_key_icon(icon)
  return function(window)
    local icons = window_state(window).icons
    icons[#icons + 1] = icon
  end
end

local function pop_key_icon(window)
  table.remove(window_state(window).icons)
end

local function clear_key_icons(window)
  window_state(window).icons = {}
end

--------------KEY TABLES AND BINDINGS--------------

config.keys = {
  { key = 'F1', mods = 'NONE', action = act.ShowDebugOverlay },
  { key = 'F2', mods = 'NONE', action = act.ShowLauncher },
  { key = 'F3', mods = 'NONE', action = act.ShowTabNavigator },
  { key = 'F4', mods = 'NONE', action = act.ActivateCommandPalette },
  { key = 'F5', mods = 'NONE', action = act.CharSelect { group = 'SmileysAndEmotion' } },
  { key = 'F6', mods = 'NONE', action = act.CharSelect { group = 'Objects' } },
  { key = 'F7', mods = 'NONE', action = act.CharSelect { group = 'Symbols' } },
  { key = 'F8', mods = 'NONE', action = act.CharSelect { group = 'UnicodeNames' } },
  { key = 'd', mods = 'CTRL', action = cb(action_exit_shell) },
  { key = 'k', mods = 'LEADER', action = cb(action_kill_process) },
  -- Pane destruction is explicit and confirmed; never a second CLI process.
  { key = 'x', mods = 'LEADER', action = act.CloseCurrentPane { confirm = true } },
  { key = 'l', mods = 'LEADER', action = cb(action_log_debug_info) },
  { key = 'Home', mods = 'CTRL', action = cb(action_ctrl_home) },
  { key = 'End', mods = 'CTRL', action = cb(action_ctrl_end) },
  { key = 'PageUp', mods = 'NONE', action = cb(action_pageup) },
  { key = 'PageDown', mods = 'NONE', action = cb(action_pagedown) },
  { key = 'Escape', mods = 'NONE', action = cb(action_escape) },
  -- Always the Ctrl-L key; never a textual `clear` into a possibly non-empty line.
  { key = 'l', mods = 'CTRL', action = send_key('l', 'CTRL') },
  { key = 't', mods = 'CTRL|ALT', action = act.SpawnTab 'DefaultDomain' },
  { key = 'y', mods = 'CTRL|ALT', action = act.SpawnTab 'CurrentPaneDomain' },
  { key = 'Tab', mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },
  { key = 'Tab', mods = 'CTRL', action = act.ActivateTabRelative(1) },
  { key = '\'', mods = 'CTRL|ALT', action = act.TogglePaneZoomState },
  { key = ';', mods = 'CTRL|ALT', action = cb(action_alt_pane_toggle_zoom) },

  -- Key table stack: clear, pop, push term, push nvim.
  { key = '0', mods = 'CTRL|ALT', action = act.Multiple { act.ClearKeyTableStack, cb(clear_key_icons) } },
  { key = '-', mods = 'CTRL|ALT', action = act.Multiple { act.PopKeyTable, cb(pop_key_icon) } },
  {
    key = '9',
    mods = 'CTRL|ALT',
    action = act.Multiple {
      act.ActivateKeyTable { name = 'term', one_shot = false },
      cb(push_key_icon(nf.cod_terminal)),
    },
  },
  {
    key = '8',
    mods = 'CTRL|ALT',
    action = act.Multiple {
      act.ActivateKeyTable { name = 'nvim', one_shot = false },
      cb(push_key_icon(nf.custom_neovim)),
    },
  },
}

-- Send clean F keys to the shell, e.g. for Midnight Commander.
for f = 1, 12 do
  local key = 'F' .. f
  table.insert(config.keys, { key = key, mods = 'CTRL|ALT', action = send_key(key) })
end

for _, item in ipairs {
  { key = 'LeftArrow',  direction = 'Left' },
  { key = 'DownArrow',  direction = 'Down' },
  { key = 'UpArrow',    direction = 'Up' },
  { key = 'RightArrow', direction = 'Right' },
} do
  table.insert(config.keys, { key = item.key, mods = 'CTRL', action = act.ActivatePaneDirection(item.direction) })
  table.insert(config.keys, { key = item.key, mods = 'ALT', action = act.AdjustPaneSize { item.direction, 1 } })
  table.insert(config.keys, { key = item.key, mods = 'CTRL|ALT', action = act.SplitPane { direction = item.direction } })
end

config.key_tables = {
  term = {
    { key = 'w',         mods = 'CTRL', action = act.CloseCurrentTab { confirm = true } },
    { key = 'c',         mods = 'CTRL', action = cb(action_ctrl_c) },

    { key = '=',         mods = 'CTRL', action = act.IncreaseFontSize },
    { key = '-',         mods = 'CTRL', action = act.DecreaseFontSize },
    { key = '0',         mods = 'CTRL', action = act.ResetFontSize },

    { key = 'v',         mods = 'CTRL', action = act.PasteFrom 'Clipboard' },
    { key = 'x',         mods = 'CTRL', action = act.ActivateCopyMode },
    { key = 's',         mods = 'CTRL', action = act.Search 'CurrentSelectionOrEmptyString' },

    { key = 'Home',      mods = 'NONE', action = cb(action_home) },
    { key = 'UpArrow',   mods = 'NONE', action = cb(action_up) },
    { key = 'DownArrow', mods = 'NONE', action = cb(action_down) },
  },

  nvim = {},
}

if wezterm.target_triple:match('darwin') then
  -- Mac: make sure Ctrl+1..9 pass through to the shell as character keys.
  for k = 1, 9 do
    table.insert(config.keys, { key = tostring(k), mods = 'CTRL', action = send_key(tostring(k), 'CTRL') })
  end
  -- Cursor Home/End plus half-page Up/Down. Logical keys let WezTerm use the
  -- active keyboard protocol instead of hard-coded SS3 bytes.
  table.insert(config.keys, { key = 'LeftArrow',  mods = 'SUPER', action = send_key('Home') })
  table.insert(config.keys, { key = 'DownArrow',  mods = 'SUPER', action = act.ScrollByPage(0.5) })
  table.insert(config.keys, { key = 'UpArrow',    mods = 'SUPER', action = act.ScrollByPage(-0.5) })
  table.insert(config.keys, { key = 'RightArrow', mods = 'SUPER', action = send_key('End') })
end

-- Local key binds go last so machine-specific overrides win.
if local_config.keys ~= nil and type(local_config.keys) ~= 'table' then
  wezterm.log_warn('wezterm_local.keys must be a table; ignoring local key bindings')
else
  for _, binding in ipairs(local_config.keys or {}) do
    table.insert(config.keys, binding)
  end
end

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

--------------PER-PANE MEMORY--------------
-- Everything the status bar and tab titles remember about a pane, keyed by
-- pane id and expired by inactivity. Fields:
--   seen     last clock() the pane was painted
--   vars     user vars as of the last state_serial commit
--   cwd      display path read after the last cwd_ready
--   command  { token, started } of the running command, for the elapsed timer
--   settle   { shown, pending, since } anti-flicker state of the tab title
--   title    { name, pane_title, text } last formatted tab title

local pane_states = {}

local function pane_state(pane_id)
  local state = pane_states[pane_id]
  if not state then
    state = {}
    pane_states[pane_id] = state
  end
  state.seen = clock()
  return state
end

local cache_prune_interval_seconds = 300
local cache_retention_seconds = 3600
local last_prune = clock()

-- Live tabs are touched by status and title painting, so no mux sweep is
-- needed; whatever went untouched for an hour is gone.
local function prune_stale_states()
  local now = clock()
  if now - last_prune < cache_prune_interval_seconds then
    return
  end
  last_prune = now
  for id, state in pairs(pane_states) do
    if now - state.seen >= cache_retention_seconds then
      pane_states[id] = nil
    end
  end
  for id, state in pairs(window_states) do
    if now - state.seen >= cache_retention_seconds then
      window_states[id] = nil
    end
  end
end

-- Producers write several user vars per transition and emit state_serial
-- last. Each var triggers update-status, so painting is skipped while these
-- fields differ from the committed snapshot; the commit repaints once.
local committed_fields = {
  'shell_integration', 'shell_name', 'shell_prompt', 'process_name',
  'command_token', 'clink', 'zsh', 'nvim', 'cwd_ready', 'state_serial',
}

local function batch_in_progress(state, live)
  if not state.vars then
    -- Nothing committed since config load: an integrated shell that has not
    -- reached its state_serial yet is mid-batch; anything else is settled.
    return live.shell_integration == 'on' and (live.state_serial or '') == ''
  end
  for _, name in ipairs(committed_fields) do
    if live[name] ~= state.vars[name] then
      return true
    end
  end
  return false
end

-- Read the CWD from the terminal's OSC 7 state. Only called right after a
-- producer signals cwd_ready: without an in-memory URI WezTerm would fall
-- back to scanning operating-system processes.
local function refresh_cwd(pane, state)
  local ok, cwd = pcall(pane.get_current_working_dir, pane)
  if not ok then
    state.cwd = state.cwd or ''
    return
  end
  if cwd ~= nil and type(cwd) ~= 'string' then
    cwd = cwd.file_path or tostring(cwd)  -- Url object; older builds return a string
  end
  state.cwd = cwd and normalize_path(cwd) or ''
end

local function display_cwd(pane, state, vars)
  if state.cwd == nil and (vars.cwd_ready or '') ~= '' then
    refresh_cwd(pane, state)
  end
  return state.cwd or ''
end

-- Seconds since a new command_token was first seen; nil at the prompt.
local function command_elapsed(state, vars)
  local token = vars.command_token or ''
  if token == '' or vars.shell_prompt == 'on' then
    state.command = nil
    return nil
  end
  local now = clock()
  if not state.command or state.command.token ~= token then
    state.command = { token = token, started = now }
  end
  return now - state.command.started
end

local function format_elapsed(seconds)
  seconds = math.max(0, math.floor(seconds))
  local days = math.floor(seconds / 86400)
  return (days > 0 and days .. 'd' or '')
    .. string.format('%02d:%02d:%02d', math.floor(seconds / 3600) % 24, math.floor(seconds / 60) % 60, seconds % 60)
end

--------------STATUS BAR--------------

local function format_left_status(window)
  return wezterm.format {
    { Foreground = { Color = window:leader_is_active() and '#FF6060' or '#000000' } },
    { Text = nf.md_lightning_bolt },
  }
end

local function toggle_color(status)
  return status == 'on' and '#AF8461' or status == 'off' and '#6A946A' or '#666666'
end

local function format_right_status(window, pane, state, vars)
  local items = {}
  local function add(color, text)
    if text ~= '' then
      items[#items + 1] = { Foreground = { Color = color } }
      items[#items + 1] = { Text = text }
    end
  end
  local icons = window_state(window).icons
  local cwd = display_cwd(pane, state, vars)
  local elapsed = command_elapsed(state, vars)
  add('Yellow', table.concat(icons, ' '))
  add('#4488FF', #icons > 0 and ' ' .. nf.md_arrow_expand_left .. '    ' or '')
  add('#BBBBBB', cwd ~= '' and wezterm.truncate_left(cwd, 60) .. '      ' or '')
  add('#847EAE', window:active_workspace() .. ' : ' .. (try(pane, 'get_domain_name') or '') .. '    ')
  add(toggle_color(vars.clink), nf.md_alpha_c .. ' ')
  add(toggle_color(vars.zsh), nf.md_alpha_z .. ' ')
  add(toggle_color(vars.nvim), nf.custom_neovim .. '    ')
  add('#AB696F', elapsed and format_elapsed(elapsed) .. '    ' or '')
  return wezterm.format(items)
end

local function refresh_status(window, pane, state, vars)
  window:set_left_status(format_left_status(window))
  window:set_right_status(format_right_status(window, pane, state, vars))
end

-- Paint from the committed snapshot; skip while a producer batch is open.
-- Before the first commit (e.g. after a config reload) the live vars are the
-- snapshot.
local function paint_status(window, pane)
  local state = pane_state(pane:pane_id())
  local live = try(pane, 'get_user_vars') or {}
  if batch_in_progress(state, live) then
    return
  end
  if not state.vars and (live.state_serial or '') ~= '' then
    state.vars = live
  end
  refresh_status(window, pane, state, state.vars or live)
end

wezterm.on('user-var-changed', function(window, pane, name, value)
  local state = pane_state(pane:pane_id())
  if name == 'cwd_ready' and value ~= '' then
    refresh_cwd(pane, state)
  elseif name == 'state_serial' then
    state.vars = try(pane, 'get_user_vars') or state.vars
    refresh_status(window, pane, state, state.vars or {})
  end
end)

wezterm.on('window-focus-changed', paint_status)

wezterm.on('update-status', function(window, pane)
  paint_status(window, pane)
  prune_stale_states()
end)

--------------TAB TITLES--------------
-- Tab titles use the PaneInformation snapshot and user vars only; they never
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

local function process_label(label)
  if type(label) ~= 'string' then return nil end
  label = label:match('^%s*(.-)%s*$')
  label = (basename(label) or label):lower():gsub('%.exe$', '')
  return label ~= '' and label or nil
end

local function display_process_name(vars, pane_title)
  if vars.nvim == 'on' then
    return 'nvim'
  end
  return process_label(vars.process_name) or process_label(vars.shell_name) or process_label(pane_title)
end

-- Flicker guard: a new name must persist for a second before it replaces the
-- shown one, so a short-lived command (git, ls, a build step) never flips the
-- title. Re-evaluated on every redraw; no timers.
local tab_title_settle_seconds = 1.0

local function settled_name(state, name)
  local settle = state.settle
  if not settle then
    state.settle = { shown = name }
    return name
  end
  if name == settle.shown then
    settle.pending = nil
  elseif name ~= settle.pending then
    settle.pending, settle.since = name, clock()
  elseif clock() - settle.since >= tab_title_settle_seconds then
    settle.shown, settle.pending = name, nil
  end
  return settle.shown
end

local function tab_title_text(tab, max_width)
  local width = math.max(1, max_width or 1)
  if tab.tab_title ~= '' then
    return wezterm.truncate_right(tab.tab_title, width)
  end
  local info = tab.active_pane
  local state = pane_state(info.pane_id)
  local vars = state.vars or info.user_vars
  local name = settled_name(state, display_process_name(vars, info.title) or 'terminal')
  local title = state.title
  if not title or title.name ~= name or title.pane_title ~= info.title then
    local prefix = info.title:match('^Copy mode:') and 'Copy mode: ' or ''
    local icon = process_icons[name] or { '>', name }
    title = { name = name, pane_title = info.title, text = prefix .. icon[1] .. ' ' .. icon[2] .. ' : ' .. info.pane_id }
    state.title = title
  end
  return wezterm.truncate_right(title.text, width)
end

wezterm.on('format-tab-title', function(tab, _tabs, _panes, _config, _hover, max_width)
  local ok, text = pcall(tab_title_text, tab, max_width)
  if ok then
    return text
  end
  warn_rate_limited('tab-title', 'Failed to format tab title: ' .. tostring(text))
  -- Hold the last good title instead of dropping to the default for a tick.
  local state = tab.active_pane and pane_states[tab.active_pane.pane_id]
  return state and state.title and wezterm.truncate_right(state.title.text, math.max(1, max_width or 1)) or nil
end)

--------------STARTUP--------------
-- Position the first window from local configuration unless WezTerm already
-- got explicit startup args.

wezterm.on('gui-startup', function(cmd)
  local spawn = {}
  for k, v in pairs(cmd or {}) do
    spawn[k] = v
  end
  if spawn.position == nil then
    spawn.position = clamp_window_position(configured_window_position())
  end
  local ok, tab_or_err, pane, mux_window = pcall(wezterm.mux.spawn_window, spawn)
  if not ok then
    wezterm.log_warn('Failed to spawn startup window: ' .. tostring(tab_or_err))
    return
  end
  -- Two early repaints let the GUI and the shell integration settle. The
  -- timers hold plain ids: the objects may not outlive the delay.
  local window_id, pane_id = mux_window:window_id(), pane:pane_id()
  for _, delay in ipairs { 0.10, 0.40 } do
    wezterm.time.call_after(delay, function()
      local ok_refresh, err = pcall(function()
        local live_window = wezterm.mux.get_window(window_id)
        local live_pane = wezterm.mux.get_pane(pane_id)
        local gui_window = live_window and live_window:gui_window()
        if gui_window and live_pane then
          paint_status(gui_window, live_pane)
        end
      end)
      if not ok_refresh then
        wezterm.log_warn('Failed to refresh startup status: ' .. tostring(err))
      end
    end)
  end
end)

return config

----------------------------------------------------------------------------
-- debugging goodies
--
-- get gui window, active pane, active pane title:
--
--     > wezterm['mux']['all_windows']()[1]:gui_window():active_pane():get_title()
