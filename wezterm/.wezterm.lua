local wezterm = require 'wezterm'
local act = wezterm.action
local cb = wezterm.action_callback
local is_windows = wezterm.target_triple:match('windows') ~= nil
local config = wezterm.config_builder()

-- Small helpers used throughout the config.

local function send_key(key, mods)
  return act.SendKey { key = key, mods = mods or 'NONE' }
end

--------------DEFAULT CONFIGURATION--------------
-- Shared defaults plus optional per-machine overrides.

local default_config = {
  leader       = { key = 'q', mods = 'ALT', timeout_milliseconds = 9999 },
  initial_rows = 32,
  initial_cols = 120,
  -- font         = nil,
  -- font_size    = nil,
  -- window_frame = nil,
  -- launch_menu  = nil,
  -- default_prog = nil,
  window_pos   = { x = 175, y = 30 },  -- initial window position
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

local function get_configured_window_position()
  local default_pos = type(default_config.window_pos) == 'table' and default_config.window_pos or {}
  local local_pos = type(local_config.window_pos) == 'table' and local_config.window_pos or {}
  return {
    x = local_pos.x ~= nil and local_pos.x or default_pos.x,
    y = local_pos.y ~= nil and local_pos.y or default_pos.y,
    origin = local_pos.origin ~= nil and local_pos.origin or default_pos.origin,
  }
end

config.leader       = local_config.leader       or default_config.leader
config.initial_rows = local_config.initial_rows or default_config.initial_rows
config.initial_cols = local_config.initial_cols or default_config.initial_cols
config.font         = local_config.font         or default_config.font
config.font_size    = local_config.font_size    or default_config.font_size
config.window_frame = local_config.window_frame or default_config.window_frame
config.launch_menu  = local_config.launch_menu  or default_config.launch_menu
config.default_prog = local_config.default_prog or default_config.default_prog
-- local_config.keys applied after config.keys
-------------------------------------------------

config.adjust_window_size_when_changing_font_size = false
config.animation_fps = 25
config.max_fps = 60
config.audible_bell = 'Disabled'
if is_windows then
  -- Keep CRLF paste behavior for cmd.exe/PowerShell, but let Unix platforms use
  -- their native/default newline handling.
  config.canonicalize_pasted_newlines = 'CarriageReturnAndLineFeed'
end
config.check_for_updates = false
config.disable_default_key_bindings = true
config.inactive_pane_hsb = { hue = 1.0, saturation = 0.3, brightness = 0.4 }
config.scrollback_lines = 200000
config.show_close_tab_button_in_tabs = false
config.status_update_interval = 300
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
  local pane_id = type(pane.pane_id) == 'function' and pane:pane_id() or pane.pane_id
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
  local pane_id = type(pane.pane_id) == 'function' and pane:pane_id() or pane.pane_id
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
  local process_name, _, _, pid, _, _ = get_pane_process_context(pane, false)
  if not process_name or type(pid) ~= 'number' or pid < 1 then
    return
  end
  local domain_name = pane:get_domain_name()
  if not background_kill_process(domain_name, pid, false) then
    return
  end
  wezterm.time.call_after(0.5, function()
    background_kill_process(domain_name, pid, true)
  end)
end

--------------------------------------------------------------------------------
-- 'LEADER + x' closes the active pane, then follows up with a hard pane kill
-- if the graceful close did not finish.

local action_kill_pane = function(window, pane)
  local pane_id = pane:pane_id()  -- capture now while pane is alive
  window:perform_action(wezterm.action.CloseCurrentPane { confirm = false }, pane)
  wezterm.time.call_after(0.2, function()
    wezterm.background_child_process({
      get_wezterm_cli_executable(),
      'cli',
      'kill-pane',
      '--pane-id',
      tostring(pane_id),
    })
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
local pane_cwd_cache = {}

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
  local overrides = window:get_config_overrides() or {}
  if overrides.status_update_interval ~= nil then
    overrides.status_update_interval = nil
    window:set_config_overrides(overrides)
  end
  state.cleared_status_interval_override = true
end

local function get_pane_cache_id(pane)
  return type(pane.pane_id) == 'function' and pane:pane_id() or pane.pane_id
end

-- User vars are event-driven, so cache them and let the event handler update
-- the copy instead of polling every status tick.
local function get_cached_user_vars(pane)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then
    return pane:get_user_vars()
  end
  local cached = pane_user_vars_cache[pane_id]
  if cached then
    return cached
  end
  local user_vars = pane:get_user_vars()
  pane_user_vars_cache[pane_id] = user_vars
  return user_vars
end

local function toggle_color(status)
  return status == 'on' and '#AF8461' or status == 'off' and '#6A946A' or '#666666'
end

-- Cache battery sampling; some desktops have no battery at all.
local function get_battery_status()
  local now = os.time()
  if battery_cache.data and (now - battery_cache.last_update < 60) then
    return battery_cache.data
  end
  local info = wezterm.battery_info()
  if #info == 0 then
    battery_cache.data = {
      color = '',
      icon = '',
      text = '',
    }
    battery_cache.last_update = now
    return battery_cache.data
  end
  local charge = info[1]['state_of_charge']
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
local stable_display_delay_seconds = 1
local pane_status_cwd_cache = {}
local pane_process_display_cache = {}
local tab_title_process_name_cache = {}

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

-- Prefer WezTerm's current-working-directory API when available, but throttle
-- the call and fall back to process cwd if needed.
local function get_display_cwd(pane, process_cwd, process_pid)
  local pane_id = get_pane_cache_id(pane)
  local cached = pane_id and pane_cwd_cache[pane_id] or nil
  local now = os.time()
  if cached and cached.process_pid == process_pid and (now - cached.last_update) < 2 then
    return cached.cwd
  end
  local ok, cwd = pcall(pane.get_current_working_dir, pane)
  local display_cwd = ''
  if ok and cwd then
    if type(cwd) == 'string' then
      display_cwd = normalize_path(cwd)
    elseif cwd.file_path then
      display_cwd = normalize_path(cwd.file_path)
    else
      display_cwd = normalize_path(tostring(cwd))
    end
  elseif type(process_cwd) == 'string' and process_cwd ~= '' then
    display_cwd = normalize_path(process_cwd)
  end
  if pane_id ~= nil then
    pane_cwd_cache[pane_id] = {
      cwd = display_cwd,
      process_pid = process_pid,
      last_update = now,
    }
  end
  return display_cwd
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

local format_right_status = function(window, pane)
  local ok, result = pcall(function()
    local user_vars = get_cached_user_vars(pane)
    local pane_id = pane:pane_id()
    local domain_name = pane:get_domain_name()
    local process_name, fullname, cwd, pid, process_time, argv = get_process_name_fullname_cwd_pid_time_argv(pane)
    local shell = process_name and fullname and get_shell(process_name, fullname, argv) or nil
    cwd = get_display_cwd(pane, cwd, pid)
    cwd = get_stable_display_value(pane_status_cwd_cache, pane_id, cwd or '', cwd or '')

    local clink_color = toggle_color(user_vars.clink)
    local zsh_color = toggle_color(user_vars.zsh)
    local nvim_color = toggle_color(user_vars.nvim)
    local running_time, days = '', 0
    local display_process_time, running_color =
      get_running_process_display(pane_id, process_name, fullname, pid, process_time, shell, pane:is_alt_screen_active())
    if display_process_time then
      local elapsed_seconds = math.max(0, os.time() - display_process_time)
      days = math.floor(elapsed_seconds / 86400)
      running_time = ( days>0 and days..'d' or '')..os.date('!%X', elapsed_seconds)
    end
    local battery_status = get_battery_status()
    local key_icons = get_key_icons_stack(window)

    -- Format top status
    --------------------
    return wezterm.format({
      { Foreground = { Color = 'Yellow' } },
      { Text = table.concat(key_icons, ' ') },
      { Foreground = { Color = '#4488FF' } },
      { Text = (#key_icons > 0) and ' '..wezterm.nerdfonts.md_arrow_expand_left..'    ' or '' },
      { Foreground = { Color = '#BBBBBB' } },
      { Text = (cwd or '')..'      ' },
      { Foreground = { Color = '#847EAE' } },
      { Text = window:active_workspace()..' : '..domain_name..'    ' },
      { Foreground = { Color = clink_color } },
      { Text = wezterm.nerdfonts.md_alpha_c..' ' },
      { Foreground = { Color = zsh_color } },
      { Text = wezterm.nerdfonts.md_alpha_z..' ' },
      { Foreground = { Color = nvim_color } },
      { Text = wezterm.nerdfonts.custom_neovim..'    ' },
      { Foreground = { Color = running_color } },
      { Text = running_time..'    ' },
      { Foreground = { Color = battery_status.color } },
      { Text = battery_status.icon .. battery_status.text .. '' },
      { Foreground = { Color = 'Gray' } },
      { Text = get_pane_start_time(pane_id, display_process_time) .. '      ' },
    })
  end)
  if not ok then
    return ''
  end
  return result
end

wezterm.on('user-var-changed', function(window, pane, name, value)
  local pane_id = get_pane_cache_id(pane)
  if pane_id == nil then
    return
  end
  local cached = pane_user_vars_cache[pane_id]
  if not cached then
    cached = pane:get_user_vars()
    pane_user_vars_cache[pane_id] = cached
  end
  cached[name] = value
  process_info_cache[pane_id] = nil
  pane_cwd_cache[pane_id] = nil
end)

wezterm.on('window-focus-changed', function(window, pane)
  clear_status_interval_override(window)
end)

wezterm.on('update-status', function(window, pane)
  clear_status_interval_override(window)
  local state = get_window_status_state(window)
  local left_status = format_left_status(window, pane)
  if left_status ~= state.left_status then
    window:set_left_status(left_status)
    state.left_status = left_status
  end
  window:set_right_status(format_right_status(window, pane))
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
  local pane_id = type(pane.pane_id) == 'function' and pane:pane_id() or pane.pane_id
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
    return nil
  end
  return result
end)

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
    spawn.position = get_configured_window_position()
  end
  wezterm.mux.spawn_window(spawn)
end)
return config

----------------------------------------------------------------------------
-- debugging goodies
--
-- get gui window, active pane, active pane title:
--
--     > wezterm['mux']['all_windows']()[1]:gui_window():active_pane():get_title()
--     > wezterm['mux']['all_windows']()[1]:gui_window():active_pane():get_foreground_process_info()
