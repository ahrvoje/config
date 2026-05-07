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

config.leader                 = configured_value('leader')
config.initial_rows           = configured_value('initial_rows')
config.initial_cols           = configured_value('initial_cols')
config.font                   = configured_value('font')
config.font_size              = configured_value('font_size')
config.front_end              = configured_value('front_end')
config.window_frame           = configured_value('window_frame')
config.launch_menu            = configured_value('launch_menu')
config.default_prog           = configured_value('default_prog')
config.animation_fps          = configured_value('animation_fps')
config.cursor_blink_ease_in   = configured_value('cursor_blink_ease_in')
config.cursor_blink_ease_out  = configured_value('cursor_blink_ease_out')
config.max_fps                = configured_value('max_fps')
config.scrollback_lines       = configured_value('scrollback_lines')
config.status_update_interval = configured_value('status_update_interval')
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

local action_exit_shell = function(window, pane)
  local _, _, _, _, _, _, shell = get_pane_process_context(pane, true)
  if shell == 'python' then
    window:perform_action(act.SendString 'exit()\r', pane)
  elseif shell == 'ptpython' then
    window:perform_action(act.SendString 'exit()\n', pane)
  elseif shell == 'powershell' or shell == 'pwsh' then
    window:perform_action(act.SendString 'exit\r', pane)
  elseif shell == 'cmd' then
    -- Ctrl-U clears line without executing, then exit
    window:perform_action(act.SendString '\x15exit\r', pane)
  else
    window:perform_action(send_key('d', 'CTRL'), pane)
  end
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

local action_ctrl_home = function(window, pane)
  if pane:is_alt_screen_active() then
    window:perform_action(send_key('Home', 'CTRL'), pane)
  else
    window:perform_action(act.ScrollToTop, pane)
  end
end

local action_ctrl_end = function(window, pane)
  if pane:is_alt_screen_active() then
    window:perform_action(send_key('End', 'CTRL'), pane)
  else
    window:perform_action(act.ScrollToBottom, pane)
  end
end

local action_pageup = function(window, pane)
  if pane:is_alt_screen_active() then
    window:perform_action(act.SendString '\x1b[5~', pane)  -- CSI PageUp
  else
    window:perform_action(act.ScrollByPage(-0.5), pane)
  end
end

local action_pagedown = function(window, pane)
  if pane:is_alt_screen_active() then
    window:perform_action(act.SendString '\x1b[6~', pane)  -- CSI PageDown
  else
    window:perform_action(act.ScrollByPage(0.5), pane)
  end
end

-- 'Home'/'Up'/'Down' have two roles:
--   Send the usual line-start/history keys if a shell prompt is active
--   Scroll the viewport if the pane is running something else

local action_home = function(window, pane)
  if get_pane_shell(pane) then
    window:perform_action(send_key('Home'), pane)
  else
    window:perform_action(act.ScrollToTop, pane)
  end
end

local action_up = function(window, pane)
  if get_pane_shell(pane) then
    window:perform_action(send_key('UpArrow'), pane)
  else
    window:perform_action(act.ScrollByLine(-1), pane)
  end
end

local action_down = function(window, pane)
  if get_pane_shell(pane) then
    window:perform_action(send_key('DownArrow'), pane)
  else
    window:perform_action(act.ScrollByLine(1), pane)
  end
end

--------------------------------------------------------------------------------
-- Clear screen action

local action_clear_screen = function(window, pane)
  local _, _, _, _, _, _, shell = get_pane_process_context(pane, true)
  if shell == 'powershell' or shell == 'pwsh' then
    window:perform_action(act.SendString( 'clear\r' ), pane)
  else
    window:perform_action(send_key('l', 'CTRL'), pane)
  end
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
  if distro_name then
    local args = { 'wsl.exe', '-d', distro_name, '--', 'kill' }
    if force then
      table.insert(args, '-9')
    end
    table.insert(args, pid_text)
    wezterm.background_child_process(args)
    return true
  end
  if is_windows then
    local args = { 'taskkill', '/PID', pid_text, '/T' }
    if force then
      table.insert(args, '/F')
    end
    wezterm.background_child_process(args)
    return true
  end
  local args = { 'kill' }
  if force then
    table.insert(args, '-9')
  end
  table.insert(args, pid_text)
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

local action_Esc = function(window, pane)
  local process_name, _, _, _, _, _, shell = get_pane_process_context(pane, true)
  if window:leader_is_active() then
    -- Cancel leader if active.
    window:perform_action(act.SendKey{ key='Escape' }, pane)
  elseif not process_name then
    -- Exit the wezterm overlay if it owns the pane.
    window:perform_action(act.SendKey{ key='Escape' }, pane)
    if refresh_after_overlay_close then
      refresh_after_overlay_close(window)
    end
  elseif process_name == 'wslhost' or shell == 'msys' then
    if not pane:is_alt_screen_active() and not line_is_empty(pane) then
      -- Clear the shell line without relying on a shell-specific binding.
      window:perform_action(act.SendString( '\x01\x0b' ), pane)
    else
      -- Full-screen app is active, so send a real Escape.
      window:perform_action(act.SendKey{ key='[', mods='CTRL' }, pane)
    end
  elseif not shell then
    if process_name == 'fzf' then
      -- fzf reliably accepts Ctrl+G even when bare Escape is awkward via ConPTY.
      window:perform_action(act.SendKey{ key='g', mods='CTRL' }, pane)
    else
      -- Ctrl+[ is the portable terminal trick for sending Escape (0x1B).
      window:perform_action(act.SendKey{ key='[', mods='CTRL' }, pane)
    end
  elseif shell == 'cmd' then
    if line_is_empty(pane) then
      -- Cmd with an empty line should still receive a real Escape.
      window:perform_action(act.SendKey{ key='[', mods='CTRL' }, pane)
    else
      window:perform_action(act.Multiple{
        act.SendKey{ key='End',  mods='NONE' },
        act.SendKey{ key='Home', mods='SHIFT' },
        act.SendKey{ key='Delete', mods='NONE' },
      }, pane)
    end
  elseif line_is_empty(pane) then
    -- Empty prompt line: send Escape rather than trying to clear it.
    window:perform_action(act.SendKey{ key='[', mods='CTRL' }, pane)
  elseif shell == 'pwsh' or shell == 'powershell' then
    -- PowerShell 5 and 7: Ctrl+Home / Ctrl+End clears both halves of the line.
    window:perform_action(act.Multiple{
      act.SendKey{ key='Home', mods='CTRL' },
      act.SendKey{ key='End',  mods='CTRL' },
    }, pane)
  else
    -- Bash/Zsh/etc.: Ctrl+A Ctrl+K clears the current line.
    window:perform_action(act.SendString( '\x01\x0b' ), pane)
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

local function add_term_key_icon(window)
  local stack = get_key_icons_stack(window)
  stack[#stack + 1] = wezterm.nerdfonts.cod_terminal
end

local function add_nvim_key_icon(window)
  local stack = get_key_icons_stack(window)
  stack[#stack + 1] = wezterm.nerdfonts.custom_neovim
end
config.keys = {
  { key = 'F1', mods = 'NONE', action = act.ShowDebugOverlay },
  { key = 'F2', mods = 'NONE', action = act.ShowLauncher },
  { key = 'F3', mods = 'NONE', action = act.ShowTabNavigator },
  { key = 'F4', mods = 'NONE', action = act.ActivateCommandPalette },
  { key = 'F5', mods = 'NONE', action = act.CharSelect{ group = 'SmileysAndEmotion' } },
  { key = 'F6', mods = 'NONE', action = act.CharSelect{ group = 'Objects' } },
  { key = 'F7', mods = 'NONE', action = act.CharSelect{ group = 'Symbols' } },
  { key = 'F8', mods = 'NONE', action = act.CharSelect{ group = 'UnicodeNames' } },

  -- Send clean F keys to shell, e.g. for Midnight Commander.
  { key = 'F1',  mods = 'CTRL|ALT', action = send_key('F1') },
  { key = 'F2',  mods = 'CTRL|ALT', action = send_key('F2') },
  { key = 'F3',  mods = 'CTRL|ALT', action = send_key('F3') },
  { key = 'F4',  mods = 'CTRL|ALT', action = send_key('F4') },
  { key = 'F5',  mods = 'CTRL|ALT', action = send_key('F5') },
  { key = 'F6',  mods = 'CTRL|ALT', action = send_key('F6') },
  { key = 'F7',  mods = 'CTRL|ALT', action = send_key('F7') },
  { key = 'F8',  mods = 'CTRL|ALT', action = send_key('F8') },
  { key = 'F9',  mods = 'CTRL|ALT', action = send_key('F9') },
  { key = 'F10', mods = 'CTRL|ALT', action = send_key('F10') },
  { key = 'F11', mods = 'CTRL|ALT', action = send_key('F11') },
  { key = 'F12', mods = 'CTRL|ALT', action = send_key('F12') },

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

  { key = 'LeftArrow',  mods = 'CTRL',     action = act.ActivatePaneDirection 'Left' },
  { key = 'DownArrow',  mods = 'CTRL',     action = act.ActivatePaneDirection 'Down' },
  { key = 'UpArrow',    mods = 'CTRL',     action = act.ActivatePaneDirection 'Up' },
  { key = 'RightArrow', mods = 'CTRL',     action = act.ActivatePaneDirection 'Right' },

  { key = 'LeftArrow',  mods = 'ALT',      action = act.AdjustPaneSize { 'Left', 1 } },
  { key = 'DownArrow',  mods = 'ALT',      action = act.AdjustPaneSize { 'Down', 1 } },
  { key = 'UpArrow',    mods = 'ALT',      action = act.AdjustPaneSize { 'Up', 1 } },
  { key = 'RightArrow', mods = 'ALT',      action = act.AdjustPaneSize { 'Right', 1 } },

  { key = 'LeftArrow',  mods = 'CTRL|ALT', action = act.SplitPane { direction = 'Left' } },
  { key = 'DownArrow',  mods = 'CTRL|ALT', action = act.SplitPane { direction = 'Down' } },
  { key = 'UpArrow',    mods = 'CTRL|ALT', action = act.SplitPane { direction = 'Up' } },
  { key = 'RightArrow', mods = 'CTRL|ALT', action = act.SplitPane { direction = 'Right' } },

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
local window_status_cache = {}
local tab_title_cache = {}
local pane_user_vars_cache = {}

local function get_window_status_state(window)
  local window_id = window:window_id()
  local state = window_status_cache[window_id]
  if not state then
    state = {}
    window_status_cache[window_id] = state
  end
  return state
end

local function clear_status_interval_override(window)
  if not window or not window.get_config_overrides or not window.set_config_overrides then
    return
  end
  local state = get_window_status_state(window)
  if state.cleared_status_interval_override then
    return
  end
  local ok_overrides, overrides = pcall(window.get_config_overrides, window)
  if not ok_overrides then
    log_warn_rate_limited('status-interval-override', 'Failed to read config overrides: ' .. tostring(overrides))
    return
  end
  overrides = overrides or {}
  if overrides.status_update_interval ~= nil then
    overrides.status_update_interval = nil
    local ok_set, err = pcall(window.set_config_overrides, window, overrides)
    if not ok_set then
      log_warn_rate_limited('status-interval-override', 'Failed to clear status interval override: ' .. tostring(err))
      return
    end
  end
  state.cleared_status_interval_override = true
end

-- User vars are event-driven, so cache them and let the event handler update
-- the copy instead of polling every status tick.
local function get_cached_user_vars(pane)
  if not pane then
    return {}
  end
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then
    local ok, user_vars = pcall(pane.get_user_vars, pane)
    if ok and type(user_vars) == 'table' then
      return user_vars
    end
    if not is_stale_mux_object_error(user_vars) then
      log_warn_rate_limited('user-vars', 'Failed to read pane user vars: ' .. tostring(user_vars))
    end
    return {}
  end
  local cached = pane_user_vars_cache[pane_id]
  if cached then
    return cached
  end
  local ok, user_vars = pcall(pane.get_user_vars, pane)
  if not ok or type(user_vars) ~= 'table' then
    if not is_stale_mux_object_error(user_vars) then
      log_warn_rate_limited('user-vars', 'Failed to read pane user vars: ' .. tostring(user_vars))
    end
    user_vars = {}
  end
  pane_user_vars_cache[pane_id] = user_vars
  return user_vars
end

local function toggle_color(status)
  return status == 'on' and '#AF8461' or status == 'off' and '#6A946A' or '#666666'
end

local empty_battery_status = {
  color = '',
  icon = '',
  text = '',
}

-- Cache battery sampling; some desktops have no battery at all.
local function get_battery_status()
  local now = os.time()
  if battery_cache.data and (now - battery_cache.last_update < 60) then
    return battery_cache.data
  end
  local ok, info = pcall(wezterm.battery_info)
  if not ok or type(info) ~= 'table' then
    log_warn_rate_limited('battery-info', 'Failed to read battery info: ' .. tostring(info))
    battery_cache.data = battery_cache.data or empty_battery_status
    battery_cache.last_update = now
    return battery_cache.data
  end
  if #info == 0 then
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
  local color, icon, text
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
  text = math.ceil(100 * charge) .. '%  '
  battery_cache.data = {
    color = color,
    icon  = icon,
    text  = text,
  }
  battery_cache.last_update = now
  return battery_cache.data
end

local pane_start_time_cache = {}
local stable_display_delay_seconds = 0.5
local pane_status_cwd_cache = {}
local pane_process_display_cache = {}
local tab_title_process_name_cache = {}
local tab_title_snapshot_max_age_seconds = 5
local fallback_process_start_by_pane = {}

-- Async pane snapshot. The slow process/cwd queries run in a refresher
-- scheduled via wezterm.time.call_after, so the status formatter and tab
-- title formatter only ever read cached values and the timer tick stays
-- snappy regardless of how long get_foreground_process_info takes.
local pane_snapshot_cache = {}
local pane_refresh_pending = {}
local pane_refresh_pending_since = {}
local snapshot_min_age_seconds = 1
local snapshot_pending_recover_seconds = 5
local cache_prune_last_update = 0
local cache_prune_interval_seconds = 60
local refresh_window_status

local function collect_live_cache_ids()
  local live_panes = {}
  local live_windows = {}
  local ok_windows, mux_windows = pcall(wezterm.mux.all_windows)
  if not ok_windows or type(mux_windows) ~= 'table' then
    log_warn_rate_limited('cache-prune-windows', 'Failed to list mux windows for cache pruning: ' .. tostring(mux_windows))
    return nil, nil
  end

  for _, mux_window in ipairs(mux_windows) do
    local ok_window_id, window_id = pcall(mux_window.window_id, mux_window)
    if ok_window_id and window_id ~= nil then
      live_windows[window_id] = true
    end

    local ok_tabs, tabs = pcall(mux_window.tabs, mux_window)
    if ok_tabs and type(tabs) == 'table' then
      for _, tab in ipairs(tabs) do
        local ok_panes, panes = pcall(tab.panes, tab)
        if ok_panes and type(panes) == 'table' then
          for _, pane in ipairs(panes) do
            local pane_id = get_pane_cache_id(pane)
            if pane_id ~= nil then
              live_panes[pane_id] = true
            end
          end
        end
      end
    end
  end

  return live_panes, live_windows
end

local function prune_cache(cache, live_ids)
  for id in pairs(cache) do
    if not live_ids[id] then
      cache[id] = nil
    end
  end
end

local function prune_dead_cache_entries()
  local now = os.time()
  if (now - cache_prune_last_update) < cache_prune_interval_seconds then
    return
  end
  cache_prune_last_update = now

  local live_panes, live_windows = collect_live_cache_ids()
  if not live_panes or not live_windows then
    return
  end

  prune_cache(process_info_cache, live_panes)
  prune_cache(tab_title_cache, live_panes)
  prune_cache(pane_user_vars_cache, live_panes)
  prune_cache(pane_start_time_cache, live_panes)
  prune_cache(pane_status_cwd_cache, live_panes)
  prune_cache(pane_process_display_cache, live_panes)
  prune_cache(tab_title_process_name_cache, live_panes)
  prune_cache(fallback_process_start_by_pane, live_panes)
  prune_cache(pane_snapshot_cache, live_panes)
  prune_cache(pane_refresh_pending, live_panes)
  prune_cache(pane_refresh_pending_since, live_panes)
  prune_cache(window_status_cache, live_windows)
  prune_cache(key_icons_by_window, live_windows)
end

local function compute_display_cwd(pane, process_cwd)
  local ok, cwd = pcall(pane.get_current_working_dir, pane)
  if ok and cwd then
    if type(cwd) == 'string' then
      return normalize_path(cwd)
    elseif cwd.file_path then
      return normalize_path(cwd.file_path)
    else
      return normalize_path(tostring(cwd))
    end
  end
  if type(process_cwd) == 'string' and process_cwd ~= '' then
    return normalize_path(process_cwd)
  end
  return ''
end

local function refresh_pane_snapshot(pane)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then return end
  local now = os.time()
  local previous = pane_snapshot_cache[pane_id]
  local p_name, f_name, raw_cwd, pid, process_time, argv =
    query_process_name_fullname_cwd_pid_time_argv(pane)
  local got_live_process = p_name and f_name
  if not got_live_process and previous and previous.process_name and previous.fullname then
    p_name       = previous.process_name
    f_name       = previous.fullname
    pid          = previous.pid
    process_time = previous.process_time
    argv         = previous.argv
  elseif not got_live_process then
    p_name, f_name, raw_cwd, pid, process_time, argv =
      get_cached_process_info(pane, nil)
  end
  if not process_time and p_name and f_name then
    local fallback = fallback_process_start_by_pane[pane_id]
    local same_fallback_process = fallback
      and fallback.process_name == p_name
      and fallback.fullname == f_name
      and (fallback.pid == pid or fallback.pid == nil or pid == nil)
    local same_previous_process = previous
      and previous.process_time
      and previous.process_name == p_name
      and previous.fullname == f_name
      and (previous.pid == pid or previous.pid == nil or pid == nil)

    if same_previous_process then
      process_time = previous.process_time
    elseif same_fallback_process then
      process_time = fallback.process_time
    else
      process_time = now
    end
  end
  if process_time and p_name and f_name then
    fallback_process_start_by_pane[pane_id] = {
      process_name = p_name,
      fullname = f_name,
      pid = pid,
      process_time = process_time,
    }
  end
  local shell = (p_name and f_name) and get_shell(p_name, f_name, argv) or nil
  local display_cwd = compute_display_cwd(pane, raw_cwd)
  if display_cwd == '' and previous and type(previous.cwd) == 'string' then
    display_cwd = previous.cwd
  end
  if got_live_process then
    cache_process_info(pane, p_name, f_name, raw_cwd, pid, process_time, argv)
  end
  pane_snapshot_cache[pane_id] = {
    process_name        = p_name,
    fullname            = f_name,
    pid                 = pid,
    process_time        = process_time,
    argv                = argv,
    shell               = shell,
    cwd                 = display_cwd,
    process_is_fallback = not got_live_process,
    last_process_update = got_live_process and now or (previous and previous.last_process_update),
    last_update         = now,
  }
end

local function get_pane_snapshot(pane)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then return nil end
  return pane_snapshot_cache[pane_id]
end

local function ensure_pane_snapshot(pane)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil or pane_snapshot_cache[pane_id] then
    return
  end
  local ok, err = pcall(refresh_pane_snapshot, pane)
  if not ok then
    log_warn_rate_limited(
      'pane-initial-refresh-' .. tostring(pane_id),
      'Failed to build initial pane snapshot for pane ' .. tostring(pane_id) .. ': ' .. tostring(err)
    )
  end
end

-- Schedule a deferred refresh of the pane snapshot. Rate-limited to once per
-- second per pane; pending flag has a 5s stuck-recovery so a failed callback
-- can never lock the refresher forever.
local function schedule_pane_refresh(pane, after_refresh, force)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then return end
  local snapshot = pane_snapshot_cache[pane_id]
  local now = os.time()
  if not force and snapshot and (now - snapshot.last_update) < snapshot_min_age_seconds then
    return
  end
  if pane_refresh_pending[pane_id] then
    local since = pane_refresh_pending_since[pane_id] or now
    if (now - since) < snapshot_pending_recover_seconds then
      return
    end
    -- Falls through: previous callback never cleared the flag.
  end
  pane_refresh_pending[pane_id] = true
  pane_refresh_pending_since[pane_id] = now
  wezterm.time.call_after(0.05, function()
    local ok, err = pcall(refresh_pane_snapshot, pane)
    if not ok then
      log_warn_rate_limited(
        'pane-refresh-' .. tostring(pane_id),
        'Failed to refresh pane snapshot for pane ' .. tostring(pane_id) .. ': ' .. tostring(err)
      )
    end
    pane_refresh_pending[pane_id] = nil
    pane_refresh_pending_since[pane_id] = nil
    if ok and after_refresh then
      local ok_after, after_err = pcall(after_refresh)
      if not ok_after then
        log_warn_rate_limited(
          'pane-refresh-after-' .. tostring(pane_id),
          'Failed to repaint after pane snapshot refresh for pane ' .. tostring(pane_id) .. ': ' .. tostring(after_err)
        )
      end
    end
  end)
end

local function get_display_clock_seconds()
  if wezterm.time and wezterm.time.now then
    local ok, text = pcall(function()
      return wezterm.time.now():format_utc('%s%.3f')
    end)
    local seconds = ok and tonumber(text) or nil
    if seconds then
      return seconds
    end
  end

  if wezterm.strftime_utc then
    local ok, text = pcall(wezterm.strftime_utc, '%s%.3f')
    local seconds = ok and tonumber(text) or nil
    if seconds then
      return seconds
    end
  end

  return os.time()
end

local function get_stable_display_value(cache, key, signature, value)
  if key == nil then
    return value
  end

  local now = get_display_clock_seconds()
  local state = cache[key]
  if not state then
    state = {
      signature = signature,
      value = value,
    }
    cache[key] = state
    return value
  end

  if state.signature == signature then
    state.candidate_signature = nil
    state.candidate_value = nil
    state.candidate_since = nil
    return state.value
  end

  if state.candidate_signature ~= signature then
    state.candidate_signature = signature
    state.candidate_value = value
    state.candidate_since = now
    return state.value
  end

  if now - state.candidate_since >= stable_display_delay_seconds then
    state.signature = state.candidate_signature
    state.value = state.candidate_value
    state.candidate_signature = nil
    state.candidate_value = nil
    state.candidate_since = nil
  end
  return state.value
end

local function get_running_process_display(pane_id, process_name, fullname, pid, process_time, shell, is_alt)
  local raw_display = nil
  local signature = table.concat({
    process_name or '',
    fullname or '',
    tostring(pid or ''),
    tostring(process_time or ''),
    shell or '',
    is_alt and 'alt' or '',
  }, '\31')

  if process_time then
    local running_color
    if shell or not process_name or is_alt then
      -- show blueish running time for: recognized idle shell, wezterm overlay, alt screen app
      running_color = '#3D8AB1'
    else
      -- show red running time for some process in progress
      running_color = '#AB696F'
    end

    raw_display = {
      process_time = process_time,
      color = running_color,
    }
  end
  if not raw_display and pane_id ~= nil then
    local state = pane_process_display_cache[pane_id]
    local display = state and (state.value or state.candidate_value)
    if display and display.process_time then
      return display.process_time, display.color or ''
    end
  end

  local display = get_stable_display_value(pane_process_display_cache, pane_id, signature, raw_display)
  if display then
    return display.process_time, display.color or ''
  end
  return nil, ''
end

local function get_pane_start_time(pane_id, process_time)
  if not pane_id or not process_time then
    return '------------------------------'
  end
  local cached = pane_start_time_cache[pane_id]
  if not cached or cached.process_time ~= process_time then
    local ok, date_text = pcall(os.date, '%b %d %X', process_time)
    if not ok then
      return '------------------------------'
    end
    cached = {
      process_time = process_time,
      text = wezterm.nerdfonts.fa_clock..' '..date_text,
    }
    pane_start_time_cache[pane_id] = cached
  end
  return cached.text
end

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

-- Format tab titles from snapshot pane info first, then fall back to the last
-- cached live process name when that gives a more specific label.
local function get_tab_title_process_name(pane)
  local pane_id = get_pane_cache_id(pane)
  local snapshot = pane_id and pane_snapshot_cache[pane_id] or nil
  if snapshot and snapshot.process_name
      and snapshot.last_update
      and (os.time() - snapshot.last_update) < tab_title_snapshot_max_age_seconds then
    return snapshot.shell or snapshot.process_name
  end

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
  local cached_name = get_cached_process_info(pane, 5)
  return cached_name
end

local function safe_active_workspace(window)
  if not window or type(window.active_workspace) ~= 'function' then
    return ''
  end
  local ok, workspace = pcall(window.active_workspace, window)
  if ok and type(workspace) == 'string' then
    return workspace
  end
  return ''
end

local function safe_pane_domain_name(pane)
  if not pane or type(pane.get_domain_name) ~= 'function' then
    return ''
  end
  local ok, domain_name = pcall(pane.get_domain_name, pane)
  if ok and type(domain_name) == 'string' then
    return domain_name
  end
  return ''
end

local function safe_pane_alt_screen_active(pane)
  if not pane or type(pane.is_alt_screen_active) ~= 'function' then
    return false
  end
  local ok, is_alt = pcall(pane.is_alt_screen_active, pane)
  return ok and is_alt or false
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

local function format_elapsed_time(process_time)
  local elapsed_seconds = math.max(0, math.floor(get_display_clock_seconds() - process_time))
  local days = math.floor(elapsed_seconds / 86400)
  local ok, time_text = pcall(os.date, '!%X', elapsed_seconds)
  if not ok or type(time_text) ~= 'string' then
    time_text = '00:00:00'
  end
  return (days > 0 and days..'d' or '')..time_text
end

local function get_cached_clock_process_time(pane_id)
  if pane_id == nil then
    return nil, ''
  end
  local state = pane_process_display_cache[pane_id]
  local display = state and (state.value or state.candidate_value)
  if display and display.process_time then
    return display.process_time, display.color or ''
  end
  local snapshot = pane_snapshot_cache[pane_id]
  if snapshot and snapshot.process_time then
    return snapshot.process_time, snapshot.shell and '#3D8AB1' or '#AB696F'
  end
  local fallback = fallback_process_start_by_pane[pane_id]
  if fallback and fallback.process_time then
    return fallback.process_time, '#3D8AB1'
  end
  return nil, ''
end

local function format_right_status_fallback(window, pane)
  local pane_id = get_pane_cache_id(pane)
  local process_time, color = get_cached_clock_process_time(pane_id)
  local items = {}
  append_format_item(items, '#847EAE', safe_active_workspace(window)..' : '..safe_pane_domain_name(pane)..'    ')
  if process_time then
    append_format_item(items, color ~= '' and color or '#3D8AB1', format_elapsed_time(process_time)..'    ')
  end
  append_format_item(items, 'Gray', get_pane_start_time(pane_id, process_time) .. '      ')
  return wezterm.format(items)
end

local format_right_status = function(window, pane)
  local state = get_window_status_state(window)
  local ok, result = pcall(function()
    local had_snapshot = get_pane_snapshot(pane) ~= nil
    ensure_pane_snapshot(pane)
    local initial_snapshot = get_pane_snapshot(pane) or {}
    local force_refresh = not had_snapshot and (not initial_snapshot.process_name or initial_snapshot.process_is_fallback)
    schedule_pane_refresh(pane, function()
      if refresh_window_status then
        refresh_window_status(window, pane)
      end
    end, force_refresh)

    local user_vars = get_cached_user_vars(pane)
    local pane_id = get_pane_cache_id(pane)
    local domain_name = safe_pane_domain_name(pane)
    local snapshot = get_pane_snapshot(pane) or {}
    local process_name = snapshot.process_name
    local fullname     = snapshot.fullname
    local pid          = snapshot.pid
    local process_time = snapshot.process_time
    local shell        = snapshot.shell
    local cwd          = snapshot.cwd or ''
    cwd = get_stable_display_value(pane_status_cwd_cache, pane_id, cwd, cwd)

    local clink_color = toggle_color(user_vars.clink)
    local zsh_color = toggle_color(user_vars.zsh)
    local nvim_color = toggle_color(user_vars.nvim)
    local running_time = ''
    local display_process_time, running_color =
      get_running_process_display(pane_id, process_name, fullname, pid, process_time, shell, safe_pane_alt_screen_active(pane))
    if display_process_time then
      running_time = format_elapsed_time(display_process_time)
    end
    local battery_status = get_battery_status()
    local key_icons = get_key_icons_stack(window)

    -- Format top status
    --------------------
    local items = {}
    append_format_item(items, 'Yellow', table.concat(key_icons, ' '))
    append_format_item(items, '#4488FF', (#key_icons > 0) and ' '..wezterm.nerdfonts.md_arrow_expand_left..'    ' or '')
    append_format_item(items, '#BBBBBB', (cwd and cwd ~= '') and (cwd..'      ') or '')
    append_format_item(items, '#847EAE', safe_active_workspace(window)..' : '..domain_name..'    ')
    append_format_item(items, clink_color, wezterm.nerdfonts.md_alpha_c..' ')
    append_format_item(items, zsh_color, wezterm.nerdfonts.md_alpha_z..' ')
    append_format_item(items, nvim_color, wezterm.nerdfonts.custom_neovim..'    ')
    append_format_item(items, running_color, running_time ~= '' and (running_time..'    ') or '')
    append_format_item(items, battery_status.color, (battery_status.icon or '') .. (battery_status.text or ''))
    append_format_item(items, 'Gray', get_pane_start_time(pane_id, display_process_time) .. '      ')
    return wezterm.format(items)
  end)
  if not ok then
    log_warn_rate_limited('right-status', 'Failed to format right status: ' .. tostring(result))
    local ok_fallback, fallback = pcall(format_right_status_fallback, window, pane)
    if ok_fallback then
      return fallback
    end
    return state.right_status or ''
  end
  return result
end

local function mark_pane_display_stale(pane)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then
    return nil
  end

  process_info_cache[pane_id] = nil
  pane_status_cwd_cache[pane_id] = nil
  pane_process_display_cache[pane_id] = nil
  tab_title_process_name_cache[pane_id] = nil
  tab_title_cache[pane_id] = nil
  pane_refresh_pending[pane_id] = nil
  pane_refresh_pending_since[pane_id] = nil
  fallback_process_start_by_pane[pane_id] = nil

  if pane_snapshot_cache[pane_id] then
    pane_snapshot_cache[pane_id].last_update = 0
  end
  return pane_id
end

refresh_window_status = function(window, pane)
  if not window then
    return
  end
  clear_status_interval_override(window)
  prune_dead_cache_entries()
  local state = get_window_status_state(window)
  local ok_left_status, left_status = pcall(format_left_status, window, pane)
  if not ok_left_status then
    log_warn_rate_limited('left-status', 'Failed to format left status: ' .. tostring(left_status))
    left_status = state.left_status or ''
  end
  if left_status ~= state.left_status then
    local ok_set, err = pcall(window.set_left_status, window, left_status)
    if ok_set then
      state.left_status = left_status
    else
      log_warn_rate_limited('left-status-set', 'Failed to set left status: ' .. tostring(err))
    end
  end
  local right_status = format_right_status(window, pane)
  if right_status ~= state.right_status then
    local ok_set, err = pcall(window.set_right_status, window, right_status)
    if ok_set then
      state.right_status = right_status
    else
      log_warn_rate_limited('right-status-set', 'Failed to set right status: ' .. tostring(err))
    end
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

local status_clock_generation = tostring(get_display_clock_seconds()) .. ':' .. tostring(math.random(1000000))
local status_clock_started = false
local function refresh_all_window_statuses()
  if not wezterm.gui or type(wezterm.gui.gui_windows) ~= 'function' then
    return
  end
  local ok_windows, windows = pcall(wezterm.gui.gui_windows)
  if not ok_windows or type(windows) ~= 'table' then
    log_warn_rate_limited('status-clock-windows', 'Failed to list GUI windows for status clock: ' .. tostring(windows))
    return
  end
  for _, window in ipairs(windows) do
    local pane = get_window_active_pane(window)
    if pane then
      refresh_window_status(window, pane)
    end
  end
end

local function schedule_status_clock_tick()
  wezterm.time.call_after(0.5, function()
    if wezterm.GLOBAL and wezterm.GLOBAL.status_clock_generation ~= status_clock_generation then
      return
    end
    local ok, err = pcall(refresh_all_window_statuses)
    if not ok then
      log_warn_rate_limited('status-clock', 'Failed to refresh status clock: ' .. tostring(err))
    end
    schedule_status_clock_tick()
  end)
end

local function start_status_clock()
  if status_clock_started then
    return
  end
  status_clock_started = true
  if wezterm.GLOBAL then
    wezterm.GLOBAL.status_clock_generation = status_clock_generation
  end
  schedule_status_clock_tick()
end

local function refresh_after_overlay_delay(window, delay_seconds)
  wezterm.time.call_after(delay_seconds, function()
    local ok, err = pcall(function()
      local pane = get_window_active_pane(window)
      if not pane then
        return
      end
      local pane_id = mark_pane_display_stale(pane)
      local ok_refresh, refresh_err = pcall(refresh_pane_snapshot, pane)
      if not ok_refresh then
        log_warn_rate_limited(
          'overlay-pane-refresh-' .. tostring(pane_id or 'unknown'),
          'Failed to refresh pane after overlay closed: ' .. tostring(refresh_err)
        )
      end
      refresh_window_status(window, pane)
    end)
    if not ok then
      log_warn_rate_limited(
        'overlay-refresh-callback',
        'Failed to refresh status after overlay closed: ' .. tostring(err)
      )
    end
  end)
end

refresh_after_overlay_close = function(window)
  refresh_after_overlay_delay(window, 0.05)
  refresh_after_overlay_delay(window, 0.25)
end

wezterm.on('user-var-changed', function(window, pane, name, value)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then
    return
  end
  local cached = pane_user_vars_cache[pane_id]
  if not cached then
    local ok_vars, user_vars = pcall(pane.get_user_vars, pane)
    if not ok_vars or type(user_vars) ~= 'table' then
      log_warn_rate_limited('user-vars', 'Failed to read pane user vars: ' .. tostring(user_vars))
      user_vars = {}
    end
    cached = user_vars
    pane_user_vars_cache[pane_id] = cached
  end
  cached[name] = value
  -- Mark process snapshot stale (so the next status tick schedules a refresh)
  -- but keep the last value visible until the async refresher fills in the
  -- new one — avoids a blank flash on every prompt.
  process_info_cache[pane_id] = nil
  if pane_snapshot_cache[pane_id] then
    pane_snapshot_cache[pane_id].last_update = 0
  end
  pane_refresh_pending[pane_id] = nil
  pane_refresh_pending_since[pane_id] = nil
  refresh_window_status(window, pane)
end)

wezterm.on('window-focus-changed', function(window, pane)
  clear_status_interval_override(window)
  start_status_clock()
  refresh_window_status(window, pane)
end)

wezterm.on('update-status', function(window, pane)
  start_status_clock()
  refresh_window_status(window, pane)
end)

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
  name = get_stable_display_value(tab_title_process_name_cache, pane_id, name or '', name)
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
  start_status_clock()
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
