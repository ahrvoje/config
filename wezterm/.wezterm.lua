local wezterm = require 'wezterm'
local act = wezterm.action

local config = wezterm.config_builder()

--------------DEFAULT CONFIGURATION--------------
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
config.canonicalize_pasted_newlines = 'CarriageReturnAndLineFeed'
config.check_for_updates = false
config.disable_default_key_bindings = true
config.inactive_pane_hsb = { hue = 1.0, saturation = 0.3, brightness = 0.4 }
config.scrollback_lines = 200000
config.show_close_tab_button_in_tabs = false
config.status_update_interval = 500
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
--config.enable_scroll_bar     = true
--config.min_scroll_bar_height = '2cell'
--config.colors                = { scrollbar_thumb = '#556666' }
--config.window_padding        = { left = 8, right = 16, top = 4, bottom = 4 }  -- right padding is scrollbar width


-- Equivalent to POSIX basename(3)
-- '/foo/bar'         → 'bar'
-- '/foo/bar/'        → ''
-- 'c:\\foo\\bar'     → 'bar'
-- 'C:\\foo\\bar.exe' → 'bar.exe'
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

-- normalize windows path by stripping URI scheme
local function normalize_path(path)
  local npath = path
  npath = npath:gsub('^file:///', '')
  npath = npath:gsub('^file://', '')
  npath = npath:gsub('%%(%x%x)', function(h) return string.char(tonumber(h,16)) end)
  npath = npath:gsub('^/([A-Za-z]:)','%1')
  
  return npath
end

local function get_mux_pane(pane)
  if not pane or not pane.foreground_process_name then
    -- if nil or already mux just return back
    return pane
  end

  -- it's not mux pane, so get it
  return wezterm.mux.get_pane(pane.pane_id)
end

local function to_unix_time(t)
  if not wezterm.target_triple:match('windows') then
    -- already Unix time
    return t
  end

  -- convert Windows to Unix time, Windows epoch date is Jan 01, 1601 - 134774 days before Unix
  -- https://stackoverflow.com/questions/6161776/convert-windows-filetime-to-second-in-unix-linux
  return math.floor(t / 10000000 - 134774 * 86400);
end

local process_info_cache = {}

local function get_process_name_fullname_cwd_pid_time_argv(pane)
  local pane_id = type(pane.pane_id) == 'function' and pane:pane_id() or pane.pane_id
  local now = os.time()
  
  local cached = process_info_cache[pane_id]
  if cached and (now - cached.last_update < 2) then
    return cached.name, cached.ext, cached.cwd, cached.pid, cached.time, cached.argv
  end

  local mux_pane = get_mux_pane(pane)
  if not mux_pane then return end

  local ok, info = pcall(mux_pane.get_foreground_process_info, mux_pane)
  if not ok or type(info) ~= 'table' then return end

  local name = info.name
  local executable = info.executable
  if type(name) ~= 'string' or name == '' then return end
  if type(executable) ~= 'string' or executable == '' then return end

  local process_time = nil
  if type(info.start_time) == 'number' then
    process_time = to_unix_time(info.start_time)
  end

  local argv = type(info.argv) == 'table' and info.argv or nil
  local p_name = get_rootname(name:lower())
  local f_name = executable:lower()

  process_info_cache[pane_id] = {
    name = p_name,
    ext = f_name,
    cwd = info.cwd,
    pid = info.pid,
    time = process_time,
    argv = argv,
    last_update = now
  }

  return p_name, f_name, info.cwd, info.pid, process_time, argv
end

----------------------------------------------------------------------------------
-- Better shell detection
--   There is no way to detect is a shell idle or some process running so these
--   kind of heuristics are needed, and they can fail for some novel case.
--   https://wezfurlong.org/wezterm/config/lua/config/skip_close_confirmation_for_processes_named.html
--   https://github.com/wez/wezterm/issues/562#issuecomment-803440418
--   https://github.com/wez/wezterm/issues/843
local function get_shell(process_name, fullname, argv)
  if not process_name or not fullname or not argv then return end

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

local function get_pane_shell(pane)
  local process_name, fullname, _, _, _, argv = get_process_name_fullname_cwd_pid_time_argv(pane)
  if not process_name or not fullname or not argv then
    return
  end

  return get_shell(process_name, fullname, argv)
end

----------------------------------------------------------------------------------
-- 'Ctrl-c' key has two roles:
--   KeyboardInterrupt if there is no selection
--   Copy to clipboard if selection is available
local action_ctrl_c = function(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if not sel or sel == '' then
    window:perform_action(act.SendKey{ key='c', mods='CTRL' }, pane)
  else
    window:perform_action(act.CopyTo 'ClipboardAndPrimarySelection', pane)
  end
end

----------------------------------------------------------------------------------
-- 'Ctrl-d' close shell, taking care of special cases like PowerShell, Python...
local action_exit_shell = function(window, pane)
  local shell = get_pane_shell(pane)
  if shell == 'python' then
    window:perform_action(act.SendString 'exit()\r', pane)

  elseif shell == 'ptpython' then
    window:perform_action(act.SendString 'exit()\n', pane)

  elseif shell == 'powershell' or shell == 'pwsh' then
    window:perform_action(act.SendString 'exit\r', pane)

  elseif shell == 'cmd' then
    window:perform_action(act.SendString 'exit\r', pane)

  else
    window:perform_action(act.SendKey { key='d', mods='CTRL' }, pane)
  end
end

----------------------------------------------------------------------------------
-- 'LEADER + l' log current process, pane, and local conf info into debug overlay
local function get_process_info(window, pane)
  local ok, process_info = pcall(pane.get_foreground_process_info, pane)
  if not ok or not process_info then
    return
  end
  
  return {
    context = 'Process info',
    data = process_info,
  }
end

local function get_pane_info(window, pane)
  local id = pane:pane_id()
  local tab = pane:tab()
  if not tab then return nil end  -- pane has no tab (detached)
  for _, info in ipairs(tab:panes_with_info()) do
    if info.pane:pane_id() == id then
      return { context = 'Pane info', data = info }
    end
  end
end

local function get_pane_user_vars(window, pane)
  return {
    context = 'Pane user vars',
    data = pane:get_user_vars(),
  }
end

local function get_pane_metadata(window, pane)
  return {
    context = 'Pane metadata',
    data = pane:get_metadata(),
  }
end

local function get_pane_misc(window, pane)
  return {
    context = 'Pane misc',
    data = {
      { field = 'alt screen', value = tostring(pane:is_alt_screen_active()) },
      { field = 'cwd',        value = tostring(pane:get_current_working_dir()) },
    }
  }
end

local function get_local_config(window, pane)
  return {
    context = 'Local configuration',
    data = local_config,
  }
end

local action_log_debug_info = function(window, pane)
  wezterm.log_info({
    get_process_info(window, pane),
    get_pane_info(window, pane),
    get_pane_user_vars(window, pane),
    get_pane_metadata(window, pane),
    get_pane_misc(window, pane),
    get_local_config(window, pane),
  })
end

----------------------------------------------------------------------------------
local action_ctrl_home = function(window, pane)
  if pane:is_alt_screen_active() then
    window:perform_action(act.SendKey{ key='Home', mods='CTRL' }, pane)
  else
    window:perform_action(act.ScrollToTop, pane)
  end
end

local action_ctrl_end = function(window, pane)
  if pane:is_alt_screen_active() then
    window:perform_action(act.SendKey{ key='End', mods='CTRL' }, pane)
  else
    window:perform_action(act.ScrollToBottom, pane)
  end
end

local action_pageup = function(window, pane)
  if pane:is_alt_screen_active() then
    window:perform_action(act.SendKey{ key='PageUp', mods='None' }, pane)
  else
    window:perform_action(act.ScrollByPage(-0.5), pane)
  end
end

local action_pagedown = function(window, pane)
  if pane:is_alt_screen_active() then
    window:perform_action(act.SendKey{ key='PageDown', mods='None' }, pane)
  else
    window:perform_action(act.ScrollByPage(0.5), pane)
  end
end

-- 'Home'/'Up'/'Down' keys have two roles
--   Default line-start/history-up/history-down if shell is active
--   Scroll-top/scroll-up/scroll-down if no shell/prompt is active
local action_home = function(window, pane)
  local shell = get_pane_shell(pane)
  if not shell then
    -- wezterm overlay or actual shell (e.g. zsh)
    window:perform_action(act.SendKey{ key='Home', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollToTop, pane)
  end
end

local action_up = function(window, pane)
  local shell = get_pane_shell(pane)
  if not shell then
    window:perform_action(act.SendKey{ key='UpArrow', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollByLine(-1), pane)
  end
end

local action_down = function(window, pane)
  local shell = get_pane_shell(pane)
  if not shell then
    window:perform_action(act.SendKey{ key='DownArrow', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollByLine(1), pane)
  end
end

----------------------------------------------------------------------------------
-- Clear screen action
local action_clear_screen = function(window, pane)
  local shell = get_pane_shell(pane)
  
  if shell == 'powershell' or shell == 'pwsh' then
    window:perform_action(act.SendString( 'clear\r' ), pane)
  else
    window:perform_action(act.SendKey{ key='l', mods='CTRL' }, pane)
  end
end

----------------------------------------------------------------------------------
-- 'LEADER + k' - Kill Process action
local action_kill_process = function(window, pane)
  local process_name, _, _, pid, _, _ = get_process_name_fullname_cwd_pid_time_argv( pane )
  if not process_name then
    return
  end

  if wezterm.target_triple:match('windows') and os.getenv('WSL_DISTRO_NAME') == nil then
    wezterm.background_child_process({ 'taskkill', '/PID', tostring(pid), '/T' })  -- no /F first
    wezterm.sleep_ms(500)
    wezterm.background_child_process({ 'taskkill', '/PID', tostring(pid), '/T', '/F' })
  else
    wezterm.background_child_process({ 'kill', tostring(pid) })
    wezterm.sleep_ms(500)
    wezterm.background_child_process({ 'kill', '-9', tostring(pid) })
  end
end

----------------------------------------------------------------------------------
-- 'LEADER + x' - Kill active pane
local action_kill_pane = function(window, pane)
  local pane_id = pane:pane_id()  -- capture now while pane is alive
  -- Try nicely (without confirm)
  window:perform_action(wezterm.action.CloseCurrentPane { confirm = false }, pane)

  -- After 200ms delay try a hard kill
  wezterm.time.call_after(0.2, function()
    wezterm.background_child_process({ 'wezterm', 'cli', 'kill-pane', '--pane-id', tostring(pane_id) })
  end)
end

----------------------------------------------------------------------------------
-- 'Ctrl + Alt + ;' - Toggle zoom state of pane running alt screen
local action_alt_pane_toggle_zoom = function(window, pane)
  local tab = window:active_tab()
  if not tab then return end

  for _, pane_info in ipairs(tab:panes_with_info()) do
    local mux_pane = pane_info.pane
    if mux_pane:is_alt_screen_active() then
      mux_pane:activate()
      if pane_info.is_zoomed then
        tab:set_zoomed(false)
      else
        tab:set_zoomed(true)
      end
    end
  end
end

-- 'Esc' - Clear the line
local line_is_empty = function (pane)
  local ok, dims = pcall(pane.get_dimensions, pane)
  if not ok or not dims then return true end  -- assume empty if we can't check

  -- bottom visible line index
  local start = dims.scrollback_rows + dims.viewport_rows - 1
  local ok2, text = pcall(pane.get_lines_as_text, pane, start, 1)
  text = (ok2 and text) or ''
  text = text:gsub('%s+$', '')  -- trim trailing spaces

  -- very conservative: empty or just a prompt-ish ending
  if text == '' then
    return true
  end

  -- common prompt terminators
  if text:match('[%]%$#>~]$') then
    return true
  end

  return false
end

local action_Esc = function(window, pane)
  local shell = get_pane_shell(pane)
  local process_name, _, _, _, _, _ = get_process_name_fullname_cwd_pid_time_argv(pane)
  
  if window:leader_is_active() then
    -- cancel leader if active
    window:perform_action(act.SendKey{ key='Escape' }, pane)
  
  elseif not process_name then
    -- exit overlay if active
    window:perform_action(act.SendKey{ key='Escape' }, pane)
  
  elseif process_name == 'wslhost' or shell == 'msys' then
    if not pane:is_alt_screen_active() and not line_is_empty(pane) then
      -- if in CLI with some chars present in prompt line
      window:perform_action(act.SendString( '\x01\x0b' ), pane)
    else
      -- alt screen app is running, e.g. nvim...
      window:perform_action(act.SendKey{ key='[', mods='CTRL' }, pane)
    end
  
  elseif not shell then
  -- if some app running, but not shell, e.g. nvim
    -- there were problems with sending key 'Escape' or string '0x1B' directly
    -- Ctrl+[ is old portable terminal trick for sending Esc char 0x1B
    -- apparently Ctrl shaves off high bit of [ char 0x5B leaving 0x1B
    window:perform_action(act.SendKey{ key='[', mods='CTRL' }, pane)
  
  elseif line_is_empty(pane) then
    -- send Esc if line is empty
    window:perform_action(act.SendKey{ key='[', mods='CTRL' }, pane)
  
  -- last option is to clear the line
  elseif shell == 'cmd' then
    window:perform_action(act.Multiple{
      act.SendKey{ key='End',  mods='NONE' },
      act.SendKey{ key='Home', mods='SHIFT' },
      act.SendKey{ key='Delete', mods='NONE' },
    }, pane)
  
  elseif shell == 'pwsh' or shell == 'powershell' then
    -- PowerShell 5 & 7, works w/o PS key bind, w & w/o Constrained Language Mode (CLM)
    -- Ctrl+Home & Ctrl+End delete from cursor to home & end
    window:perform_action(act.Multiple{
      act.SendKey{ key='Home', mods='CTRL' },
      act.SendKey{ key='End',  mods='CTRL' },
    }, pane)
  
  -- all left cases will get the last available option
  else
    -- Bash/Zsh/etc., send Ctrl-A Ctrl-K to clear line
    window:perform_action(act.SendString( '\x01\x0b' ), pane)
  end
end

-- Send selected text to pane running alt screen
local action_send_to_alt_pane = function(window, pane)
  local text = window:get_selection_text_for_pane(pane)
  if not text or text == '' then return end
  local tab = window:active_tab()
  if not tab then return end

  for _, pane_info in ipairs(tab:panes_with_info()) do
    local p = pane_info.pane
    if p:is_alt_screen_active() then
      wezterm.log_info(text)
      window:perform_action(act.SendString(text), p)
      p:activate()
    end
  end
end

----------------------------------------------------------------------------------
-- key tables stack icons - clear, add, pop
local key_icons = {}
local clear_key_icons_stack = function(window, pane)
  key_icons = {}
end

local pop_key_icons_stack = function(window, pane)
  table.remove(key_icons)
end

local add_term_key_icon = function(window, pane)
  table.insert(key_icons, wezterm.nerdfonts.cod_terminal)
end

local add_nvim_key_icon = function(window, pane)
  table.insert(key_icons, wezterm.nerdfonts.custom_neovim)
end

----------------------------------------------------------------------------------
config.keys = {
  { key = 'F1', mods = 'NONE', action = act.ShowDebugOverlay },
  { key = 'F2', mods = 'NONE', action = act.ShowLauncher },
  { key = 'F3', mods = 'NONE', action = act.ShowTabNavigator },
  { key = 'F4', mods = 'NONE', action = act.ActivateCommandPalette },
  { key = 'F5', mods = 'NONE', action = act.CharSelect{ group = 'SmileysAndEmotion' } },
  { key = 'F6', mods = 'NONE', action = act.CharSelect{ group = 'Objects' } },
  { key = 'F7', mods = 'NONE', action = act.CharSelect{ group = 'Symbols' } },
  { key = 'F8', mods = 'NONE', action = act.CharSelect{ group = 'UnicodeNames' } },

  -- send clean F keys to shell, e.g. for Midnight Commander
  { key = 'F1',  mods = 'CTRL|ALT', action = act.SendKey{ key='F1',  mods='NONE' } },
  { key = 'F2',  mods = 'CTRL|ALT', action = act.SendKey{ key='F2',  mods='NONE' } },
  { key = 'F3',  mods = 'CTRL|ALT', action = act.SendKey{ key='F3',  mods='NONE' } },
  { key = 'F4',  mods = 'CTRL|ALT', action = act.SendKey{ key='F4',  mods='NONE' } },
  { key = 'F5',  mods = 'CTRL|ALT', action = act.SendKey{ key='F5',  mods='NONE' } },
  { key = 'F6',  mods = 'CTRL|ALT', action = act.SendKey{ key='F6',  mods='NONE' } },
  { key = 'F7',  mods = 'CTRL|ALT', action = act.SendKey{ key='F7',  mods='NONE' } },
  { key = 'F8',  mods = 'CTRL|ALT', action = act.SendKey{ key='F8',  mods='NONE' } },
  { key = 'F9',  mods = 'CTRL|ALT', action = act.SendKey{ key='F9',  mods='NONE' } },
  { key = 'F10', mods = 'CTRL|ALT', action = act.SendKey{ key='F10', mods='NONE' } },
  { key = 'F11', mods = 'CTRL|ALT', action = act.SendKey{ key='F11', mods='NONE' } },
  { key = 'F12', mods = 'CTRL|ALT', action = act.SendKey{ key='F12', mods='NONE' } },

  { key = 'd',          mods = 'CTRL',   action = wezterm.action_callback( action_exit_shell ) },
  { key = 'k',          mods = 'LEADER', action = wezterm.action_callback( action_kill_process ) },
  { key = 'x',          mods = 'LEADER', action = wezterm.action_callback( action_kill_pane ) },
  { key = 'l',          mods = 'LEADER', action = wezterm.action_callback( action_log_debug_info ) },

  { key = 'Home',       mods = 'CTRL',       action = wezterm.action_callback( action_ctrl_home ) },
  { key = 'End',        mods = 'CTRL',       action = wezterm.action_callback( action_ctrl_end ) },
  { key = 'PageUp',     mods = 'NONE',       action = wezterm.action_callback( action_pageup ) },
  { key = 'PageDown',   mods = 'NONE',       action = wezterm.action_callback( action_pagedown ) },
  { key = 'Escape',     mods = 'NONE',       action = wezterm.action_callback( action_Esc ) },
  { key = 'l',          mods = 'CTRL',       action = wezterm.action_callback( action_clear_screen ) },
  
  { key = 't',          mods = 'CTRL|ALT',   action = act.SpawnTab 'DefaultDomain' },
  { key = 'y',          mods = 'CTRL|ALT',   action = act.SpawnTab 'CurrentPaneDomain' },
  { key = 'Tab',        mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },
  { key = 'Tab',        mods = 'CTRL',       action = act.ActivateTabRelative(1) },
  
  { key = '\'',         mods = 'CTRL|ALT',   action = act.TogglePaneZoomState },
  { key = ';',          mods = 'CTRL|ALT',   action = wezterm.action_callback( action_alt_pane_toggle_zoom ) },
  
  { key = 'LeftArrow',  mods = 'CTRL',       action = act.ActivatePaneDirection 'Left' },
  { key = 'DownArrow',  mods = 'CTRL',       action = act.ActivatePaneDirection 'Down' },
  { key = 'UpArrow',    mods = 'CTRL',       action = act.ActivatePaneDirection 'Up' },
  { key = 'RightArrow', mods = 'CTRL',       action = act.ActivatePaneDirection 'Right' },
  
  { key = 'LeftArrow',  mods = 'ALT',        action = act.AdjustPaneSize { 'Left', 1 } },
  { key = 'DownArrow',  mods = 'ALT',        action = act.AdjustPaneSize { 'Down', 1 } },
  { key = 'UpArrow',    mods = 'ALT',        action = act.AdjustPaneSize { 'Up', 1 } },
  { key = 'RightArrow', mods = 'ALT',        action = act.AdjustPaneSize { 'Right', 1 } },
  
  { key = 'LeftArrow',  mods = 'CTRL|ALT',   action = act.SplitPane { direction = 'Left' } },
  { key = 'DownArrow',  mods = 'CTRL|ALT',   action = act.SplitPane { direction = 'Down' } },
  { key = 'UpArrow',    mods = 'CTRL|ALT',   action = act.SplitPane { direction = 'Up' } },
  { key = 'RightArrow', mods = 'CTRL|ALT',   action = act.SplitPane { direction = 'Right' } },
      
  -- key mappings for KeyTable stack and actions
  { key = '0', mods = 'CTRL|ALT',
    action = act.Multiple {
      act.ClearKeyTableStack,
      wezterm.action_callback( clear_key_icons_stack ),
    }
  },
  { key = '-', mods = 'CTRL|ALT',
    action = act.Multiple { 
      act.PopKeyTable,
      wezterm.action_callback( pop_key_icons_stack ),
    }
  },
  { key = '9', mods = 'CTRL|ALT',
    action = act.Multiple { 
      act.ActivateKeyTable({ name = 'term', one_shot = false }),
      wezterm.action_callback( add_term_key_icon )
    }
  },
  { key = '8', mods = 'CTRL|ALT',
    action = act.Multiple { 
      act.ActivateKeyTable({ name = 'nvim', one_shot = false }),
      wezterm.action_callback( add_nvim_key_icon )
    }
  },
}

config.key_tables = {
  term = {
    { key = 'w',         mods = 'CTRL', action = act.CloseCurrentTab{ confirm = true } },
    { key = 'c',         mods = 'CTRL', action = wezterm.action_callback( action_ctrl_c ) },
    
    { key = '=',         mods = 'CTRL', action = act.IncreaseFontSize },
    { key = '-',         mods = 'CTRL', action = act.DecreaseFontSize },
    { key = '0',         mods = 'CTRL', action = act.ResetFontSize },
    
    { key = 'v',         mods = 'CTRL', action = act.PasteFrom 'Clipboard' },
    { key = 'x',         mods = 'CTRL', action = act.ActivateCopyMode },
    { key = 's',         mods = 'CTRL', action = act.Search 'CurrentSelectionOrEmptyString' },
    
    { key = 'Home',      mods = 'NONE', action = wezterm.action_callback( action_home ) },
    { key = 'UpArrow',   mods = 'NONE', action = wezterm.action_callback( action_up ) },
    { key = 'DownArrow', mods = 'NONE', action = wezterm.action_callback( action_down ) },
  },
  
  nvim = {},
}

if wezterm.target_triple:match('darwin') then
  -- Mac, make sure CTRL+1..9 pass through to shell as they are character keys
  for k = 1,9 do
    table.insert(config.keys, { key = tostring(k), mods = 'CTRL', action = act.SendKey( { key = tostring(k), mods='CTRL' }) })
  end

  -- cursor Home and End, half-page Up & Down
  table.insert(config.keys, { key = 'LeftArrow',  mods = 'SUPER', action = act.SendString '\x1bOH' })
  table.insert(config.keys, { key = 'DownArrow',  mods = 'SUPER', action = act.ScrollByPage( 0.5 ) })
  table.insert(config.keys, { key = 'UpArrow',    mods = 'SUPER', action = act.ScrollByPage( -0.5 ) })
  table.insert(config.keys, { key = 'RightArrow', mods = 'SUPER', action = act.SendString '\x1bOF' })

end

-- apply local key binds
if local_config.keys then
  for _, v in ipairs(local_config.keys) do
    table.insert(config.keys, v)
  end
end

-- send selected text to alt-screen pane, e.g. send terminal selection to nvim
if wezterm.gui then
  local copy_mode = wezterm.gui.default_key_tables().copy_mode
  table.insert(
    copy_mode,
    { key = 'Enter', mods = 'CTRL', action = wezterm.action_callback( action_send_to_alt_pane ) }
  )
  config.key_tables['copy_mode'] = copy_mode
end

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

-- Top left & right status bar
local format_left_status = function(window, pane)
  return wezterm.format({
    { Foreground = { Color = window:leader_is_active() and '#FF6060' or '#000000' } },
    { Text = wezterm.nerdfonts.md_lightning_bolt },
  })
end

local battery_cache = { data = nil, last_update = 0 }

local function get_battery_status()
  local now = os.time()
  
  if battery_cache.data and (now - battery_cache.last_update < 60) then
    return battery_cache.data
  end

  local info = wezterm.battery_info()
  if #info == 0 then
    return {
      color = '',
      icon = '',
      text = '',
    }
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
local function get_pane_start_time(pane_id, process_time)
  if not pane_id or not process_time then
    return '------------------------------'
  end

  if not pane_start_time_cache[pane_id] then
    pane_start_time_cache[pane_id] = wezterm.nerdfonts.fa_clock..' '..os.date('%b %d %X', process_time)
  end

  return pane_start_time_cache[pane_id]
end

local format_right_status = function(window, pane)
  local ok, result = pcall(function()
    local user_vars = pane:get_user_vars()
    local pane_id = pane:pane_id()
    local domain_name = pane:get_domain_name()

    local process_name, fullname, cwd, _, process_time, argv = get_process_name_fullname_cwd_pid_time_argv(pane)
    local shell = process_name and fullname and argv and get_shell(process_name, fullname, argv) or nil

    if not cwd or shell == 'wslhost' or shell == 'msys' then
      cwd = ''
    end

    local status
    status = user_vars.clink
    local clink_color = status and status=='on' and '#AF8461' or status=='off' and '#6A946A' or '#666666'
    status = user_vars.zsh
    local zsh_color = status and status=='on' and '#AF8461' or status=='off' and '#6A946A' or '#666666'
    status = user_vars.nvim
    local nvim_color = status and status=='on' and '#AF8461' or status=='off' and '#6A946A' or '#666666'

    local running_time, days, running_color = '', 0, ''
    if process_time then
      running_time = os.time() - process_time
      days = math.floor(running_time / 86400)
      running_time = ( days>0 and days..'d' or '')..os.date('!%X', running_time)

      local is_alt = pane:is_alt_screen_active()
      if shell or not process_name or is_alt then
        -- show blueish running time for: recognized idle shell, wezterm overlay, alt screen app
        running_color = '#3D8AB1'
      else
        -- show red running time for some process in progress
        running_color = '#AB696F'
      end
    end

    local battery_status = get_battery_status()

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
      { Text = get_pane_start_time(pane_id, process_time) .. '      ' },
    })
  end)

  if not ok then
    return ''
  end

  return result
end

wezterm.on('update-status', function(window, pane)
  -- fix for nudging the tab title redraw for wezterm overlays
  window:set_right_status('')

  window:set_left_status(format_left_status(window, pane))
  window:set_right_status(format_right_status(window, pane))
end)

-- Format tab title
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
wezterm.on('format-tab-title', function(tab, tabs, panes, config, hover, max_width)
  local ok, result = pcall(function()
    local pane = tab.active_pane

    local process_name, fullname, _, _, _, argv = get_process_name_fullname_cwd_pid_time_argv(pane)
    if not process_name then
      -- leave formatting to wezterm
      return nil
    end

    local title_prefix
    if pane.title and pane.title:match('Copy mode:') then
      title_prefix = 'Copy mode: '
    else
      title_prefix = ''
    end

    local name = get_shell(process_name, fullname, argv)
    if not name or name == '' then
      name = process_name
    end

    local icon_name = icons_names[name] or { '>', name }

    return wezterm.format({
      { Text = title_prefix .. icon_name[1] .. ' ' .. icon_name[2] .. ' : ' .. pane.pane_id },
    })
  end)

  if not ok then
    return nil
  end

  return result
end)

-- Startup window position is loaded from local configuration
wezterm.on('gui-startup', function(cmd)
  wezterm.mux.spawn_window(cmd or { position = {
    x = local_config.window_pos and local_config.window_pos.x or default_config.window_pos.x,
    y = local_config.window_pos and local_config.window_pos.y or default_config.window_pos.y,
  }})
end)

return config


----------------------------------------------------------------------------
-- debugging goodies
--
-- get gui window, active pane, active pane title:
--
--     > wezterm['mux']['all_windows']()[1]:gui_window():active_pane():get_title()
--     > wezterm['mux']['all_windows']()[1]:gui_window():active_pane():get_foreground_process_info()
