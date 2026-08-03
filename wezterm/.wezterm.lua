local wezterm = require 'wezterm'
local act = wezterm.action
local cb = wezterm.action_callback
local is_windows = wezterm.target_triple:match('windows') ~= nil
local config = wezterm.config_builder()

-- Small helpers used throughout the config.

local function send_key(key, mods)
  return act.SendKey { key = key, mods = mods or 'NONE' }
end

-- A monotonicized UI clock. WezTerm exposes UTC wall time rather than a
-- monotonic clock to Lua, so reject backward steps and cap discontinuities.
-- Normal sub-second/one-second progress remains accurate; suspend or manual
-- clock corrections cannot freeze a cache or instantly skip a settle period.
local ui_clock_state = { raw = nil, logical = 0 }
local function raw_clock_seconds()
  local ok, value = pcall(function()
    return tonumber(wezterm.time.now():format_utc('%s%.3f'))
  end)
  return ok and value or nil
end

local function clock_seconds()
  local raw = raw_clock_seconds()
  if not raw then
    return ui_clock_state.logical
  end
  if ui_clock_state.raw ~= nil then
    local delta = raw - ui_clock_state.raw
    if delta >= 0 then
      -- One-second status ticks are normal. A larger jump is a suspend or
      -- wall-clock correction; advance only slightly so TTLs and the title
      -- settle guard cannot all expire in one distracting repaint.
      ui_clock_state.logical = ui_clock_state.logical + (delta <= 2 and delta or 0.25)
    end
  end
  ui_clock_state.raw = raw
  return ui_clock_state.logical
end

local warning_last_logged = {}
local function log_warn_rate_limited(key, message, interval_seconds)
  local now = clock_seconds()
  local last = warning_last_logged[key]
  if last and (now - last) < (interval_seconds or 60) then
    return
  end
  warning_last_logged[key] = now
  wezterm.log_warn(message)
end

local function is_stale_mux_object_error(err)
  local text = tostring(err)
  return text:match('not found in mux') ~= nil
end

--------------DEFAULT CONFIGURATION--------------
-- Shared defaults plus optional per-machine overrides.

local default_config = {
  leader                  = { key = 'q', mods = 'ALT', timeout_milliseconds = 9999 },
  initial_rows            = 35,
  initial_cols            = 125,
  animation_fps           = 1,
  cursor_blink_ease_in    = 'Constant',
  cursor_blink_ease_out   = 'Constant',
  max_fps                 = 60,
  scrollback_lines        = 50000,
  -- The right status changes at one-second resolution. Prompt/process/CWD
  -- transitions repaint immediately via user-var-changed.
  status_update_interval  = 1000,
  -- font                 = nil,
  -- font_size            = nil,
  -- front_end            = nil,
  -- window_frame         = nil,
  -- launch_menu          = nil,
  -- default_prog         = nil,
  window_pos              = { x = 175, y = 30 },  -- initial window position
}

-------------------------------------------------

---------------LOCAL CONFIGURATION---------------

local function prequire(m) 
  local ok, response = pcall(require, m)
  if not ok then
    local err = tostring(response)
    -- Treat missing optional local module as normal; warn on all other load failures.
    if not string.find(err, "module '" .. m .. "' not found", 1, true) then
      wezterm.log_warn('Failed to load "' .. m .. '": ' .. err)
    end
    return {}
  end
  if type(response) ~= 'table' then
    wezterm.log_warn('Module "' .. m .. '" must return a table; using defaults')
    return {}
  end
  return response
end
local local_config = prequire 'wezterm_local'

local function configured_value(key)
  if local_config[key] ~= nil then
    return local_config[key]
  end
  return default_config[key]
end

local function get_configured_window_position()
  local default_pos = type(default_config.window_pos) == 'table' and default_config.window_pos or {}
  local local_pos = type(local_config.window_pos) == 'table' and local_config.window_pos or {}
  return {
    x = local_pos.x ~= nil and local_pos.x or default_pos.x,
    y = local_pos.y ~= nil and local_pos.y or default_pos.y,
    origin = local_pos.origin ~= nil and local_pos.origin or default_pos.origin,
  }
end

local function get_screen_bounds(origin, x, y)
  if not wezterm.gui or type(wezterm.gui.screens) ~= 'function' then
    return nil
  end
  local ok, screens = pcall(wezterm.gui.screens)
  if not ok or type(screens) ~= 'table' then
    log_warn_rate_limited('screens', 'Failed to read screen bounds: ' .. tostring(screens))
    return nil
  end
  local screen
  local relative_coordinates = false
  if origin == 'MainScreen' then
    screen = screens.main
    relative_coordinates = true
  elseif origin == 'ActiveScreen' then
    screen = screens.active or screens.main
    relative_coordinates = true
  elseif type(origin) == 'table' and type(origin.Named) == 'string' then
    screen = type(screens.by_name) == 'table' and screens.by_name[origin.Named] or nil
    relative_coordinates = true
  else
    -- ScreenCoordinateSystem coordinates are absolute. Preserve a valid
    -- position on a non-active monitor by selecting the screen that contains
    -- it; fall back to the active screen only for stale/off-desktop values.
    if type(screens.by_name) == 'table' and type(x) == 'number' and type(y) == 'number' then
      for _, candidate in pairs(screens.by_name) do
        if type(candidate) == 'table'
            and type(candidate.x) == 'number' and type(candidate.y) == 'number'
            and type(candidate.width) == 'number' and type(candidate.height) == 'number'
            and x >= candidate.x and x < candidate.x + candidate.width
            and y >= candidate.y and y < candidate.y + candidate.height then
          screen = candidate
          break
        end
      end
    end
    screen = screen or screens.active or screens.main
  end
  if type(screen) ~= 'table' then
    return nil
  end
  if type(screen.x) ~= 'number' or type(screen.y) ~= 'number'
      or type(screen.width) ~= 'number' or type(screen.height) ~= 'number' then
    return nil
  end
  return {
    x = relative_coordinates and 0 or screen.x,
    y = relative_coordinates and 0 or screen.y,
    width = screen.width,
    height = screen.height,
  }
end

local function clamp_number(value, min_value, max_value)
  if max_value < min_value then
    max_value = min_value
  end
  return math.max(min_value, math.min(max_value, value))
end

local function clamp_window_position(position)
  if type(position) ~= 'table' or type(position.x) ~= 'number' or type(position.y) ~= 'number' then
    return position
  end
  local origin = position.origin
  local valid_origin = origin == nil or origin == 'ScreenCoordinateSystem'
    or origin == 'MainScreen' or origin == 'ActiveScreen'
    or (type(origin) == 'table' and type(origin.Named) == 'string')
  if not valid_origin then
    log_warn_rate_limited('window-origin', 'Ignoring invalid window_pos.origin: ' .. tostring(origin))
    origin = nil
  end
  local clamped = {}
  for k, v in pairs(position) do
    clamped[k] = v
  end
  clamped.origin = origin
  local bounds = get_screen_bounds(origin, position.x, position.y)
  if not bounds and type(origin) == 'table' and type(origin.Named) == 'string' then
    -- A monitor can disappear between machines/docks. Preserve a usable
    -- startup by interpreting its relative coordinates on the active screen.
    log_warn_rate_limited('window-origin-missing', 'Named startup screen is unavailable: ' .. origin.Named)
    origin = 'ActiveScreen'
    clamped.origin = origin
    bounds = get_screen_bounds(origin)
  end
  if not bounds then
    return clamped
  end
  local visible_margin = 80
  clamped.x = clamp_number(position.x, bounds.x, bounds.x + bounds.width - visible_margin)
  clamped.y = clamp_number(position.y, bounds.y, bounds.y + bounds.height - visible_margin)
  return clamped
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
  config[key] = configured_value(key)
end
-- local_config.keys applied after config.keys
-------------------------------------------------

config.adjust_window_size_when_changing_font_size = false
config.audible_bell = 'Disabled'
if is_windows then
  -- Do not override canonicalize_pasted_newlines: WezTerm's automatic default
  -- distinguishes Windows console programs from WSL. A global CRLF setting
  -- produces blank lines in non-bracketed WSL pastes.
  -- wsl.exe strips Windows env vars from the guest unless WSLENV forwards
  -- them; forward WEZTERM_PANE so WSL shells can detect they run in wezterm
  -- (zsh keys its OSC 1337 user-var emission off it)
  local env = {}
  local configured_env = configured_value('set_environment_variables')
  if type(configured_env) == 'table' then
    for k, v in pairs(configured_env) do
      env[k] = v
    end
  end
  local wslenv = env.WSLENV ~= nil and tostring(env.WSLENV) or os.getenv('WSLENV')
  local parts = {}
  local has_wezterm_pane = false
  for part in tostring(wslenv or ''):gmatch('[^:]+') do
    parts[#parts + 1] = part
    local name = part:match('^([^/]+)')
    if name and name:upper() == 'WEZTERM_PANE' then
      has_wezterm_pane = true
    end
  end
  if not has_wezterm_pane then
    parts[#parts + 1] = 'WEZTERM_PANE/u'
  end
  env.WSLENV = table.concat(parts, ':')
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

--------------PATH AND PANE-STATE HELPERS--------------

-- Equivalent to POSIX basename(3)
-- '/foo/bar'         -> 'bar'
-- '/foo/bar/'        -> ''
-- 'c:\\foo\\bar'     -> 'bar'
-- 'C:\\foo\\bar.exe' -> 'bar.exe'

local function get_basename(s)
  s = s:gsub('[/\\]+$', '')
  return s:match('([^/\\]+)$')
end

-- Normalize a file URI without dropping the leading slash on Unix or the UNC
-- marker on Windows. Current WezTerm Url objects expose file_path directly;
-- this string path remains for compatibility with older builds.

local function normalize_path(path)
  if type(path) ~= 'string' then
    return ''
  end
  local npath = path
  npath = npath:gsub('^file://', '')
  npath = npath:gsub('%%(%x%x)', function(h) return string.char(tonumber(h,16)) end)
  if is_windows then
    npath = npath:gsub('^/([A-Za-z]:)', '%1')
    if npath:sub(1, 2) == '//' then
      npath = npath:gsub('/', '\\')
    end
  end
  return npath
end

local function get_pane_cache_id(pane)
  if not pane then
    return nil
  end
  local ok_field, pane_id_field = pcall(function() return pane.pane_id end)
  if not ok_field then
    return nil
  end
  if type(pane_id_field) == 'function' then
    local ok, pane_id = pcall(pane_id_field, pane)
    if ok then
      return pane_id
    end
    return nil
  end
  return pane_id_field
end

local function read_pane_user_vars(pane)
  if not pane then
    return {}
  end
  local ok_field, getter = pcall(function() return pane.get_user_vars end)
  if not ok_field or type(getter) ~= 'function' then
    return {}
  end
  local ok, user_vars = pcall(getter, pane)
  return ok and type(user_vars) == 'table' and user_vars or {}
end

local function prompt_context_from_user_vars(user_vars)
  local integrated = user_vars.shell_integration == 'on'
  local at_prompt = integrated and user_vars.shell_prompt == 'on'
  local shell = user_vars.shell_name
  if shell == nil or shell == '' then
    shell = user_vars.clink == 'on' and 'cmd' or user_vars.zsh == 'on' and 'zsh' or nil
  end
  return shell, at_prompt, integrated, user_vars
end

local function pane_prompt_context(pane)
  return prompt_context_from_user_vars(read_pane_user_vars(pane))
end

--------------CONTEXT-AWARE KEY ACTIONS--------------

--------------------------------------------------------------------------------
-- 'Ctrl-c' key has two roles:
--   KeyboardInterrupt if there is no selection
--   Copy to clipboard if selection is available

local action_ctrl_c = function(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if not sel or sel == '' then
    window:perform_action(send_key('c', 'CTRL'), pane)
  else
    window:perform_action(act.CopyTo 'ClipboardAndPrimarySelection', pane)
  end
end

--------------------------------------------------------------------------------
-- 'Ctrl-d' keeps native EOF/DeleteCharOrExit semantics. cmd.exe has no useful
-- Ctrl-D contract, so its prompt integration explicitly clears and exits.
local clear_cmd_line = act.Multiple {
  send_key('End'),
  send_key('Home', 'SHIFT'),
  send_key('Delete'),
}
local exit_cmd = act.Multiple {
  clear_cmd_line,
  act.SendString 'exit\r',
}

local action_exit_shell = function(window, pane)
  local shell, at_prompt = pane_prompt_context(pane)
  window:perform_action(shell == 'cmd' and at_prompt and exit_cmd or send_key('d', 'CTRL'), pane)
end

local function debug_section(context, data)
  return data and { context = context, data = data } or nil
end

--------------------------------------------------------------------------------
-- 'LEADER + l' logs pane snapshots, user vars, and local config info into the
-- debug overlay for quick diagnostics.

local action_log_debug_info = function(window, pane)
  local pane_info
  local ok_tab, tab = pcall(function() return pane:tab() end)
  if ok_tab and tab then
    local pane_id = get_pane_cache_id(pane)
    local ok_panes, panes = pcall(function() return tab:panes_with_info() end)
    for _, info in ipairs(ok_panes and panes or {}) do
      if get_pane_cache_id(info.pane) == pane_id then
        pane_info = info
        break
      end
    end
  end
  local ok_vars, user_vars = pcall(function() return pane:get_user_vars() end)
  local ok_metadata, metadata = pcall(function() return pane:get_metadata() end)
  local ok_alt, alt_screen = pcall(function() return pane:is_alt_screen_active() end)
  wezterm.log_info({
    debug_section('Pane info', pane_info),
    debug_section('Pane user vars', ok_vars and user_vars or nil),
    debug_section('Pane metadata', ok_metadata and metadata or nil),
    debug_section('Pane misc', {
      { field = 'alt screen', value = ok_alt and tostring(alt_screen) or 'unavailable' },
    }),
    debug_section('Local configuration', local_config),
  })
end

--------------------------------------------------------------------------------
-- Ctrl+Home/End and PageUp/PageDown switch between full-screen apps and
-- scrollback navigation.

local function choose_action(predicate, true_action, false_action)
  return function(window, pane)
    window:perform_action(predicate(pane) and true_action or false_action, pane)
  end
end

local function pane_is_alt_screen(pane)
  local ok, active = pcall(function() return pane:is_alt_screen_active() end)
  return ok and active == true
end

-- Inline fzf selectors never enter the alt screen, so they don't expose
-- alternate-screen ownership.  The zsh and Clink integrations flag them via
-- an OSC 1337 user var while fzf owns the pane; get_user_vars is an in-memory
-- read, safe on per-keystroke paths.
local function pane_fzf_active(pane, user_vars)
  return (user_vars or read_pane_user_vars(pane)).fzf == 'on'
end

-- Clink popups (Rex model/mode chooser, etc.) run inside cmd.exe's normal
-- screen and are not distinguishable from the line editor by terminal state.
-- The Clink side therefore flags popup ownership explicitly.
local function pane_clink_popup_active(pane, user_vars)
  return (user_vars or read_pane_user_vars(pane)).clink_popup == 'on'
end

local function pane_wants_raw_nav_keys(pane)
  if pane_is_alt_screen(pane) then
    return true
  end
  local user_vars = read_pane_user_vars(pane)
  if pane_fzf_active(pane, user_vars) or pane_clink_popup_active(pane, user_vars) then
    return true
  end
  local _shell, at_prompt, integrated = prompt_context_from_user_vars(user_vars)
  -- Only an authoritative local prompt turns these into scrollback actions.
  -- Commands, SSH/remote panes, and unknown integrations receive real keys.
  return not (integrated and at_prompt)
end

local function pane_has_shell(pane)
  local _shell, at_prompt, integrated = pane_prompt_context(pane)
  -- Unknown/remote panes get raw keys. Intercepting them as viewport actions
  -- loses remote shell history/navigation and is less safe than pass-through.
  return not integrated or at_prompt
end

local action_ctrl_home = choose_action(pane_wants_raw_nav_keys, send_key('Home', 'CTRL'), act.ScrollToTop)
local action_ctrl_end = choose_action(pane_wants_raw_nav_keys, send_key('End', 'CTRL'), act.ScrollToBottom)
local action_pageup = choose_action(pane_wants_raw_nav_keys, send_key('PageUp'), act.ScrollByPage(-0.5))
local action_pagedown = choose_action(pane_wants_raw_nav_keys, send_key('PageDown'), act.ScrollByPage(0.5))

-- 'Home'/'Up'/'Down' have two roles:
--   Send the usual line-start/history keys if a shell prompt is active
--   Scroll the viewport if the pane is running something else

local action_home = choose_action(pane_has_shell, send_key('Home'), act.ScrollToTop)
local action_up = choose_action(pane_has_shell, send_key('UpArrow'), act.ScrollByLine(-1))
local action_down = choose_action(pane_has_shell, send_key('DownArrow'), act.ScrollByLine(1))

--------------------------------------------------------------------------------
-- Clear screen action

local action_clear_screen = function(window, pane)
  window:perform_action(send_key('l', 'CTRL'), pane)
end

--------------PROCESS AND PANE TERMINATION--------------

-- Windows-only escape hatch for a wedged foreground process. This synchronous
-- process query is intentionally confined to the explicit kill keystroke; it
-- is never called by paint/status/navigation paths.
local function get_windows_kill_target(pane)
  local ok, info = pcall(function() return pane:get_foreground_process_info() end)
  if not ok or type(info) ~= 'table' or type(info.pid) ~= 'number' or info.pid < 1 then
    return nil
  end
  return {
    pid = info.pid,
    name = type(info.name) == 'string' and info.name:lower() or '',
    executable = type(info.executable) == 'string' and info.executable:lower() or '',
    -- Compare the raw value only. Its epoch/unit varies by platform, but
    -- equality across two Windows queries is sufficient to reject PID reuse.
    start_time = info.start_time,
  }
end

local function same_windows_kill_target(left, right)
  if not left or not right or left.pid ~= right.pid then
    return false
  end
  if left.start_time ~= nil and right.start_time ~= nil
      and left.start_time ~= right.start_time then
    return false
  end
  if left.executable ~= '' and right.executable ~= ''
      and left.executable ~= right.executable then
    return false
  end
  return left.name == '' or right.name == '' or left.name == right.name
end

local function background_windows_taskkill(target, force)
  if not target or type(target.pid) ~= 'number' or target.pid < 1 then
    return false
  end
  local args = { 'taskkill.exe', '/PID', tostring(target.pid), '/T' }
  if force then
    args[#args + 1] = '/F'
  end
  local ok, err = pcall(wezterm.background_child_process, args)
  if not ok then
    log_warn_rate_limited('windows-taskkill', 'Failed to launch taskkill: ' .. tostring(err))
    return false
  end
  return true
end

local action_kill_process = function(window, pane)
  if not is_windows then
    window:perform_action(send_key('c', 'CTRL'), pane)
    return
  end

  local shell, at_prompt = pane_prompt_context(pane)
  if shell and at_prompt then
    -- Do not destroy an idle integrated shell by accident.
    window:perform_action(send_key('c', 'CTRL'), pane)
    return
  end

  local target = get_windows_kill_target(pane)
  if not target or not background_windows_taskkill(target, false) then
    window:perform_action(send_key('c', 'CTRL'), pane)
    return
  end

  -- Capture only the pane id across the delay. Holding the pane userdata is
  -- unsafe: if the pane dies before the timer fires, method calls on it abort
  -- the timer's coroutine outside any pcall ("cannot resume dead coroutine").
  local pane_id = get_pane_cache_id(pane)
  if type(pane_id) ~= 'number' then
    -- Cannot re-verify the target later; the graceful kill was already sent,
    -- so skip the forced follow-up rather than escalate blindly.
    return
  end

  wezterm.time.call_after(0.5, function()
    local ok, err = pcall(function()
      local ok_pane, live_pane = pcall(wezterm.mux.get_pane, pane_id)
      if not ok_pane or not live_pane then
        -- Pane closed during the delay: nothing to verify, do not force-kill.
        return
      end
      local current = get_windows_kill_target(live_pane)
      if same_windows_kill_target(target, current) then
        background_windows_taskkill(target, true)
      end
    end)
    if not ok then
      log_warn_rate_limited('windows-taskkill-follow-up', 'Failed to run taskkill follow-up: ' .. tostring(err))
    end
  end)
end

--------------------------------------------------------------------------------
-- Pane destruction is explicit and confirmed. Avoid a second CLI process: it
-- can attach to a different GUI/class where pane ids may collide.
local action_kill_pane = function(window, pane)
  window:perform_action(wezterm.action.CloseCurrentPane { confirm = true }, pane)
end

-- Resolve only an unambiguous target. Never paste or zoom an arbitrary first
-- alt-screen pane when several applications could receive the action.
local function find_alt_screen_target_pane(tab, current_pane)
  if not tab then
    return nil, nil, 'missing'
  end
  local current_pane_id = get_pane_cache_id(current_pane)
  local candidates = {}
  local ok, panes = pcall(function() return tab:panes_with_info() end)
  if not ok or type(panes) ~= 'table' then
    log_warn_rate_limited('alt-pane-list', 'Failed to enumerate panes: ' .. tostring(panes))
    return nil, nil, 'unavailable'
  end
  for _, pane_info in ipairs(panes) do
    local candidate = pane_info.pane
    if pane_is_alt_screen(candidate) then
      if get_pane_cache_id(candidate) == current_pane_id then
        return candidate, pane_info
      end
      candidates[#candidates + 1] = { pane = candidate, info = pane_info }
    end
  end
  if #candidates == 1 then
    return candidates[1].pane, candidates[1].info
  end
  return nil, nil, #candidates > 1 and 'ambiguous' or 'missing'
end

--------------------------------------------------------------------------------
-- 'Ctrl + Alt + ;' toggles the zoom state of the pane running alt-screen.

local action_alt_pane_toggle_zoom = function(window, pane)
  local ok_tab, tab = pcall(function() return window:active_tab() end)
  if not ok_tab or not tab then return end
  local target_pane, pane_info, reason = find_alt_screen_target_pane(tab, pane)
  if not target_pane or not pane_info then
    if reason == 'ambiguous' then
      log_warn_rate_limited('alt-pane-zoom-ambiguous', 'Refusing to zoom: multiple alt-screen panes are eligible')
    end
    return
  end
  local ok, err = pcall(function()
    target_pane:activate()
    tab:set_zoomed(not pane_info.is_zoomed)
  end)
  if not ok then
    log_warn_rate_limited('alt-pane-zoom', 'Failed to toggle alt-pane zoom: ' .. tostring(err))
  end
end

--------------ESCAPE BEHAVIOR--------------
-- 'Esc' is context-sensitive: clear the current line when possible, but still
-- behave like a real terminal Escape for full-screen apps and overlays.

local plain_escape = act.SendKey{ key='Escape' }
local fzf_escape = act.SendKey{ key='g', mods='CTRL' }
-- ConPTY holds a bare \x1b as a possible escape-sequence prefix, so a
-- synthesized plain Escape never reaches console apps as VK_ESCAPE. Encode
-- the press as explicit win32-input-mode key events (CSI Vk;Sc;Uc;Kd;Cs;Rc _),
-- which ConPTY translates deterministically into VK_ESCAPE INPUT_RECORDs —
-- what Clink's popups actually listen for.
local win32_escape = act.SendString '\x1b[27;1;27;1;0;1_\x1b[27;1;27;0;0;1_'
local clear_shell_line = act.SendString '\x01\x0b'
local action_Esc = function(window, pane)
  if window:leader_is_active() then
    window:perform_action(plain_escape, pane)
    return
  end
  local shell, at_prompt, integrated, user_vars = pane_prompt_context(pane)
  if pane_fzf_active(pane, user_vars) then
    -- Explicit signal from the shell's fzf wrapper; Ctrl-G is fzf's abort key
    -- and works through native Windows, WSL, and MSYS terminal boundaries.
    window:perform_action(fzf_escape, pane)
  elseif pane_clink_popup_active(pane, user_vars) then
    -- a Clink popup (e.g. Rex selector) owns the pane; an Escape key event
    -- must reach it instead of the cmd line-clear sequence below
    window:perform_action(win32_escape, pane)
  elseif pane_is_alt_screen(pane) then
    window:perform_action(plain_escape, pane)
  elseif integrated and at_prompt and shell == 'cmd' then
    window:perform_action(clear_cmd_line, pane)
  elseif integrated and at_prompt then
    window:perform_action(clear_shell_line, pane)
  else
    -- Unknown and remote panes are pass-through. Never infer a shell from a
    -- process name or scrape the visible line to decide what Escape means.
    window:perform_action(plain_escape, pane)
  end
end

-- Send selected text to the pane running alt-screen, e.g. terminal selection
-- into Neovim copy-mode or a full-screen TUI.
local action_send_to_alt_pane = function(window, pane)
  local text = window:get_selection_text_for_pane(pane)
  if not text or text == '' then return end
  local ok_tab, tab = pcall(function() return window:active_tab() end)
  if not ok_tab or not tab then return end
  local target_pane, _pane_info, reason = find_alt_screen_target_pane(tab, pane)
  if not target_pane then
    if reason == 'ambiguous' then
      log_warn_rate_limited('alt-pane-paste-ambiguous', 'Refusing to paste: multiple alt-screen panes are eligible')
    end
    return
  end
  local ok, err = pcall(function() target_pane:send_paste(text) end)
  if not ok then
    log_warn_rate_limited('alt-pane-paste', 'Failed to send protected paste: ' .. tostring(err))
    return
  end
  pcall(target_pane.activate, target_pane)
end

--------------KEY TABLES AND BINDINGS--------------

-- Key tables stack icons - clear, add, pop.
local key_icons_by_window = {}
local key_icons_last_seen = {}
local function get_key_icons_stack(window)
  if not window then
    return {}
  end
  local window_id = window:window_id()
  key_icons_last_seen[window_id] = clock_seconds()
  local stack = key_icons_by_window[window_id]
  if not stack then
    stack = {}
    key_icons_by_window[window_id] = stack
  end
  return stack
end

local function clear_key_icons_stack(window)
  local window_id = window:window_id()
  key_icons_by_window[window_id] = {}
  key_icons_last_seen[window_id] = clock_seconds()
end

local function pop_key_icons_stack(window)
  table.remove(get_key_icons_stack(window))
end

local function push_key_icon(icon)
  return function(window)
    local stack = get_key_icons_stack(window)
    stack[#stack + 1] = icon
  end
end

local add_term_key_icon = push_key_icon(wezterm.nerdfonts.cod_terminal)
local add_nvim_key_icon = push_key_icon(wezterm.nerdfonts.custom_neovim)
config.keys = {
  { key = 'F1', mods = 'NONE', action = act.ShowDebugOverlay },
  { key = 'F2', mods = 'NONE', action = act.ShowLauncher },
  { key = 'F3', mods = 'NONE', action = act.ShowTabNavigator },
  { key = 'F4', mods = 'NONE', action = act.ActivateCommandPalette },
  { key = 'F5', mods = 'NONE', action = act.CharSelect{ group = 'SmileysAndEmotion' } },
  { key = 'F6', mods = 'NONE', action = act.CharSelect{ group = 'Objects' } },
  { key = 'F7', mods = 'NONE', action = act.CharSelect{ group = 'Symbols' } },
  { key = 'F8', mods = 'NONE', action = act.CharSelect{ group = 'UnicodeNames' } },
  { key = 'd', mods = 'CTRL', action = cb(action_exit_shell) },
  { key = 'k', mods = 'LEADER', action = cb(action_kill_process) },
  { key = 'x', mods = 'LEADER', action = cb(action_kill_pane) },
  { key = 'l', mods = 'LEADER', action = cb(action_log_debug_info) },
  { key = 'Home', mods = 'CTRL', action = cb(action_ctrl_home) },
  { key = 'End', mods = 'CTRL', action = cb(action_ctrl_end) },
  { key = 'PageUp', mods = 'NONE', action = cb(action_pageup) },
  { key = 'PageDown', mods = 'NONE', action = cb(action_pagedown) },
  { key = 'Escape', mods = 'NONE', action = cb(action_Esc) },
  { key = 'l', mods = 'CTRL', action = cb(action_clear_screen) },
  { key = 't', mods = 'CTRL|ALT', action = act.SpawnTab 'DefaultDomain' },
  { key = 'y', mods = 'CTRL|ALT', action = act.SpawnTab 'CurrentPaneDomain' },
  { key = 'Tab', mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },
  { key = 'Tab', mods = 'CTRL', action = act.ActivateTabRelative(1) },
  { key = '\'', mods = 'CTRL|ALT', action = act.TogglePaneZoomState },
  { key = ';', mods = 'CTRL|ALT', action = cb(action_alt_pane_toggle_zoom) },

  -- Key mappings for KeyTable stack and actions.
  {
    key = '0',
    mods = 'CTRL|ALT',
    action = act.Multiple { act.ClearKeyTableStack, cb(clear_key_icons_stack) },
  },
  {
    key = '-',
    mods = 'CTRL|ALT',
    action = act.Multiple { act.PopKeyTable, cb(pop_key_icons_stack) },
  },
  {
    key = '9',
    mods = 'CTRL|ALT',
    action = act.Multiple {
      act.ActivateKeyTable { name = 'term', one_shot = false },
      cb(add_term_key_icon),
    },
  },
  {
    key = '8',
    mods = 'CTRL|ALT',
    action = act.Multiple {
      act.ActivateKeyTable { name = 'nvim', one_shot = false },
      cb(add_nvim_key_icon),
    },
  },
}

-- Send clean F keys to shell, e.g. for Midnight Commander.
for f = 1, 12 do
  local key = 'F' .. tostring(f)
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
  for k = 1,9 do
    table.insert(config.keys, {
      key = tostring(k),
      mods = 'CTRL',
      action = send_key(tostring(k), 'CTRL'),
    })
  end

  -- Cursor Home/End plus half-page Up/Down. Send logical keys so WezTerm uses
  -- the active terminal keyboard protocol rather than hard-coded SS3 bytes.
  table.insert(config.keys, { key = 'LeftArrow',  mods = 'SUPER', action = send_key('Home') })
  table.insert(config.keys, { key = 'DownArrow',  mods = 'SUPER', action = act.ScrollByPage(0.5) })
  table.insert(config.keys, { key = 'UpArrow',    mods = 'SUPER', action = act.ScrollByPage(-0.5) })
  table.insert(config.keys, { key = 'RightArrow', mods = 'SUPER', action = send_key('End') })
end

-- Apply local key binds last so machine-specific overrides can win.
if local_config.keys ~= nil and type(local_config.keys) ~= 'table' then
  wezterm.log_warn('wezterm_local.keys must be a table; ignoring local key bindings')
elseif local_config.keys then
  for _, v in ipairs(local_config.keys) do
    table.insert(config.keys, v)
  end
end

-- Send selected text to the active alt-screen pane, e.g. terminal selection to
-- Neovim or another full-screen TUI.
if wezterm.gui then
  local copy_mode = wezterm.gui.default_key_tables().copy_mode
  table.insert(copy_mode, { key = 'Enter', mods = 'CTRL', action = cb(action_send_to_alt_pane) })
  config.key_tables['copy_mode'] = copy_mode
end

-- Ctrl+wheel scrolls line-by-line for precise viewport movement.
config.mouse_bindings = {
  {
    event = { Down = { streak = 1, button = { WheelUp = 1 } } },
    mods = 'CTRL',
    action = act.ScrollByLine(-1),
  },
  {
    event = { Down = { streak = 1, button = { WheelDown = 1 } } },
    mods = 'CTRL',
    action = act.ScrollByLine(1),
  },
}

--------------STATUS AND TAB TITLES--------------
-- Top left & right status bar.

local format_left_status = function(window, pane)
  return wezterm.format({
    { Foreground = { Color = window:leader_is_active() and '#FF6060' or '#000000' } },
    { Text = wezterm.nerdfonts.md_lightning_bolt },
  })
end

local tab_title_cache = {}
local tab_title_settle = {}
local display_cwd_cache = {}
local command_runtime_state = {}
local committed_user_vars_cache = {}
local pane_last_seen = {}
local refresh_window_status

local function safe_method(object, method, fallback, expected_type)
  if not object then
    return fallback
  end
  local ok_field, fn = pcall(function() return object[method] end)
  if not ok_field or type(fn) ~= 'function' then
    return fallback
  end
  local ok, value = pcall(fn, object)
  if ok and (not expected_type or type(value) == expected_type) then
    return value
  end
  return fallback
end

local function get_pane_user_vars(pane)
  local pane_id = get_pane_cache_id(pane)
  if pane_id ~= nil and committed_user_vars_cache[pane_id] then
    return committed_user_vars_cache[pane_id]
  end
  -- Bootstrap after a config reload. Subsequent shell transitions are copied
  -- only on state_serial, so automatic per-variable update-status events keep
  -- rendering the previous coherent state rather than intermediate fields.
  local user_vars = {}
  for name, value in pairs(read_pane_user_vars(pane)) do
    user_vars[name] = value
  end
  if pane_id ~= nil and type(user_vars.state_serial) == 'string' and user_vars.state_serial ~= '' then
    committed_user_vars_cache[pane_id] = user_vars
  end
  return user_vars
end

local function normalize_cwd_value(cwd)
  if not cwd then
    return ''
  end
  if type(cwd) == 'string' then
    return normalize_path(cwd)
  end
  local ok_path, file_path = pcall(function() return cwd.file_path end)
  if ok_path and type(file_path) == 'string' then
    return normalize_path(file_path)
  end
  return normalize_path(tostring(cwd))
end

-- Only call this after an integration has emitted OSC 7 and then cwd_ready.
-- That ordering guarantees an in-memory terminal URI and prevents WezTerm's
-- get_current_working_dir fallback from scanning operating-system processes.
local function refresh_display_cwd(pane)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then
    return ''
  end
  pane_last_seen[pane_id] = clock_seconds()
  local ok_field, getter = pcall(function() return pane.get_current_working_dir end)
  if not ok_field or type(getter) ~= 'function' then
    local value = display_cwd_cache[pane_id] and display_cwd_cache[pane_id].value or ''
    display_cwd_cache[pane_id] = { value = value, last_seen = clock_seconds() }
    return value
  end
  local ok, cwd = pcall(getter, pane)
  if not ok then
    if not is_stale_mux_object_error(cwd) then
      log_warn_rate_limited('cwd', 'Failed to read OSC-reported cwd: ' .. tostring(cwd))
    end
    local value = display_cwd_cache[pane_id] and display_cwd_cache[pane_id].value or ''
    display_cwd_cache[pane_id] = { value = value, last_seen = clock_seconds() }
    return value
  end
  local value = normalize_cwd_value(cwd)
  -- Cache even an empty terminal URI. The next cwd_ready event retries, while
  -- ordinary status paints remain strictly memory-only.
  display_cwd_cache[pane_id] = { value = value, last_seen = clock_seconds() }
  return value
end

local function get_display_cwd(pane, user_vars)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then
    return ''
  end
  local cached = display_cwd_cache[pane_id]
  if not cached and type(user_vars.cwd_ready) == 'string' and user_vars.cwd_ready ~= '' then
    return refresh_display_cwd(pane)
  end
  if cached then
    cached.last_seen = clock_seconds()
    return cached.value
  end
  return ''
end

local function append_format_item(items, color, text)
  if text == nil then
    return
  end
  text = tostring(text)
  if text == '' then
    return
  end
  if type(color) == 'string' and color ~= '' then
    table.insert(items, { Foreground = { Color = color } })
  end
  table.insert(items, { Text = text })
end

local function toggle_color(status)
  return status == 'on' and '#AF8461' or status == 'off' and '#6A946A' or '#666666'
end

local function format_elapsed_time(elapsed_seconds)
  if elapsed_seconds == nil then
    return ''
  end
  elapsed_seconds = math.max(0, math.floor(elapsed_seconds))
  local days = math.floor(elapsed_seconds / 86400)
  local hours = math.floor(elapsed_seconds / 3600) % 24
  local minutes = math.floor(elapsed_seconds / 60) % 60
  local seconds = elapsed_seconds % 60
  return (days > 0 and days..'d' or '') .. string.format('%02d:%02d:%02d', hours, minutes, seconds)
end

local function normalize_process_label(label)
  if type(label) ~= 'string' then
    return nil
  end
  label = label:match('^%s*(.-)%s*$') or ''
  if label == '' then
    return nil
  end
  label = get_basename(label) or label
  label = label:lower():gsub('%.exe$', '')
  return label ~= '' and label or nil
end

local function get_display_process_name(user_vars, pane_title)
  if user_vars.nvim == 'on' then
    return 'nvim'
  end
  return normalize_process_label(user_vars.process_name)
    or normalize_process_label(user_vars.shell_name)
    or normalize_process_label(pane_title)
end

local function get_command_elapsed(pane_id, user_vars)
  local token = type(user_vars.command_token) == 'string' and user_vars.command_token or ''
  if token == '' or user_vars.shell_prompt == 'on' then
    command_runtime_state[pane_id] = nil
    return nil
  end
  local now = clock_seconds()
  local state = command_runtime_state[pane_id]
  if not state or state.token ~= token then
    state = { token = token, started = now, last_seen = now }
    command_runtime_state[pane_id] = state
  else
    state.last_seen = now
  end
  return now - state.started
end

local function format_right_status(window, pane)
  local user_vars = get_pane_user_vars(pane)
  local pane_id = get_pane_cache_id(pane)
  local cwd = get_display_cwd(pane, user_vars)
  local key_icons = get_key_icons_stack(window)
  local elapsed = pane_id and get_command_elapsed(pane_id, user_vars) or nil
  local running_time = format_elapsed_time(elapsed)
  if pane_id then
    pane_last_seen[pane_id] = clock_seconds()
  end

  local items = {}
  append_format_item(items, 'Yellow', table.concat(key_icons, ' '))
  append_format_item(items, '#4488FF', (#key_icons > 0) and ' '..wezterm.nerdfonts.md_arrow_expand_left..'    ' or '')
  append_format_item(items, '#BBBBBB', cwd ~= '' and (wezterm.truncate_left(cwd, 60)..'      ') or '')
  append_format_item(
    items,
    '#847EAE',
    safe_method(window, 'active_workspace', '', 'string')..' : '..safe_method(pane, 'get_domain_name', '', 'string')..'    '
  )
  append_format_item(items, toggle_color(user_vars.clink), wezterm.nerdfonts.md_alpha_c..' ')
  append_format_item(items, toggle_color(user_vars.zsh), wezterm.nerdfonts.md_alpha_z..' ')
  append_format_item(items, toggle_color(user_vars.nvim), wezterm.nerdfonts.custom_neovim..'    ')
  append_format_item(items, '#AB696F', running_time ~= '' and (running_time..'    ') or '')
  return wezterm.format(items)
end

local function set_status(window, setter, text, log_key)
  if not window then
    return
  end
  local ok_field, fn = pcall(function() return window[setter] end)
  if not ok_field or type(fn) ~= 'function' then
    return
  end
  local ok, err = pcall(fn, window, text)
  if not ok then
    log_warn_rate_limited(log_key, 'Failed to set ' .. setter .. ': ' .. tostring(err))
  end
end

refresh_window_status = function(window, pane)
  if not window then
    return
  end

  local ok_left, left_status = pcall(format_left_status, window, pane)
  if ok_left then
    set_status(window, 'set_left_status', left_status, 'left-status-set')
  else
    log_warn_rate_limited('left-status', 'Failed to format left status: ' .. tostring(left_status))
  end

  local ok_right, right_status = pcall(format_right_status, window, pane)
  if ok_right then
    set_status(window, 'set_right_status', right_status, 'right-status-set')
  else
    log_warn_rate_limited('right-status', 'Failed to format right status: ' .. tostring(right_status))
  end
end

wezterm.on('user-var-changed', function(window, pane, name, value)
  local pane_id = get_pane_cache_id(pane)
  if name == 'cwd_ready' and value ~= '' then
    refresh_display_cwd(pane)
    return
  end
  -- Shell/app producers emit state_serial last. Explicitly repaint only on
  -- that commit; automatic intermediate update-status events render the last
  -- committed snapshot rather than a partially updated state.
  if name ~= 'state_serial' then
    return
  end
  if pane_id ~= nil then
    local snapshot = {}
    for var_name, var_value in pairs(read_pane_user_vars(pane)) do
      snapshot[var_name] = var_value
    end
    committed_user_vars_cache[pane_id] = snapshot
    local cached = tab_title_cache[pane_id]
    if cached then
      cached.last_update = -math.huge
    end
  end
  refresh_window_status(window, pane)
end)

wezterm.on('window-focus-changed', function(window, pane)
  refresh_window_status(window, pane)
end)

-- Expire state incrementally by inactivity. Active/inactive live tabs are
-- touched by status/title formatting, so no synchronous mux.get_pane sweep is
-- needed on the GUI event thread.
local cache_prune_interval_seconds = 300
local cache_retention_seconds = 3600
local last_cache_prune = clock_seconds()

local function prune_inactive_cache_entries(now)
  for pane_id, last_seen in pairs(pane_last_seen) do
    if now - last_seen >= cache_retention_seconds then
      pane_last_seen[pane_id] = nil
      display_cwd_cache[pane_id] = nil
      tab_title_cache[pane_id] = nil
      tab_title_settle[pane_id] = nil
      command_runtime_state[pane_id] = nil
      committed_user_vars_cache[pane_id] = nil
    end
  end
  for window_id, last_seen in pairs(key_icons_last_seen) do
    if now - last_seen >= cache_retention_seconds then
      key_icons_last_seen[window_id] = nil
      key_icons_by_window[window_id] = nil
    end
  end
end

local committed_fields = {
  'shell_integration', 'shell_name', 'shell_prompt', 'process_name',
  'command_token', 'clink', 'zsh', 'nvim', 'cwd_ready', 'state_serial',
}

local function pane_state_is_committed(pane)
  local pane_id = get_pane_cache_id(pane)
  local committed = pane_id ~= nil and committed_user_vars_cache[pane_id] or nil
  if not committed then
    local live = read_pane_user_vars(pane)
    if live.shell_integration == 'on'
        and (type(live.state_serial) ~= 'string' or live.state_serial == '') then
      return false
    end
    return true
  end
  local live = read_pane_user_vars(pane)
  for _, name in ipairs(committed_fields) do
    if live[name] ~= committed[name] then
      return false
    end
  end
  return true
end

wezterm.on('update-status', function(window, pane)
  -- Each OSC user variable causes update-status. Skip formatting while a
  -- producer's batch differs from the last state_serial snapshot; the final
  -- commit callback performs one immediate coherent repaint.
  if pane_state_is_committed(pane) then
    refresh_window_status(window, pane)
  end
  local now = clock_seconds()
  if now - last_cache_prune >= cache_prune_interval_seconds then
    last_cache_prune = now
    prune_inactive_cache_entries(now)
  end
end)

local function get_pane_title_text(pane)
  local ok, title = pcall(function() return pane.title end)
  return ok and type(title) == 'string' and title or ''
end
-- Format tab title.
-- Tab titles consume PaneInformation snapshot fields and OSC user vars only;
-- they never resolve a mux pane or query the operating system.

local icons_names = {
  nvim       = { wezterm.nerdfonts.custom_neovim,    'Neovim' },
  bash       = { wezterm.nerdfonts.md_bash,          'bash' },
  gitbash    = { wezterm.nerdfonts.dev_git,          'git bash' },
  powershell = { wezterm.nerdfonts.seti_powershell,  'PS5' },
  pwsh       = { wezterm.nerdfonts.seti_powershell,  'PS7' },
  python     = { wezterm.nerdfonts.seti_python,      'Python' },
  python3    = { wezterm.nerdfonts.seti_python,      'Python' },
  ptpython   = { wezterm.nerdfonts.seti_python,      'PtPy' },
  cmd        = { wezterm.nerdfonts.cod_terminal,     'Cmd' },
  julia      = { wezterm.nerdfonts.seti_julia,       'Julia' },
  wslhost    = { wezterm.nerdfonts.linux_tux,        'WSL' },
  nu         = { wezterm.nerdfonts.md_chevron_right, 'Nu' },
  zsh        = { wezterm.nerdfonts.md_percent,       'zsh' },
}

-- Tab-title flicker guard: a foreground process name must persist for
-- tab_title_settle_seconds before it replaces the name shown on the tab, so a
-- short-lived command (git, ls, a sub-second build step) never flips the title.
-- Re-evaluated on each redraw and self-correcting: no timers, no callbacks.
local tab_title_settle_seconds = 1.0

local function settle_tab_title_name(pane_id, name)
  local state = tab_title_settle[pane_id]
  if not state then
    tab_title_settle[pane_id] = { shown = name, last_seen = clock_seconds() }
    return name
  end
  state.last_seen = clock_seconds()
  if name == state.shown then
    state.pending = nil
    return state.shown
  end
  if name ~= state.pending then
    state.pending = name
    state.pending_since = clock_seconds()
  elseif clock_seconds() - (state.pending_since or 0) >= tab_title_settle_seconds then
    state.shown = name
    state.pending = nil
    return name
  end
  return state.shown
end

-- A short reuse window avoids redundant string formatting across the two
-- format-tab-title passes while retaining the one-second anti-flicker settle.
local tab_title_reuse_seconds = 0.5

local function get_pane_info_user_vars(pane)
  local ok, user_vars = pcall(function() return pane.user_vars end)
  return ok and type(user_vars) == 'table' and user_vars or {}
end

local function get_tab_title_text(tab, max_width)
  local explicit_title = type(tab.tab_title) == 'string' and tab.tab_title or ''
  if explicit_title ~= '' then
    return wezterm.truncate_right(explicit_title, math.max(1, max_width or 1))
  end
  local pane = tab.active_pane
  local pane_id = get_pane_cache_id(pane)
  if not pane_id then
    return nil
  end
  local pane_title = type(pane.title) == 'string' and pane.title or get_pane_title_text(pane)
  local user_vars = committed_user_vars_cache[pane_id] or get_pane_info_user_vars(pane)
  local cached = tab_title_cache[pane_id]
  local now = clock_seconds()
  pane_last_seen[pane_id] = now
  if cached and cached.pane_title == pane_title
      and cached.process_name == user_vars.process_name
      and cached.shell_name == user_vars.shell_name
      and cached.nvim == user_vars.nvim
      and now - (cached.last_update or 0) < tab_title_reuse_seconds then
    return wezterm.truncate_right(cached.text, math.max(1, max_width or 1))
  end
  local name = get_display_process_name(user_vars, pane_title)
  if not name or name == '' then
    name = 'terminal'
  end
  name = settle_tab_title_name(pane_id, name)
  if cached and cached.name == name and cached.pane_title == pane_title then
    cached.process_name = user_vars.process_name
    cached.shell_name = user_vars.shell_name
    cached.nvim = user_vars.nvim
    cached.last_update = now
    return wezterm.truncate_right(cached.text, math.max(1, max_width or 1))
  end
  local title_prefix = pane_title:match('^Copy mode:') and 'Copy mode: ' or ''
  local icon_name = icons_names[name] or { '>', name }
  local text = title_prefix .. icon_name[1] .. ' ' .. icon_name[2] .. ' : ' .. pane_id
  tab_title_cache[pane_id] = {
    name = name,
    pane_title = pane_title,
    process_name = user_vars.process_name,
    shell_name = user_vars.shell_name,
    nvim = user_vars.nvim,
    text = text,
    last_update = now,
  }
  return wezterm.truncate_right(text, math.max(1, max_width or 1))
end

wezterm.on('format-tab-title', function(tab, tabs, panes, config, hover, max_width)
  local ok, result = pcall(get_tab_title_text, tab, max_width)
  if not ok then
    log_warn_rate_limited('tab-title', 'Failed to format tab title: ' .. tostring(result))
    result = nil
  end
  if result ~= nil then
    return result
  end
  -- Error or transient empty name: hold the last good title instead of
  -- dropping to WezTerm's default for a tick.
  local pane_id = get_pane_cache_id(tab.active_pane)
  local cached = pane_id and tab_title_cache[pane_id] or nil
  return cached and wezterm.truncate_right(cached.text, math.max(1, max_width or 1)) or nil
end)

local function refresh_spawned_window_status(mux_window, pane, delay_seconds)
  if not mux_window or not pane then
    return
  end
  -- Capture only plain ids across the delay. Userdata held over a timer can
  -- outlive its window/pane, and method calls on the dead object abort the
  -- timer's coroutine outside any pcall ("cannot resume dead coroutine").
  local ok_id, window_id = pcall(function() return mux_window:window_id() end)
  local pane_id = get_pane_cache_id(pane)
  if not ok_id or type(window_id) ~= 'number' or type(pane_id) ~= 'number' then
    return
  end
  wezterm.time.call_after(delay_seconds, function()
    local ok, err = pcall(function()
      local ok_win, live_window = pcall(wezterm.mux.get_window, window_id)
      local ok_pane, live_pane = pcall(wezterm.mux.get_pane, pane_id)
      if not ok_win or not live_window or not ok_pane or not live_pane then
        -- Window or pane closed during the delay: nothing left to refresh.
        return
      end
      local ok_gui, gui_window = pcall(live_window.gui_window, live_window)
      if ok_gui and gui_window and refresh_window_status then
        refresh_window_status(gui_window, live_pane)
      end
    end)
    if not ok then
      log_warn_rate_limited(
        'startup-status-refresh',
        'Failed to refresh startup status: ' .. tostring(err)
      )
    end
  end)
end

-- Startup window position is loaded from local configuration unless WezTerm
-- already supplied explicit startup args.

wezterm.on('gui-startup', function(cmd)
  local spawn = {}
  if cmd then
    for k, v in pairs(cmd) do
      spawn[k] = v
    end
  end
  if spawn.position == nil then
    spawn.position = clamp_window_position(get_configured_window_position())
  end
  local ok, _tab_or_error, pane, mux_window = pcall(wezterm.mux.spawn_window, spawn)
  if not ok then
    log_warn_rate_limited('startup-spawn', 'Failed to spawn startup window: ' .. tostring(_tab_or_error))
    return
  end
  refresh_spawned_window_status(mux_window, pane, 0.10)
  refresh_spawned_window_status(mux_window, pane, 0.40)
end)
return config

----------------------------------------------------------------------------
-- debugging goodies
--
-- get gui window, active pane, active pane title:
--
--     > wezterm['mux']['all_windows']()[1]:gui_window():active_pane():get_title()
