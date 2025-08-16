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
config.check_for_updates = false
config.disable_default_key_bindings = true
config.inactive_pane_hsb = { hue = 1.0, saturation = 0.3, brightness = 0.4 }
config.initial_cols = 124
config.initial_rows = 36
config.scrollback_lines = 200000
config.show_close_tab_button_in_tabs = false
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
function get_basename(s)
  return string.gsub(s, '(.*[/\\])(.*)', '%2')
end

-- https://stackoverflow.com/questions/2235173/what-is-the-naming-standard-for-path-components
function get_rootname(s)
  return s:match("([^/\\]+)%.exe$") or s:match("([^/\\]+)$")
end

get_process_name = function(pane)
  ok, name = pcall(pane.get_foreground_process_name, pane)
  -- this case covers lua debug overlay and TabNavigator
  if not ok or not name then
    return 'wezterm-gui'
  end
  
  return get_rootname(name)
end

----------------------------------------------------------------------------------
-- Better shell detection
--   There is no way to detect is a shell idle or some process running so these
--   kind of heuristics are needed, and they can fail for some novel case.
--   https://wezfurlong.org/wezterm/config/lua/config/skip_close_confirmation_for_processes_named.html
--   https://github.com/wez/wezterm/issues/562#issuecomment-803440418
--   https://github.com/wez/wezterm/issues/843
get_shell = function(pane)
  local shells = { cmd = 1, bash = 2, powershell = 3, pwsh = 4, zsh = 5, tmux = 6, wslhost = 7, nu = 8, }
  
  process_name = get_process_name(pane):lower()
  -- this case covers lua debug overlay, Launcher, TabNavigator
  if process_name == 'wezterm-gui' then
    return process_name
  end
  
  if shells[process_name] then
    return process_name
  end
  
  ok, process_info = pcall(pane.get_foreground_process_info, pane)
  if not ok or not process_info then
    -- this case covers lua debug overlay, Launcher, TabNavigator
    return 'wezterm-gui'
  end
  
  if ((process_name == 'python') or (process_name == 'python3')) and (#(process_info.argv) == 1) then
    return 'python'
  end

  if ((process_name == 'python') or (process_name == 'python3')) and (#(process_info.argv) == 2) and (process_info.argv[2]:match('ptpython')) then
    return 'ptpython'
  end
  
  if (process_name == 'julia') and (#(process_info.argv) == 1) then
    return 'julia'
  end
  
  return ''
end

----------------------------------------------------------------------------------
-- 'Ctrl-c' key has two roles:
--   KeyboardInterrupt if there is no selection
--   Copy to clipboard if selection is available
action_ctrl_c = function(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if not sel or sel == '' then
    window:perform_action(act.SendKey{ key='c', mods='CTRL' }, pane)
  else
    window:perform_action(act.CopyTo 'ClipboardAndPrimarySelection', pane)
  end
end

----------------------------------------------------------------------------------
-- 'Ctrl-d' close shell, taking care of special cases like PowerShell, Python...
action_exit_shell = function(window, pane)
  if get_shell(pane) == 'python' then
    window:perform_action(act.SendString 'exit()\r', pane)

  elseif get_shell(pane) == 'ptpython' then
    window:perform_action(act.SendString 'exit()\n', pane)

  elseif get_shell(pane) == 'powershell' then
    window:perform_action(act.SendString 'exit\r', pane)

  elseif get_shell(pane) == 'cmd' then
    window:perform_action(act.SendString 'exit\r', pane)

  else
    window:perform_action(act.SendKey { key='d', mods='CTRL' }, pane)
  end
end

----------------------------------------------------------------------------------
-- 'Ctrl+Shift+L' log current process info into debug overlay
action_log_process = function(window, pane)
  ok, process_info = pcall(pane.get_foreground_process_info, pane)
  if not ok or not process_info then
    wezterm.log_info('wezterm overlay')
  else
    wezterm.log_info(process_info)
  end
end

----------------------------------------------------------------------------------
-- 'Ctrl+Shift+C' log local TOML configuration file .wezterm.toml
action_log_config = function(window, pane)
  wezterm.log_info(local_config)
end

----------------------------------------------------------------------------------
-- 'Home'/'Up'/'Down' keys have two roles
--   Default line-start/history-up/history-down if shell is active
--   Scroll-top/scroll-up/scroll-down if no shell/prompt is active
action_home = function(window, pane)
  shell = get_shell(pane)
  if shell == nil or shell ~= '' then
    window:perform_action(act.SendKey{ key='Home', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollToTop, pane)
  end
end

action_up = function(window, pane)
  shell = get_shell(pane)
  if shell == nil or shell ~= '' then
    window:perform_action(act.SendKey{ key='UpArrow', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollByLine(-1), pane)
  end
end

action_down = function(window, pane)
  shell = get_shell(pane)
  if shell == nil or shell ~= '' then
    window:perform_action(act.SendKey{ key='DownArrow', mods='NONE' }, pane)
  else
    window:perform_action(act.ScrollByLine(1), pane)
  end
end

----------------------------------------------------------------------------------
-- 'LEADER + Enter' - Clear screen action
action_clear_screen = function(window, pane)
  shell = get_shell(pane)
  
  if shell == 'cmd' or shell == 'powershell' or shell == 'pwsh' or shell == 'nu' then
    window:perform_action(act.SendString ( 'cls\r' ), pane)
    window:perform_action(act.ClearScrollback 'ScrollbackOnly', pane)
    window:perform_action(act.ClearScrollback 'ScrollbackAndViewport', pane)
    window:perform_action(act.SendKey { key = 'L', mods = 'CTRL' }, pane)
    return
  end
  
  if shell == 'bash' or shell == 'wslhost' then
    -- In Bash/Zsh/etc., send terminal reset aka RIS
    window:perform_action(act.SendString('\x1bc'), pane)
    window:perform_action(act.ClearScrollback 'ScrollbackAndViewport', pane)
    return
  end

  if shell == 'zsh' then
    window:perform_action(act.SendString('clear \r'), pane)
    window:perform_action(act.ClearScrollback 'ScrollbackAndViewport', pane)
    return
  end
end

----------------------------------------------------------------------------------
-- 'LEADER + k' - Kill Process action
action_kill_process = function(window, pane)
  ok, process_info = pcall(pane.get_foreground_process_info, pane)
  if not ok or not process_info then
    return
  end

  pid = process_info.pid
  
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
-- 'Ctrl + Alt + '' - Pane zoom toggle
action_pane_toggle_zoom = function(window, pane)
  tab = window:active_tab()
  
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

-- 'Ctrl + Alt + ;' - Toggle zoom state of pane running alt screen
action_alt_pane_toggle_zoom = function(window, pane)
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
line_is_empty = function (pane)
  local dims = pane:get_dimensions()

  -- bottom visible line index
  local start = dims.scrollback_rows + dims.viewport_rows - 1
  local text = pane:get_lines_as_text(start, 1) or ""
  text = text:gsub("%s+$","")  -- trim trailing spaces

  -- very conservative: empty or just a prompt-ish ending
  if text == "" then
    return true
  end

  -- common prompt terminators
  if text:match("[%]%$#>~]$") then
    return true
  end

  return false
end

action_clear_line = function(window, pane)
  -- cancel leader if active
  if window:leader_is_active() then
    window:perform_action(act.SendKey{key="Escape"}, pane)
    return
  end

  -- exit overlay if active
  ok, process_info = pcall(pane.get_foreground_process_info, pane)
  if not ok or not process_info then
    window:perform_action(act.SendKey{ key="Escape" }, pane)
    return
  end

  -- if some app running, but not shell, e.g. nvim
  shell = get_shell(pane)
  if shell == '' then
    -- there were problems with sending both key "Escape" and string "0x1B" directly
    -- Ctrl+[ is old portable terminal trick for sending Esc char 0x1B
    -- apparently Ctrl shaves off high bit of [ char 0x5B leaving 0x1B
    window:perform_action(act.SendKey{ key="[", mods="CTRL" }, pane)
    return
  end

  -- send Esc if line is empty
  if line_is_empty(pane) then
    window:perform_action(act.SendKey{ key="[", mods="CTRL" }, pane)
    return
  end

  -- last option is to clear line
  if wezterm.target_triple:match("windows") then
    -- In Windows cmd.exe this is clear line code, maybe more portable
    window:perform_action(act.SendString('\x15'), pane)
  else
   -- In Bash/Zsh/etc., send Ctrl-A Ctrl-K to clear line
    window:perform_action(act.SendString('\x01\x0b'), pane)
  end
end

-- Send selected text to pane running alt screen
action_send_to_alt_pane = function(window, pane)
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
key_icons = ''
clear_key_icons_stack = function(window, pane)
  key_icons = ''
end

pop_key_icons_stack = function(window, pane)
  -- unicode icon char size is 3, and there is one space char, so start from char 5 = 3 + 1 + 1
  key_icons = key_icons:sub(3 + 1 + 1, #key_icons)
end

add_term_key_icon = function(window, pane)
  key_icons = wezterm.nerdfonts.cod_terminal .. ' ' .. key_icons
end

add_nvim_key_icon = function(window, pane)
  key_icons = wezterm.nerdfonts.custom_neovim .. ' ' .. key_icons
end

----------------------------------------------------------------------------------
config.keys = {
    { key = 'Enter',      mods = 'LEADER', action = act.ShowLauncher },
    { key = 'Backspace',  mods = 'LEADER', action = act.ShowDebugOverlay },
    { key = 'Space',      mods = 'LEADER', action = act.ShowTabNavigator },

    { key = 'k',          mods = 'LEADER', action = wezterm.action_callback( action_kill_process ) },
    { key = 'd',          mods = 'CTRL',   action = wezterm.action_callback( action_exit_shell ) },

    { key = 'Enter',      mods = 'CTRL|ALT', action = wezterm.action_callback( action_clear_screen ) },
    { key = 'Escape',     mods = '',         action = wezterm.action_callback( action_clear_line ) },
    
    { key = 't',          mods = 'CTRL|ALT',   action = act.SpawnTab 'CurrentPaneDomain' },
    { key = 'Tab',        mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },
    { key = 'Tab',        mods = 'CTRL',       action = act.ActivateTabRelative(1) },
    
    { key = '\'',         mods = 'CTRL|ALT', action = wezterm.action_callback( action_pane_toggle_zoom ) },
    { key = ';',          mods = 'CTRL|ALT', action = wezterm.action_callback( action_alt_pane_toggle_zoom ) },
    
    { key = 'LeftArrow',  mods = 'CTRL', action = act.ActivatePaneDirection 'Left' },
    { key = 'DownArrow',  mods = 'CTRL', action = act.ActivatePaneDirection 'Down' },
    { key = 'UpArrow',    mods = 'CTRL', action = act.ActivatePaneDirection 'Up' },
    { key = 'RightArrow', mods = 'CTRL', action = act.ActivatePaneDirection 'Right' },
    
    { key = 'LeftArrow',  mods = 'ALT', action = act.AdjustPaneSize { 'Left', 1 } },
    { key = 'DownArrow',  mods = 'ALT', action = act.AdjustPaneSize { 'Down', 1 } },
    { key = 'UpArrow',    mods = 'ALT', action = act.AdjustPaneSize { 'Up', 1 } },
    { key = 'RightArrow', mods = 'ALT', action = act.AdjustPaneSize { 'Right', 1 } },
    
    { key = 'LeftArrow',  mods = 'CTRL|ALT', action = act.SplitPane { direction = 'Left' } },
    { key = 'DownArrow',  mods = 'CTRL|ALT', action = act.SplitPane { direction = 'Down' } },
    { key = 'UpArrow',    mods = 'CTRL|ALT', action = act.SplitPane { direction = 'Up' } },
    { key = 'RightArrow', mods = 'CTRL|ALT', action = act.SplitPane { direction = 'Right' } },

    { key = 'LeftArrow',  mods = 'SUPER', action = act.SendString "\x1bOH" },
    { key = 'DownArrow',  mods = 'SUPER', action = act.ScrollByPage( 0.5 ) },
    { key = 'UpArrow',    mods = 'SUPER', action = act.ScrollByPage( -0.5 ) },
    { key = 'RightArrow', mods = 'SUPER', action = act.SendString "\x1bOF" },

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
    { key = 'w',         mods = 'CTRL',       action = act.CloseCurrentTab{ confirm = true } },
    { key = 'c',         mods = 'CTRL',       action = wezterm.action_callback( action_ctrl_c ) },
    
    { key = 'L',         mods = 'CTRL|SHIFT', action = wezterm.action_callback( action_log_process ) },
    { key = 'C',         mods = 'CTRL|SHIFT', action = wezterm.action_callback( action_log_config ) },
    
    { key = '=',         mods = 'CTRL',       action = act.IncreaseFontSize },
    { key = '-',         mods = 'CTRL',       action = act.DecreaseFontSize },
    { key = '0',         mods = 'CTRL',       action = act.ResetFontSize },
    
    { key = 'v',         mods = 'CTRL',       action = act.PasteFrom 'Clipboard' },
    { key = 'x',         mods = 'CTRL',       action = act.ActivateCopyMode },
    { key = 's',         mods = 'CTRL',       action = act.Search 'CurrentSelectionOrEmptyString' },
    
    { key = 'Home',      mods = 'CTRL',       action = act.ScrollToTop },
    { key = 'End',       mods = 'CTRL',       action = act.ScrollToBottom },
    
    { key = 'Home',      mods = 'NONE',       action = wezterm.action_callback( action_home ) },
    { key = 'UpArrow',   mods = 'NONE',       action = wezterm.action_callback( action_up ) },
    { key = 'DownArrow', mods = 'NONE',       action = wezterm.action_callback( action_down ) },
  },
  
  nvim = {},
}

if wezterm.target_triple:match('darwin') then
  -- Mac, make sure CTRL+1..9 pass through to shell as they are character keys
  for k = 1,9 do
    table.insert(config.keys, { key = tostring(k), mods = "CTRL", action = act.SendKey( { key = tostring(k), mods="CTRL" }) })
  end
  -- make sure CMD+q is pass through as it is used as nvim leader
    table.insert(config.keys, { key = 'q', mods = 'SUPER', action = act.SendKey( { key = 'q', mods='SUPER' }) })
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
    label = 'Neovim',
    args = { 'nvim.bat' },
  })

  table.insert(launch_menu, {
    label = 'Git Bash',
    args = { 'c:/Program Files/Git/bin/bash.exe', '-i', '-l' },
  })
  
  table.insert(launch_menu, {
    label = 'PowerShell',
    args = { 'powershell.exe', '-NoLogo'},
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
wezterm.on('update-status', function(window, pane)
  window:set_left_status(wezterm.format({}))
end)

wezterm.on('update-right-status', function(window, pane)
  if #key_icons > 0 then
    key_tables_text = 'key tables: '
  else
    key_tables_text = ''
  end

  shell = get_shell(pane)  
  if (not shell or shell == '') and not pane:is_alt_screen_active() then
    running_color = 'rgb(255, 0, 0)'
  elseif shell == 'wezterm-gui' then
    running_color = 'rgb(0, 0, 0)'
  else
    running_color = 'rgb(0, 0, 0)'
  end
  
  if window:leader_is_active() then
    leader_color = 'rgb(255, 100, 100)'
  else
    leader_color = 'rgb(0, 0, 0)'
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
  ok, process_info = pcall(pane.get_foreground_process_info, pane)
  if not ok or not process_info then
    -- if overlay like debug or launcher
    time_status = '-------------------'
  else
    if wezterm.target_triple:match('windows') then
      -- convert Windows to UNIX time, Windows epoch date is Jan 01, 1601 - 134774 days before UNIX
      -- https://stackoverflow.com/questions/6161776/convert-windows-filetime-to-second-in-unix-linux
      unix_time = math.floor(process_info.start_time / 10000000 - 134774 * 86400);
    else
      unix_time = process_info.start_time;
    end

    time_status = os.date('%b %d %X', unix_time)
  end

  -- Format top status
  --------------------
  window:set_right_status(wezterm.format({
    { Foreground = { Color = 'Gray' } },
    { Text = key_tables_text },
    { Foreground = { Color = 'Yellow' } },
    { Text = key_icons .. '        ' },
    { Foreground = { Color = running_color } },
    { Text = wezterm.nerdfonts.md_fire },
    { Foreground = { Color = leader_color } },
    { Text = wezterm.nerdfonts.md_lightning_bolt .. '  ' },
    { Foreground = { Color = battery_color } },
    { Text = battery_icon .. battery_text .. '' },
    { Foreground = { Color = 'Gray' } },
    { Text = 'Started: ' .. time_status .. '      ' },
  }))
end)


-- Format tab title
icons_names = {
  nvim       = { wezterm.nerdfonts.custom_neovim,    'Neovim' },
  bash       = { wezterm.nerdfonts.seti_git,         'bash' },
  powershell = { wezterm.nerdfonts.seti_powershell,  'Powershell' },
  python     = { wezterm.nerdfonts.seti_python,      'Python' },
  python3    = { wezterm.nerdfonts.seti_python,      'Python' },
  cmd        = { wezterm.nerdfonts.cod_terminal,     'Cmd' },
  julia      = { wezterm.nerdfonts.seti_julia,       'Julia' },
  wslhost    = { wezterm.nerdfonts.linux_tux,        'WSL' },
  nu         = { wezterm.nerdfonts.md_chevron_right, 'Nu' },
  zsh        = { wezterm.nerdfonts.md_percent,   'zsh' },
}
wezterm.on('format-tab-title', function(tab, tabs, panes, config, hover, max_width)
  if tab.active_pane.title:match('Copy mode:') then
    title_prefix = 'Copy mode: '
  else
    title_prefix = ''
  end

  ok, process_name = pcall(get_rootname, tab.active_pane.foreground_process_name)
  -- this case covers lua debug overlay, Launcher, TabNavigator
  if not ok or not process_name then
    process_name = 'wezterm-gui'
  end

  process_name = process_name:lower()
  icon_name = icons_names[process_name] or { '', process_name }
  
  return wezterm.format({
    { Text = title_prefix .. icon_name[1] .. ' ' .. icon_name[2] },
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

-- Default program
if wezterm.target_triple:match('darwin') then
  config.font_size = 14
end

if wezterm.target_triple:match('windows') then
  config.font = wezterm.font 'Consolas'
  config.font_size = 12

  config.set_environment_variables = {
    prompt = '$E[92m$P$E[36m $E[93m$+$E[37m$G$G$G$E[0m ',
  }
  
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
--     > wezterm['mux']['all_windows']()[1]:gui_window():active_pane()::get_foreground_process_info()
