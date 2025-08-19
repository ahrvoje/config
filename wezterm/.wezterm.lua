local wezterm = require 'wezterm'
local act = wezterm.action

local config = wezterm.config_builder()

-- load local configuration if available --------
local function prequire(m) 
  local ok, err = pcall(require, m) 
  if not ok then return nil, err end

  return err
end

local local_config = prequire 'local_config'
-------------------------------------------------

config.adjust_window_size_when_changing_font_size = false
config.animation_fps = 120
config.max_fps = 120
config.audible_bell = 'Disabled'
config.canonicalize_pasted_newlines = 'CarriageReturnAndLineFeed'
config.check_for_updates = false
config.disable_default_key_bindings = true
config.inactive_pane_hsb = { hue = 1.0, saturation = 0.3, brightness = 0.4 }
config.initial_cols = 124
config.initial_rows = 36
config.scrollback_lines = 200000
config.show_close_tab_button_in_tabs = false
config.status_update_interval = 300
config.window_decorations = 'RESIZE'

if wezterm.target_triple:match('darwin') then
  config.window_frame = { font_size = 18 }
else
  config.window_frame = { font_size = 12 }
end

if wezterm.target_triple:match('windows') then
  config.leader = { key = '`', mods = 'ALT', timeout_milliseconds = 9999 }
elseif wezterm.target_triple:match('darwin') then
  config.leader = { key = '“', mods = 'SUPER', timeout_milliseconds = 9999 }
end

-- Selection of dark themes with acceptable contrast
--
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
-- Given "/foo/bar" returns "bar"
-- Given "c:\\foo\\bar" returns "bar"
local function get_basename(s)
  return string.gsub(s, '(.*[/\\])(.*)', '%2')
end

-- https://stackoverflow.com/questions/2235173/what-is-the-naming-standard-for-path-components
local function get_rootname(s)
  return s:match("([^/\\]+)%.exe$") or s:match("([^/\\]+)$")
end

local get_process_name_fullname_pid_time_argv = function (pane)
  -- if not mux pane, get it
  if pane and pane.foreground_process_name then
    pane = wezterm.mux.get_pane(pane.pane_id)
  end
  
  if pane and pane.get_foreground_process_info then
    local info = pane.get_foreground_process_info(pane)
    if info then
      return get_rootname((info.name):lower()), (info.executable):lower(), info.pid, info.start_time, info.argv
    end
  end
end

----------------------------------------------------------------------------------
-- Better shell detection
--   There is no way to detect is a shell idle or some process running so these
--   kind of heuristics are needed, and they can fail for some novel case.
--   https://wezfurlong.org/wezterm/config/lua/config/skip_close_confirmation_for_processes_named.html
--   https://github.com/wez/wezterm/issues/562#issuecomment-803440418
--   https://github.com/wez/wezterm/issues/843
local get_shell = function(pane)
  local shells = {
    cmd = 1, bash = 2, powershell = 3, pwsh = 4, zsh = 5, tmux = 6,
    wslhost = 7, nu = 8, fish = 9, sh = 10, ksh = 11, dash = 12,
  }

  process_name, full_name, _, _, argv = get_process_name_fullname_pid_time_argv(pane)
  if not process_name or not full_name then
    return nil
  end
  
  if process_name == 'bash' and full_name:match('git') then
    return 'gitbash'
  end
  
  if shells[process_name] then
    return process_name
  end

  if full_name:match('msys') and process_name:match('env') then
    return 'msys'
  end

  if not argv then
    return nil
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
  
  return nil
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
  shell = get_shell(pane) 
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
local action_log_process = function(window, pane)
  ok, process_info = pcall(pane.get_foreground_process_info, pane)
  if not ok or not process_info then
    return
  end

  if process_name == 'wezterm' then
    wezterm.log_info('wezterm overlay')
  else
    wezterm.log_info('Process info: ')
    wezterm.log_info(process_info)
  end
end

local function paneinfo_for_pane(pane)
  local id = pane:pane_id()
  for _, info in ipairs(pane:tab():panes_with_info()) do
    if info.pane:pane_id() == id then return info end
  end
end

local action_log_pane_info = function(window, pane)
  wezterm.log_info('Pane info: ')
  wezterm.log_info(paneinfo_for_pane(pane))
end

local action_log_local_config = function(window, pane)
  wezterm.log_info('Local configuration: ')
  wezterm.log_info(local_config)
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
  shell = get_shell(pane)
  if not shell or shell ~= '' then
    -- wezterm overlay or actual shell (e.g. zsh)
    window:perform_action(act.SendKey{ key='Home', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollToTop, pane)
  end
end

local action_up = function(window, pane)
  shell = get_shell(pane)
  if not shell or shell ~= '' then
    window:perform_action(act.SendKey{ key='UpArrow', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollByLine(-1), pane)
  end
end

local action_down = function(window, pane)
  shell = get_shell(pane)
  if not shell or shell ~= '' then
    window:perform_action(act.SendKey{ key='DownArrow', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollByLine(1), pane)
  end
end

----------------------------------------------------------------------------------
-- Clear screen action
local action_clear_screen = function(window, pane)
  shell = get_shell(pane)
  
  if shell == 'cmd' or shell == 'powershell' or shell == 'pwsh' or shell == 'nu' then
    window:perform_action(act.SendString ( 'cls\r' ), pane)
    window:perform_action(act.ClearScrollback 'ScrollbackOnly', pane)
    return
  end
  
--  if shell == 'bash' then
--    -- In Bash/Zsh/etc., send terminal reset aka RIS
--    window:perform_action(act.SendString('\x1bc'), pane)
--    window:perform_action(act.ClearScrollback 'ScrollbackOnly', pane)
--    return
--  end
  
  if shell == 'bash' or shell == 'zsh' or shell == 'wslhost' then
    window:perform_action(act.SendString('clear \r'), pane)
    window:perform_action(act.ClearScrollback 'ScrollbackOnly', pane)
    return
  end
end

----------------------------------------------------------------------------------
-- 'LEADER + k' - Kill Process action
local action_kill_process = function(window, pane)
  process_name, _, pid, _, _ = get_process_name_fullname_pid_time_argv(pane)
  if process_name == 'wezterm' then
    return
  end

  if wezterm.target_triple:match('windows') and os.getenv('WSL_DISTRO_NAME') == nil then
    os.execute(('taskkill /PID %d /T'):format(pid))  -- no /F first
    wezterm.sleep_ms(500)
    os.execute(('taskkill /PID %d /T /F'):format(pid))
  else
    os.execute(('kill %d'):format(pid))
    wezterm.sleep_ms(500)
    os.execute(('kill -9 %d'):format(pid))
  end
end

----------------------------------------------------------------------------------
-- 'LEADER + x' - Kill active pane
local action_kill_pane = function(window, pane)
  local id = pane:pane_id()

  -- Try nicely (without confirm)
  window:perform_action(wezterm.action.CloseCurrentPane { confirm = false }, pane)

  -- After 200ms delay try a hard kill
  wezterm.time.call_after(0.2, function()
    wezterm.run_child_process({ 'wezterm', 'cli', 'kill-pane', '--pane-id', tostring(id) })
  end)
end

----------------------------------------------------------------------------------
-- 'Ctrl + Alt + ;' - Toggle zoom state of pane running alt screen
local action_alt_pane_toggle_zoom = function(window, pane)
  tab = window:active_tab()
  
  for _, pane_info in ipairs(tab:panes_with_info()) do
    p = pane_info['pane']
    if p:is_alt_screen_active() then
      p:activate()
    end
  end

  for _, pane_info in ipairs(tab:panes_with_info()) do
    p = pane_info['pane']
    if pane_info['is_active'] then
      if pane_info['is_zoomed'] then
        tab:set_zoomed(false)
      else
        tab:set_zoomed(true)
      end
    end
  end
end

-- 'Esc' - Clear the line
local line_is_empty = function (pane)
  local dims = pane:get_dimensions()

  -- bottom visible line index
  local start = dims.scrollback_rows + dims.viewport_rows - 1
  local text = pane:get_lines_as_text(start, 1) or ''
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
  -- cancel leader if active
  if window:leader_is_active() then
    window:perform_action(act.SendKey{ key='Escape' }, pane)
    return
  end

  -- exit overlay if active
  process_name, _, _, _, _ = get_process_name_fullname_pid_time_argv(pane)
  if not process_name then
    window:perform_action(act.SendKey{ key='Escape' }, pane)
    return
  end
  
  if process_name == 'wslhost' then
    if not pane:is_alt_screen_active() and not line_is_empty(pane) then
      -- if in WSL CLI with some chars present in prompt line
      window:perform_action(act.SendString( '\x01\x0b' ), pane)
      return
    end
    -- other cases, e.g. nvim...
    window:perform_action(act.SendKey{ key='[', mods='CTRL' }, pane)
    return
  end

  shell = get_shell(pane)

  -- if some app running, but not shell, e.g. nvim
  if not shell then
    -- there were problems with sending key "Escape" or string "0x1B" directly
    -- Ctrl+[ is old portable terminal trick for sending Esc char 0x1B
    -- apparently Ctrl shaves off high bit of [ char 0x5B leaving 0x1B
    window:perform_action(act.SendKey{ key='[', mods='CTRL' }, pane)
    return
  end

  -- send Esc if line is empty
  if line_is_empty(pane) then
    window:perform_action(act.SendKey{ key='[', mods='CTRL' }, pane)
    return
  end

  -- last option is to clear line

  if wezterm.target_triple:match('windows') and (shell == 'pwsh' or shell == 'powershell') then
    -- PowerShell 5 & 7, works w/o PS key bind, w & w/o Constrained Language Mode (CLM)
    -- Ctrl+Home & Ctrl+End delete from cursor to home & end
    window:perform_action(act.Multiple{
      act.SendKey{ key='Home', mods='CTRL' },
      act.SendKey{ key='End',  mods='CTRL' },
    }, pane)
    return
  end

  -- In win-cmd, Bash/Zsh/etc., send Ctrl-A Ctrl-K to clear line, seems rather portable
  window:perform_action(act.SendString( '\x01\x0b' ), pane)
end

-- Send selected text to pane running alt screen
local action_send_to_alt_pane = function(window, pane)
  text = window:get_selection_text_for_pane(pane)

  tab = window:active_tab()
  for _, pane_info in ipairs(tab:panes_with_info()) do
    p = pane_info['pane']
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
  { key = 'l',          mods = 'LEADER', action = act.Multiple {  -- debugging log & info
    wezterm.action_callback( action_log_process ),
    wezterm.action_callback( action_log_pane_info ),
    wezterm.action_callback( action_log_local_config ),
  }},

  { key = 'Home',       mods = 'CTRL',       action = wezterm.action_callback( action_ctrl_home ) },
  { key = 'End',        mods = 'CTRL',       action = wezterm.action_callback( action_ctrl_end ) },
  { key = 'PageUp',     mods = 'NONE',       action = wezterm.action_callback( action_pageup ) },
  { key = 'PageDown',   mods = 'NONE',       action = wezterm.action_callback( action_pagedown ) },
  { key = 'Escape',     mods = 'NONE',       action = wezterm.action_callback( action_Esc ) },
  { key = 'Enter',      mods = 'CTRL|ALT',   action = wezterm.action_callback( action_clear_screen ) },
  
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
      act.ActivateKeyTable({ name = "term", one_shot = false }),
      wezterm.action_callback( add_term_key_icon )
    }
  },
  { key = '8', mods = 'CTRL|ALT',
    action = act.Multiple { 
      act.ActivateKeyTable({ name = "nvim", one_shot = false }),
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
    table.insert(config.keys, { key = tostring(k), mods = "CTRL", action = act.SendKey( { key = tostring(k), mods="CTRL" }) })
  end

  -- cursor Home and End, half-page Up & Down
  table.insert(config.keys, { key = 'LeftArrow',  mods = 'SUPER', action = act.SendString "\x1bOH" })
  table.insert(config.keys, { key = 'DownArrow',  mods = 'SUPER', action = act.ScrollByPage( 0.5 ) })
  table.insert(config.keys, { key = 'UpArrow',    mods = 'SUPER', action = act.ScrollByPage( -0.5 ) })
  table.insert(config.keys, { key = 'RightArrow', mods = 'SUPER', action = act.SendString "\x1bOF" })

end

-- Local key macros loaded from local configuration
if local_config and local_config['keys'] then
  for _, v in ipairs(local_config.keys) do
    table.insert(config.keys, v)
  end
end

-- send selected text to alt-screen pane, e.g. send terminal selection to nvim
if wezterm.gui then
  copy_mode = wezterm.gui.default_key_tables().copy_mode
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


local launch_menu = {}

if wezterm.target_triple:match('windows') then
  table.insert(launch_menu, {
    label = 'zsh (msys64)',
    args = { 'C:/msys64/usr/bin/zsh.exe', '-l' },
  })

  table.insert(launch_menu, {
    label = 'Neovim',
    args = { 'nvim.bat' },
  })

  table.insert(launch_menu, {
    label = 'Git Bash',
    args = { 'c:/Program Files/Git/bin/bash.exe', '-i', '-l' },
  })
  
  table.insert(launch_menu, {
    label = 'PowerShell 7',
    args = { 'pwsh.exe', '-NoLogo'},
  })
  
  table.insert(launch_menu, {
    label = 'MSYS2',
    args = {
      'C:/msys64/usr/bin/env.exe',
        'MSYSTEM=MSYS',
        '/bin/bash',
        '--login'
    },
  })
    
  table.insert(launch_menu, {
    label = 'Nu',
    args = { 'nu.bat' },
  })
end

config.launch_menu = launch_menu

-- Top left & right status bar
local format_left_status = function(window, pane)
  return wezterm.format({
    { Foreground = { Color = '#66AAAA' } },
    { Text = window:active_workspace() .. ' : ' .. pane:get_domain_name() },
  })
end

local format_right_status = function(window, pane)
  if #key_icons > 0 then
    key_tables_text = ' < Keys stack'
  else
    key_tables_text = ''
  end

  shell = get_shell(pane)
  process_name, _, _, process_time, _ = get_process_name_fullname_pid_time_argv(pane)

  if shell or not process_name or process_name == 'wezterm' or pane:is_alt_screen_active() then
    running_color = '#000000'
  else
    -- show red fire icon for some running process in progress
    running_color = '#FF0000'
  end
  
  if window:leader_is_active() then
    leader_color = '#FF6060'
  else
    leader_color = '#000000'
  end

  -- Battery
  ----------
  battery_info = wezterm:battery_info()
  if #battery_info == 0 then
    battery_color = ''
    battery_icon = ''
    battery_text = ''
  else
    battery_charge = battery_info[1]['state_of_charge']
    battery_text = math.ceil(100 * battery_charge) .. '%  '

    if battery_charge < 0.25 then
    battery_color = 'Red'
    battery_icon = wezterm.nerdfonts.md_battery_20
    elseif battery_charge < 0.5 then
    battery_color = 'Yellow'
    battery_icon = wezterm.nerdfonts.md_battery_50
    else
    battery_color = 'Green'
    battery_icon = wezterm.nerdfonts.md_battery
    end
  end

  -- Process start time  
  ---------------------
  if not process_time then
    -- if wezterm overlay like debug or launcher
    time_status = '------------------------------'
  else
    if wezterm.target_triple:match('windows') then
      -- convert Windows to UNIX time, Windows epoch date is Jan 01, 1601 - 134774 days before UNIX
      -- https://stackoverflow.com/questions/6161776/convert-windows-filetime-to-second-in-unix-linux
      unix_time = math.floor(process_time / 10000000 - 134774 * 86400);
    else
      unix_time = process_time;
    end

    time_status = 'Started: ' .. os.date('%b %d %X', unix_time)
  end

  -- Format top status
  --------------------
  return wezterm.format({
    { Foreground = { Color = 'Yellow' } },
    { Text = table.concat(key_icons, ' ') },
    { Foreground = { Color = 'Gray' } },
    { Text = key_tables_text .. '        ' },
    { Foreground = { Color = running_color } },
    { Text = wezterm.nerdfonts.md_fire },
    { Foreground = { Color = leader_color } },
    { Text = wezterm.nerdfonts.md_lightning_bolt .. '  ' },
    { Foreground = { Color = battery_color } },
    { Text = battery_icon .. battery_text .. '' },
    { Foreground = { Color = 'Gray' } },
    { Text = time_status .. '      ' },
  })
end

wezterm.on('update-status', function(window, pane)
  -- fix for nudging the tab title redraw for wezterm overlays
  window:set_right_status('')

  window:set_left_status(format_left_status(window, pane))
  window:set_right_status(format_right_status(window, pane))
end)

-- Format tab title
icons_names = {
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
  pane = tab.active_pane
  
  process_name, _, _, _, _ = get_process_name_fullname_pid_time_argv(pane)
  if not process_name or process_name == 'wezterm' then
    -- leave formatting to wezterm
    return nil
  end
  
  if pane.title:match('Copy mode:') then
    title_prefix = 'Copy mode: '
  else
    title_prefix = ''
  end
  
  name = get_shell(pane)
  if not name or name == '' then
    name = process_name
  end
  
  icon_name = icons_names[name] or { '>', name }  
  
  return wezterm.format({
    { Text = title_prefix .. icon_name[1] .. ' ' .. icon_name[2] .. ' : ' .. pane.pane_id },
  })
end)

-- Startup window position is loaded from local configuration
wezterm.on('gui-startup', function(cmd)
  if local_config and local_config['window_pos'] then
    x = local_config['window_pos']['x']
    y = local_config['window_pos']['y']
  end
  
  if x == nil or y == nil then
    x = 200
    y = 32
  end
  
  wezterm.mux.spawn_window(cmd or { position = { x = x, y = y } })
end)

if wezterm.target_triple:match('darwin') then
  config.font_size = 14
end

if wezterm.target_triple:match('windows') then
  config.font = wezterm.font 'Consolas'
  config.font_size = 12
  
  config.default_prog = {
    'cmd.exe', '/s', '/k',
      -- set Unicode coding page 65001
      'chcp', '65001', '>', 'nul', '&&',
      
      -- and inject clink into the command prompt
      'clink', 'inject', '-q'
  }
end

return config


----------------------------------------------------------------------------
-- debugging goodies
--
-- get gui window, active pane, active pane title:
--
--     > wezterm['mux']['all_windows']()[1]:gui_window():active_pane():get_title()
--     > wezterm['mux']['all_windows']()[1]:gui_window():active_pane():get_foreground_process_info()
