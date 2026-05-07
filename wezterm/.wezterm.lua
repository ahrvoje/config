local wezterm = require 'wezterm'
local act = wezterm.action
local cb = wezterm.action_callback
local is_windows = wezterm.target_triple:match('windows') ~= nil
local config = wezterm.config_builder()

-- Small helpers used throughout the config.

local function send_key(key, mods)
  return act.SendKey { key = key, mods = mods or 'NONE' }
end

local warning_last_logged = {}
local function log_warn_rate_limited(key, message, interval_seconds)
  local now = os.time()
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
  initial_rows            = 32,
  initial_cols            = 120,
  animation_fps           = 1,
  cursor_blink_ease_in    = 'Constant',
  cursor_blink_ease_out   = 'Constant',
  max_fps                 = 60,
  scrollback_lines        = 50000,
  status_update_interval  = 300,
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

local function get_active_screen_bounds()
  if not wezterm.gui or type(wezterm.gui.screens) ~= 'function' then
    return nil
  end
  local ok, screens = pcall(wezterm.gui.screens)
  if not ok or type(screens) ~= 'table' then
    log_warn_rate_limited('screens', 'Failed to read screen bounds: ' .. tostring(screens))
    return nil
  end
  local screen = screens.active or screens.main or screens[1]
  if type(screen) ~= 'table' then
    return nil
  end
  if type(screen.x) ~= 'number' or type(screen.y) ~= 'number'
      or type(screen.width) ~= 'number' or type(screen.height) ~= 'number' then
    return nil
  end
  return screen
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
  local bounds = get_active_screen_bounds()
  if not bounds then
    return position
  end
  local visible_margin = 80
  local clamped = {}
  for k, v in pairs(position) do
    clamped[k] = v
  end
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
} do
  config[key] = configured_value(key)
end
-- local_config.keys applied after config.keys
-------------------------------------------------

config.adjust_window_size_when_changing_font_size = false
config.audible_bell = 'Disabled'
if is_windows then
  -- Keep CRLF paste behavior for cmd.exe/PowerShell, but let Unix platforms use
  -- their native/default newline handling.
  config.canonicalize_pasted_newlines = 'CarriageReturnAndLineFeed'
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

--------------PATH AND PROCESS HELPERS--------------

-- Equivalent to POSIX basename(3)
-- '/foo/bar'         -> 'bar'
-- '/foo/bar/'        -> ''
-- 'c:\\foo\\bar'     -> 'bar'
-- 'C:\\foo\\bar.exe' -> 'bar.exe'

local function get_basename(s)
  s = s:gsub('[/\\]+$', '')
  return s:match('([^/\\]+)$')
end

-- https://stackoverflow.com/questions/2235173/what-is-the-naming-standard-for-path-components
--   'C:\\a\\b\\file.tar.gz' -> 'file.tar'
--   '/a/b/file.txt'         -> 'file'
--   '/a/b/.bashrc'          -> '.bashrc'
--   '/a/b/dir/'             -> 'dir'

local function get_rootname(path)
  if not path then return nil end
  local base = get_basename(path)
  if not base then return nil end
  -- dotfile? treat as no extension
  if base:sub(1,1) == '.' then
    return base
  end
  -- find position before the LAST dot (if any)
  local idx = base:match('^.*()%.[^%.]*$')  -- capture index before final '.ext'
  if not idx then
    return base
  end
  return base:sub(1, idx-1)
end

local function join_path(dir, name)
  return dir .. (is_windows and '\\' or '/') .. name
end

local function file_exists(path)
  if type(path) ~= 'string' or path == '' then
    return false
  end
  local file = io.open(path, 'rb')
  if not file then
    return false
  end
  file:close()
  return true
end

-- Resolve the scripting binary robustly across native installs, macOS app
-- bundles, and Linux AppImage launches.
local function get_wezterm_cli_executable()
  local procinfo = wezterm.procinfo
  if procinfo and type(procinfo.pid) == 'function' and type(procinfo.executable_path_for_pid) == 'function' then
    local ok_pid, pid = pcall(procinfo.pid)
    if ok_pid and type(pid) == 'number' then
      local ok_path, path = pcall(procinfo.executable_path_for_pid, pid)
      if ok_path and type(path) == 'string' and path ~= '' then
        local base = get_basename(path)
        local cli_name = base and (
          base:lower() == 'wezterm-gui.exe' and 'wezterm.exe'
          or base:lower() == 'wezterm-gui' and 'wezterm'
          or nil
        )
        if cli_name then
          local sibling = join_path(wezterm.executable_dir, cli_name)
          if file_exists(sibling) then
            return sibling
          end
        end
        if file_exists(path) then
          return path
        end
      end
    end
  end
  local fallback = join_path(wezterm.executable_dir, is_windows and 'wezterm.exe' or 'wezterm')
  if file_exists(fallback) then
    return fallback
  end
  return is_windows and 'wezterm.exe' or 'wezterm'
end

-- normalize windows path by stripping URI scheme

local function normalize_path(path)
  if type(path) ~= 'string' then
    return ''
  end
  local npath = path
  npath = npath:gsub('^file:///', '')
  npath = npath:gsub('^file://', '')
  npath = npath:gsub('%%(%x%x)', function(h) return string.char(tonumber(h,16)) end)
  npath = npath:gsub('^/([A-Za-z]:)','%1')
  return npath
end

local function get_wsl_distribution_name(domain_name)
  if type(domain_name) ~= 'string' then
    return nil
  end
  return domain_name:match('^WSL:(.+)$')
end

local function get_mux_pane(pane)
  if not pane then
    return nil
  end
  if type(pane.mux_pane) == 'function' then
    local ok, mux_pane = pcall(pane.mux_pane, pane)
    if ok and mux_pane then
      return mux_pane
    end
  end
  local pane_id = type(pane.pane_id) == 'function' and pane:pane_id() or pane.pane_id
  if pane_id == nil then
    return pane
  end
  -- it's not mux pane, so get it
  local ok, mux_pane = pcall(wezterm.mux.get_pane, pane_id)
  if ok and mux_pane then
    return mux_pane
  end
  return pane
end

local function get_pane_cache_id(pane)
  if not pane then
    return nil
  end
  if type(pane.pane_id) == 'function' then
    local ok, pane_id = pcall(pane.pane_id, pane)
    if ok then
      return pane_id
    end
    return nil
  end
  return pane.pane_id
end

-- convert Windows to Unix time, Windows epoch date is Jan 01, 1601 - 134774 days before Unix
-- https://stackoverflow.com/questions/6161776/convert-windows-filetime-to-second-in-unix-linux
local windows_filetime_unix_epoch_delta = 134774 * 86400
local earliest_reasonable_process_start_time = 946684800   -- 2000-01-01
local latest_reasonable_process_start_skew = 86400

local function normalize_process_start_time(t)
  if type(t) ~= 'number' or t <= 0 then
    return nil
  end

  local seconds
  if t > 10000000000000000 then
    -- Windows FILETIME: 100ns ticks since 1601-01-01.
    seconds = math.floor(t / 10000000 - windows_filetime_unix_epoch_delta)
  elseif t > 1000000000000 then
    -- Unix milliseconds.
    seconds = math.floor(t / 1000)
  else
    -- Unix seconds, or an undocumented raw value. Validate below before use.
    seconds = math.floor(t)
  end

  local now = os.time()
  if seconds < earliest_reasonable_process_start_time or seconds > now + latest_reasonable_process_start_skew then
    return nil
  end

  local ok = pcall(os.date, '%Y', seconds)
  if not ok then
    return nil
  end
  return seconds
end

local process_info_cache = {}

-- Interactive key handling wants fresh process state; status rendering can
-- safely reuse a same-second cache to avoid repeated foreground-process lookups
-- without visibly freezing the elapsed timer.

local function query_process_name_fullname_cwd_pid_time_argv(pane)
  local mux_pane = get_mux_pane(pane)
  if not mux_pane then return end
  local ok, info = pcall(mux_pane.get_foreground_process_info, mux_pane)
  if not ok or type(info) ~= 'table' then return end
  local name = info.name
  local executable = info.executable
  if type(name) ~= 'string' or name == '' then return end
  if type(executable) ~= 'string' or executable == '' then
    executable = name
  end
  local process_time = normalize_process_start_time(info.start_time)
  local argv = type(info.argv) == 'table' and info.argv or nil
  local p_name = get_rootname(name:lower()) or name:lower()
  local f_name = executable:lower()
  return p_name, f_name, info.cwd, info.pid, process_time, argv
end
local function cache_process_info(pane, p_name, f_name, cwd, pid, process_time, argv)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil or not p_name or not f_name then
    return
  end
  process_info_cache[pane_id] = {
    name = p_name,
    ext = f_name,
    cwd = cwd,
    pid = pid,
    time = process_time,
    argv = argv,
    last_update = os.time(),
  }
end
local function get_cached_process_info(pane, max_age)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then
    return
  end
  local cached = process_info_cache[pane_id]
  if not cached then
    return
  end
  if max_age ~= nil and (os.time() - cached.last_update >= max_age) then
    return
  end
  return cached.name, cached.ext, cached.cwd, cached.pid, cached.time, cached.argv
end
local function get_process_name_fullname_cwd_pid_time_argv(pane)
  local p_name, f_name, cwd, pid, process_time, argv = get_cached_process_info(pane, 1)
  if p_name and f_name then
    return p_name, f_name, cwd, pid, process_time, argv
  end
  p_name, f_name, cwd, pid, process_time, argv =
    query_process_name_fullname_cwd_pid_time_argv(pane)
  if not p_name or not f_name then
    return
  end
  cache_process_info(pane, p_name, f_name, cwd, pid, process_time, argv)
  return p_name, f_name, cwd, pid, process_time, argv
end

--------------------------------------------------------------------------------
-- Better shell detection
--   There is no reliable API to tell whether a shell is idle or whether some
--   child process has taken over the pane, so these heuristics are
--   intentionally conservative.
--   https://wezfurlong.org/wezterm/config/lua/config/skip_close_confirmation_for_processes_named.html
--   https://github.com/wez/wezterm/issues/562#issuecomment-803440418
--   https://github.com/wez/wezterm/issues/843

local function get_shell(process_name, fullname, argv)
  if not process_name or not fullname then return end
  local shells = {
    cmd = 1, bash = 2, powershell = 3, pwsh = 4, zsh = 5, tmux = 6,
    wslhost = 7, nu = 8, fish = 9, sh = 10, ksh = 11, dash = 12,
  }
  if process_name == 'bash' and fullname:match('git') then
    return 'gitbash'
  end
  if shells[process_name] then
    return process_name
  end
  if fullname:match('msys') and process_name:match('env') then
    return 'msys'
  end
  if not argv then
    return
  end
  if ((process_name == 'python') or (process_name == 'python3')) and (#argv == 1) then
    return 'python'
  end
  if ((process_name == 'python') or (process_name == 'python3')) and (#argv == 2) and (argv[2]:match('ptpython')) then
    return 'ptpython'
  end
  if (process_name == 'julia') and (#argv == 1) then
    return 'julia'
  end
end

local function get_pane_process_context(pane, allow_cached_fallback)
  local p_name, f_name, cwd, pid, process_time, argv =
    query_process_name_fullname_cwd_pid_time_argv(pane)
  if p_name and f_name then
    cache_process_info(pane, p_name, f_name, cwd, pid, process_time, argv)
  elseif allow_cached_fallback then
    p_name, f_name, cwd, pid, process_time, argv =
      get_cached_process_info(pane, 2)
  end
  if not p_name or not f_name then
    return
  end
  return p_name, f_name, cwd, pid, process_time, argv, get_shell(p_name, f_name, argv)
end

local function get_pane_shell(pane)
  local _, _, _, _, _, _, shell = get_pane_process_context(pane, true)
  return shell
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
-- 'Ctrl-d' closes a shell while taking care of special cases like PowerShell,
-- Python, ptpython, and cmd.exe.

local exit_shell_actions = {
  python     = act.SendString 'exit()\r',
  ptpython   = act.SendString 'exit()\n',
  powershell = act.SendString 'exit\r',
  pwsh       = act.SendString 'exit\r',
  cmd        = act.SendString '\x15exit\r',
}
local powershell_shells = { powershell = true, pwsh = true }

local action_exit_shell = function(window, pane)
  local _, _, _, _, _, _, shell = get_pane_process_context(pane, true)
  window:perform_action(exit_shell_actions[shell] or send_key('d', 'CTRL'), pane)
end

local function debug_section(context, data)
  return data and { context = context, data = data } or nil
end

--------------------------------------------------------------------------------
-- 'LEADER + l' logs current process, pane, and local config info into the
-- debug overlay for quick diagnostics.

local action_log_debug_info = function(window, pane)
  local pane_info
  local tab = pane:tab()
  if tab then
    local pane_id = pane:pane_id()
    for _, info in ipairs(tab:panes_with_info()) do
      if info.pane:pane_id() == pane_id then
        pane_info = info
        break
      end
    end
  end
  local ok, process_info = pcall(pane.get_foreground_process_info, pane)
  wezterm.log_info({
    debug_section('Process info', ok and process_info or nil),
    debug_section('Pane info', pane_info),
    debug_section('Pane user vars', pane:get_user_vars()),
    debug_section('Pane metadata', pane:get_metadata()),
    debug_section('Pane misc', {
      { field = 'alt screen', value = tostring(pane:is_alt_screen_active()) },
      { field = 'cwd',        value = tostring(pane:get_current_working_dir()) },
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
  return pane:is_alt_screen_active()
end

local function pane_has_shell(pane)
  return get_pane_shell(pane) ~= nil
end

local action_ctrl_home = choose_action(pane_is_alt_screen, send_key('Home', 'CTRL'), act.ScrollToTop)
local action_ctrl_end = choose_action(pane_is_alt_screen, send_key('End', 'CTRL'), act.ScrollToBottom)
local action_pageup = choose_action(pane_is_alt_screen, act.SendString '\x1b[5~', act.ScrollByPage(-0.5))
local action_pagedown = choose_action(pane_is_alt_screen, act.SendString '\x1b[6~', act.ScrollByPage(0.5))

-- 'Home'/'Up'/'Down' have two roles:
--   Send the usual line-start/history keys if a shell prompt is active
--   Scroll the viewport if the pane is running something else

local action_home = choose_action(pane_has_shell, send_key('Home'), act.ScrollToTop)
local action_up = choose_action(pane_has_shell, send_key('UpArrow'), act.ScrollByLine(-1))
local action_down = choose_action(pane_has_shell, send_key('DownArrow'), act.ScrollByLine(1))

--------------------------------------------------------------------------------
-- Clear screen action

local action_clear_screen = function(window, pane)
  local _, _, _, _, _, _, shell = get_pane_process_context(pane, true)
  window:perform_action(powershell_shells[shell] and act.SendString 'clear\r' or send_key('l', 'CTRL'), pane)
end

--------------PROCESS AND PANE TERMINATION--------------

-- Best-effort graceful process termination, followed by an escalation path if
-- the process ignores the first signal.
local function background_kill_process(domain_name, pid, force)
  if type(pid) ~= 'number' or pid < 1 then
    return false
  end
  local pid_text = tostring(pid)
  local distro_name = get_wsl_distribution_name(domain_name)
  local args = distro_name and { 'wsl.exe', '-d', distro_name, '--', 'kill' }
    or is_windows and { 'taskkill', '/PID', pid_text, '/T' }
    or { 'kill' }
  if force then
    table.insert(args, is_windows and not distro_name and '/F' or '-9')
  end
  if not is_windows or distro_name then
    table.insert(args, pid_text)
  end
  wezterm.background_child_process(args)
  return true
end

--------------------------------------------------------------------------------
-- 'LEADER + k' kills the foreground process in the pane.

local action_kill_process = function(window, pane)
  local process_name, fullname, _cwd, pid, process_time = get_pane_process_context(pane, false)
  if not process_name or type(pid) ~= 'number' or pid < 1 then
    return
  end
  local domain_name = pane:get_domain_name()
  if not background_kill_process(domain_name, pid, false) then
    return
  end
  wezterm.time.call_after(0.5, function()
    local ok, err = pcall(function()
      local ok_context, current_name, current_fullname, _current_cwd, current_pid, current_process_time =
        pcall(get_pane_process_context, pane, false)
      if not ok_context then
        log_warn_rate_limited('kill-process-refresh', 'Failed to re-check process before force kill: ' .. tostring(current_name))
        return
      end
      if process_time
          and current_pid == pid
          and current_process_time == process_time
          and current_name == process_name
          and current_fullname == fullname then
        background_kill_process(domain_name, pid, true)
      end
    end)
    if not ok then
      log_warn_rate_limited('kill-process-callback', 'Failed to run force-kill follow-up: ' .. tostring(err))
    end
  end)
end

--------------------------------------------------------------------------------
-- 'LEADER + x' closes the active pane, then follows up with a hard pane kill
-- if the graceful close did not finish.

local action_kill_pane = function(window, pane)
  local pane_id = get_pane_cache_id(pane)  -- capture now while pane is alive
  if pane_id == nil then
    return
  end
  window:perform_action(wezterm.action.CloseCurrentPane { confirm = false }, pane)
  wezterm.time.call_after(0.2, function()
    local ok, err = pcall(function()
      local ok_pane, current_pane = pcall(wezterm.mux.get_pane, pane_id)
      if not ok_pane or not current_pane then
        return
      end
      wezterm.background_child_process({
        get_wezterm_cli_executable(),
        'cli',
        'kill-pane',
        '--pane-id',
        tostring(pane_id),
      })
    end)
    if not ok then
      log_warn_rate_limited('kill-pane-callback', 'Failed to run pane-kill follow-up: ' .. tostring(err))
    end
  end)
end

-- Prefer the current alt-screen pane, then the active alt-screen pane, then
-- the first remaining alt-screen pane as a fallback.
local function find_alt_screen_target_pane(tab, current_pane)
  if not tab then
    return nil
  end
  local current_pane_id = current_pane and current_pane:pane_id() or nil
  local fallback_pane = nil
  local fallback_info = nil
  for _, pane_info in ipairs(tab:panes_with_info()) do
    local candidate = pane_info.pane
    if candidate:is_alt_screen_active() then
      if candidate:pane_id() == current_pane_id then
        return candidate, pane_info
      end
      if pane_info.is_active then
        return candidate, pane_info
      end
      if not fallback_pane then
        fallback_pane = candidate
        fallback_info = pane_info
      end
    end
  end
  return fallback_pane, fallback_info
end

--------------------------------------------------------------------------------
-- 'Ctrl + Alt + ;' toggles the zoom state of the pane running alt-screen.

local action_alt_pane_toggle_zoom = function(window, pane)
  local tab = window:active_tab()
  if not tab then return end
  local target_pane, pane_info = find_alt_screen_target_pane(tab, pane)
  if not target_pane or not pane_info then return end
  target_pane:activate()
  tab:set_zoomed(not pane_info.is_zoomed)
end

--------------ESCAPE BEHAVIOR--------------
-- 'Esc' is context-sensitive: clear the current line when possible, but still
-- behave like a real terminal Escape for full-screen apps and overlays.

local refresh_after_overlay_close

local function get_current_line_text(pane)
  local ok_dims, dims = pcall(pane.get_dimensions, pane)
  local ok_cursor, cursor = pcall(pane.get_cursor_position, pane)
  if ok_dims and dims and dims.cols and dims.cols > 0 and ok_cursor and cursor and type(cursor.y) == 'number' then
    local ok_region, text = pcall(
      pane.get_text_from_region,
      pane,
      0,
      cursor.y,
      dims.cols - 1,
      cursor.y
    )
    if ok_region and type(text) == 'string' then
      return text
    end
  end
  return nil
end

-- Very conservative line-empty detection: empty text or a prompt-like suffix.
local line_is_empty = function (pane)
  local text = get_current_line_text(pane) or ''
  text = text:gsub('%s+$', '')  -- trim trailing spaces
  if text == '' then
    return true
  end
  if text:match('[%%%]%$#>~]$') then
    return true
  end
  return false
end

local plain_escape = act.SendKey{ key='Escape' }
local terminal_escape = act.SendKey{ key='[', mods='CTRL' }
local fzf_escape = act.SendKey{ key='g', mods='CTRL' }
local clear_shell_line = act.SendString '\x01\x0b'
local clear_cmd_line = act.Multiple{
  act.SendKey{ key='End',  mods='NONE' },
  act.SendKey{ key='Home', mods='SHIFT' },
  act.SendKey{ key='Delete', mods='NONE' },
}
local clear_powershell_line = act.Multiple{
  act.SendKey{ key='Home', mods='CTRL' },
  act.SendKey{ key='End',  mods='CTRL' },
}

local action_Esc = function(window, pane)
  local process_name, _, _, _, _, _, shell = get_pane_process_context(pane, true)
  if window:leader_is_active() then
    window:perform_action(plain_escape, pane)
  elseif not process_name then
    window:perform_action(plain_escape, pane)
    if refresh_after_overlay_close then
      refresh_after_overlay_close(window)
    end
  elseif process_name == 'wslhost' or shell == 'msys' then
    local action = not pane:is_alt_screen_active() and not line_is_empty(pane) and clear_shell_line or terminal_escape
    window:perform_action(action, pane)
  elseif not shell then
    window:perform_action(process_name == 'fzf' and fzf_escape or terminal_escape, pane)
  elseif line_is_empty(pane) then
    window:perform_action(terminal_escape, pane)
  elseif shell == 'cmd' then
    window:perform_action(clear_cmd_line, pane)
  elseif powershell_shells[shell] then
    window:perform_action(clear_powershell_line, pane)
  else
    window:perform_action(clear_shell_line, pane)
  end
end

-- Send selected text to the pane running alt-screen, e.g. terminal selection
-- into Neovim copy-mode or a full-screen TUI.
local action_send_to_alt_pane = function(window, pane)
  local text = window:get_selection_text_for_pane(pane)
  if not text or text == '' then return end
  local tab = window:active_tab()
  if not tab then return end
  local target_pane = find_alt_screen_target_pane(tab, pane)
  if not target_pane then return end
  local ok = pcall(target_pane.send_paste, target_pane, text)
  if not ok then
    window:perform_action(act.SendString(text), target_pane)
  end
  target_pane:activate()
end

--------------KEY TABLES AND BINDINGS--------------

-- Key tables stack icons - clear, add, pop.
local key_icons_by_window = {}
local function get_key_icons_stack(window)
  if not window then
    return {}
  end
  local window_id = window:window_id()
  local stack = key_icons_by_window[window_id]
  if not stack then
    stack = {}
    key_icons_by_window[window_id] = stack
  end
  return stack
end

local function clear_key_icons_stack(window)
  key_icons_by_window[window:window_id()] = {}
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

  -- Cursor Home/End plus half-page Up/Down.
  table.insert(config.keys, { key = 'LeftArrow',  mods = 'SUPER', action = act.SendString '\x1bOH' })
  table.insert(config.keys, { key = 'DownArrow',  mods = 'SUPER', action = act.ScrollByPage(0.5) })
  table.insert(config.keys, { key = 'UpArrow',    mods = 'SUPER', action = act.ScrollByPage(-0.5) })
  table.insert(config.keys, { key = 'RightArrow', mods = 'SUPER', action = act.SendString '\x1bOF' })
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

local battery_cache = { data = nil, last_update = 0 }
local tab_title_cache = {}
local refresh_window_status

local function safe_method(object, method, fallback, expected_type)
  if not object or type(object[method]) ~= 'function' then
    return fallback
  end
  local ok, value = pcall(object[method], object)
  if ok and (not expected_type or type(value) == expected_type) then
    return value
  end
  return fallback
end

local function get_pane_user_vars(pane)
  if not pane or type(pane.get_user_vars) ~= 'function' then
    return {}
  end
  local ok, user_vars = pcall(pane.get_user_vars, pane)
  if ok and type(user_vars) == 'table' then
    return user_vars
  end
  if not is_stale_mux_object_error(user_vars) then
    log_warn_rate_limited('user-vars', 'Failed to read pane user vars: ' .. tostring(user_vars))
  end
  return {}
end

local function get_display_cwd(pane, process_cwd)
  if pane and type(pane.get_current_working_dir) == 'function' then
    local ok, cwd = pcall(pane.get_current_working_dir, pane)
    if ok and cwd then
      if type(cwd) == 'string' then
        return normalize_path(cwd)
      elseif cwd.file_path then
        return normalize_path(cwd.file_path)
      end
      return normalize_path(tostring(cwd))
    end
  end
  return normalize_path(process_cwd)
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

local empty_battery_status = {
  color = '',
  icon = '',
  text = '',
}

local function get_battery_status()
  local now = os.time()
  if battery_cache.data and (now - battery_cache.last_update < 60) then
    return battery_cache.data
  end

  local ok, info = pcall(wezterm.battery_info)
  if not ok or type(info) ~= 'table' or #info == 0 then
    if not ok then
      log_warn_rate_limited('battery-info', 'Failed to read battery info: ' .. tostring(info))
    end
    battery_cache.data = empty_battery_status
    battery_cache.last_update = now
    return battery_cache.data
  end

  local charge = tonumber(info[1] and info[1]['state_of_charge'])
  if not charge then
    battery_cache.data = empty_battery_status
    battery_cache.last_update = now
    return battery_cache.data
  end

  local color, icon
  if charge < 0.25 then
    color = 'Red'
    icon = wezterm.nerdfonts.md_battery_20
  elseif charge < 0.5 then
    color = 'Yellow'
    icon = wezterm.nerdfonts.md_battery_50
  else
    color = 'Green'
    icon = wezterm.nerdfonts.md_battery
  end

  battery_cache.data = {
    color = color,
    icon = icon,
    text = math.ceil(100 * charge) .. '%  ',
  }
  battery_cache.last_update = now
  return battery_cache.data
end

local function format_elapsed_time(process_time)
  if not process_time then
    return ''
  end
  local elapsed_seconds = math.max(0, os.time() - process_time)
  local days = math.floor(elapsed_seconds / 86400)
  local ok, time_text = pcall(os.date, '!%X', elapsed_seconds)
  if not ok or type(time_text) ~= 'string' then
    time_text = '00:00:00'
  end
  return (days > 0 and days..'d' or '')..time_text
end

local function get_pane_start_time(process_time)
  if not process_time then
    return '------------------------------'
  end
  local ok, date_text = pcall(os.date, '%b %d %X', process_time)
  if not ok or type(date_text) ~= 'string' then
    return '------------------------------'
  end
  return wezterm.nerdfonts.fa_clock..' '..date_text
end

local function get_running_color(process_name, shell, is_alt)
  if shell or not process_name or is_alt then
    return '#3D8AB1'
  end
  return '#AB696F'
end

local function format_right_status(window, pane)
  local process_name, fullname, process_cwd, _pid, process_time, argv =
    get_process_name_fullname_cwd_pid_time_argv(pane)
  local shell = get_shell(process_name, fullname, argv)
  local cwd = get_display_cwd(pane, process_cwd)
  local user_vars = get_pane_user_vars(pane)
  local battery_status = get_battery_status()
  local key_icons = get_key_icons_stack(window)
  local running_time = format_elapsed_time(process_time)
  local running_color = process_time and get_running_color(
    process_name,
    shell,
    safe_method(pane, 'is_alt_screen_active', false, 'boolean')
  ) or ''

  local items = {}
  append_format_item(items, 'Yellow', table.concat(key_icons, ' '))
  append_format_item(items, '#4488FF', (#key_icons > 0) and ' '..wezterm.nerdfonts.md_arrow_expand_left..'    ' or '')
  append_format_item(items, '#BBBBBB', cwd ~= '' and (cwd..'      ') or '')
  append_format_item(
    items,
    '#847EAE',
    safe_method(window, 'active_workspace', '', 'string')..' : '..safe_method(pane, 'get_domain_name', '', 'string')..'    '
  )
  append_format_item(items, toggle_color(user_vars.clink), wezterm.nerdfonts.md_alpha_c..' ')
  append_format_item(items, toggle_color(user_vars.zsh), wezterm.nerdfonts.md_alpha_z..' ')
  append_format_item(items, toggle_color(user_vars.nvim), wezterm.nerdfonts.custom_neovim..'    ')
  append_format_item(items, running_color, running_time ~= '' and (running_time..'    ') or '')
  append_format_item(items, battery_status.color, (battery_status.icon or '') .. (battery_status.text or ''))
  append_format_item(items, 'Gray', get_pane_start_time(process_time) .. '      ')
  return wezterm.format(items)
end

local function set_status(window, setter, text, log_key)
  if not window or type(window[setter]) ~= 'function' then
    return
  end
  local ok, err = pcall(window[setter], window, text)
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

local function get_window_active_pane(window)
  if not window or type(window.active_pane) ~= 'function' then
    return nil
  end
  local ok, pane = pcall(window.active_pane, window)
  if ok then
    return pane
  end
  log_warn_rate_limited('active-pane', 'Failed to read active pane: ' .. tostring(pane))
  return nil
end

local function clear_pane_status_cache(pane)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then
    return
  end
  process_info_cache[pane_id] = nil
  tab_title_cache[pane_id] = nil
end

local function refresh_after_overlay_delay(window, delay_seconds)
  wezterm.time.call_after(delay_seconds, function()
    local ok, err = pcall(function()
      local pane = get_window_active_pane(window)
      if not pane then
        return
      end
      clear_pane_status_cache(pane)
      refresh_window_status(window, pane)
    end)
    if not ok then
      log_warn_rate_limited('overlay-refresh-callback', 'Failed to refresh status after overlay closed: ' .. tostring(err))
    end
  end)
end

refresh_after_overlay_close = function(window)
  refresh_after_overlay_delay(window, 0.05)
  refresh_after_overlay_delay(window, 0.25)
end

wezterm.on('user-var-changed', function(window, pane)
  clear_pane_status_cache(pane)
  refresh_window_status(window, pane)
end)

wezterm.on('window-focus-changed', function(window, pane)
  refresh_window_status(window, pane)
end)

wezterm.on('update-status', function(window, pane)
  refresh_window_status(window, pane)
end)

local function get_pane_title_text(pane)
  if type(pane.title) == 'string' then
    return pane.title
  end
  local ok, title = pcall(pane.get_title, pane)
  if ok and type(title) == 'string' then
    return title
  end
  return ''
end

local function get_tab_title_process_name(pane)
  local process_path = type(pane.foreground_process_name) == 'string' and pane.foreground_process_name or nil
  if process_path and process_path ~= '' then
    local normalized = normalize_path(process_path):lower()
    local process_name = get_rootname(normalized) or get_basename(normalized)
    if process_name and process_name ~= '' then
      if process_name == 'bash' and normalized:match('git') then
        return 'gitbash'
      end
      if normalized:match('msys') and process_name:match('env') then
        return 'msys'
      end
      return process_name
    end
  end

  local process_name, fullname, _cwd, _pid, _process_time, argv =
    get_process_name_fullname_cwd_pid_time_argv(pane)
  return get_shell(process_name, fullname, argv) or process_name
end
-- Format tab title.
-- Tab titles mirror the foreground process with a cached icon/text pair.

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
local function get_tab_title_text(pane)
  local pane_id = get_pane_cache_id(pane)
  if not pane_id then
    return nil
  end
  local pane_title = type(pane.title) == 'string' and pane.title or get_pane_title_text(pane)
  local name = get_tab_title_process_name(pane)
  if not name or name == '' then
    return nil
  end
  local cached = tab_title_cache[pane_id]
  if cached and cached.name == name and cached.pane_title == pane_title then
    return cached.text
  end
  local title_prefix = pane_title:match('Copy mode:') and 'Copy mode: ' or ''
  local icon_name = icons_names[name] or { '>', name }
  local text = title_prefix .. icon_name[1] .. ' ' .. icon_name[2] .. ' : ' .. pane_id
  tab_title_cache[pane_id] = {
    name = name,
    pane_title = pane_title,
    text = text,
  }
  return text
end

wezterm.on('format-tab-title', function(tab, tabs, panes, config, hover, max_width)
  local ok, result = pcall(get_tab_title_text, tab.active_pane)
  if not ok then
    log_warn_rate_limited('tab-title', 'Failed to format tab title: ' .. tostring(result))
    local pane_id = get_pane_cache_id(tab.active_pane)
    local cached = pane_id and tab_title_cache[pane_id] or nil
    return cached and cached.text or nil
  end
  return result
end)

local function refresh_spawned_window_status(mux_window, pane, delay_seconds)
  if not mux_window or not pane then
    return
  end
  wezterm.time.call_after(delay_seconds, function()
    local ok, err = pcall(function()
      local ok_gui, gui_window = pcall(mux_window.gui_window, mux_window)
      if ok_gui and gui_window and refresh_window_status then
        refresh_window_status(gui_window, pane)
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
  local _, pane, mux_window = wezterm.mux.spawn_window(spawn)
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
--     > wezterm['mux']['all_windows']()[1]:gui_window():active_pane():get_foreground_process_info()
